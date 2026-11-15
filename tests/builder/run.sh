#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Apex Code's lane case: started, named over AT-SPI, typed into and answered by pylsp in fedora-toolbox-45, against the E0 report's budgets.

# shellcheck disable=SC2016 # jq's programs and the session's bash -c name their own $ variables
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

usage() {
    cat <<USAGE
usage: tests/builder/run.sh [RPM_DIR]

Installs the lane's gnome-builder from RPM_DIR (_build/gnome-builder/out by default) and
runs a headless gnome-shell, as root, whose automation script (probe.js):
- without fedora-toolbox-45, opens the project, presses the notification's Create Toolbox
  (press.py) and waits for pylsp to start in the new toolbox, with no reopen;
- renames the toolbox dev, as another toolbox of its image: Apex Code checks dev's servers
  under that name and offers no Finish Setup; then removes python3-lsp-server from dev, with
  a Python file open, and presses Finish Setup, which must bring it back in dev, make no second
  toolbox, and spawn pylsp with no reopen;
- starts Apex Code on a copy of this repository three times, after a discarded start,
  each after the page cache is dropped: E1's first frame, at most ${BUILDER_FIRST_FRAME_MS:-1900} ms (median);
- opens tests/e1_lsp.py, waits 30 s, and samples Apex Code's own process tree ten
  times: E1's RSS and PSS, at most ${BUILDER_RSS_MIB:-360} and ${BUILDER_PSS_MIB:-270} MiB (median), and
  the toolbox runtime's host side, its servers' clients through the bridge: E2's ${BUILDER_GLUE_MIB:-20} MiB;
- reads the editor's name, E0's eight unnamed buttons and its other gaps over AT-SPI;
- stops the toolbox, as after a reboot, and holds its podman start 3 s; then types into an
  empty e2_typing.py in a meson project for 60 s from a fresh start, a key every 150 ms: E2's longest
  key, press to presented frame, at most ${BUILDER_STALL_MS:-200} ms;
- then waits for pylsp, in the toolbox, to answer a completion;
- types for 60 s into a project whose runtime is a plain fedora:45 container, no toolbox and
  without which(1): each program is looked up there at most twice, and no key over the same budget;
- opens a project whose runtime is a stand-in jhbuild, neither podman nor host: its lookups
  stay on the main thread, and only podman and host are looked up off it.
Before them, bridge.sh checks the toolbox bridge's socket, start and process groups.
Needs a throwaway container with podman's privileges (--privileged), root, and the
packages the Justfile's builder-run installs. The log and result land in _build/gnome-builder/run/.
USAGE
}

case ${1:-} in -h | --help) usage; exit 0 ;; esac
[[ -e /run/.containerenv || -e /.dockerenv ]] || die "run.sh: only inside a throwaway container"
((EUID == 0)) || die "run.sh: runs as root"

readonly HERE=$APEX_ROOT/tests/builder
readonly RPMS=${1:-$APEX_ROOT/_build/gnome-builder/out}
readonly OUT=$APEX_ROOT/_build/gnome-builder/run
readonly TOOLBOX=fedora-toolbox-45
readonly PLAIN=apex-plain
readonly PLAIN_IMAGE=registry.fedoraproject.org/fedora:45
readonly FIRST_FRAME_MS=${BUILDER_FIRST_FRAME_MS:-1900}
readonly RSS_MIB=${BUILDER_RSS_MIB:-360}
readonly PSS_MIB=${BUILDER_PSS_MIB:-270}
readonly STALL_MS=${BUILDER_STALL_MS:-200}
readonly GLUE_MIB=${BUILDER_GLUE_MIB:-20}
# probe.js's caps for Create Toolbox, Finish Setup and three waits for a button (900 + 600 + 3 x 30 s),
# then 10 minutes for its other phases, which take about 4 here.
readonly SHELL_TIMEOUT=2190

shopt -s nullglob
rpms=("$RPMS"/gnome-builder-[0-9]*.x86_64.rpm)
shopt -u nullglob
((${#rpms[@]} == 1)) || die "run.sh: expected one gnome-builder x86_64 RPM in $RPMS"
rm -f /etc/rpm/macros.image-language-conf
for verb in install reinstall; do
    dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates "$verb" "${rpms[0]}" ||
        die "run.sh: cannot $verb ${rpms[0]##*/}"
done
rm -rf "$OUT" && mkdir -p "$OUT"

# The system bus: toolbox create mounts its socket, and the shell's session uses it.
mkdir -p /run/dbus && rm -rf /run/systemd/seats
[[ -S /run/dbus/system_bus_socket ]] || dbus-daemon --system --fork

group "the toolbox bridge"
"$HERE/bridge.sh" >"$OUT/bridge.log" 2>&1 || { cat "$OUT/bridge.log" >&2; die "run.sh: the toolbox bridge's checks failed"; }
cat "$OUT/bridge.log"
endgroup

group "fedora-toolbox-45"
# The toolbox shares the account's home from passwd; CI's HOME (/github/home) is not it.
HOME=$(getent passwd "$(id -un)" | cut -d: -f6)
export HOME SHELL=/bin/bash
# podman without systemd: cgroupfs, file logs (a 99- drop-in outranks containers-common's journald 00-vendor.conf).
mkdir -p /etc/containers/containers.conf.d
printf '[containers]\npids_limit=0\nlog_driver="k8s-file"\n[engine]\ncgroup_manager="cgroupfs"\nevents_logger="file"\n' \
    >/etc/containers/containers.conf.d/99-apex-builder-test.conf
[[ -f /etc/containers/storage.conf ]] ||
    printf '[storage]\ndriver="overlay"\n[storage.options.overlay]\nmount_program="/usr/bin/fuse-overlayfs"\n' >/etc/containers/storage.conf
# Fedora's toolbox loads through /run/host, which only tmpfiles.d/toolbox.conf links on a booted host.
[[ -e /run/host ]] || ln -s ../ /run/host
# Without the toolbox, the probe's first session creates it with Apex Code's own Create Toolbox.
create=true
podman container exists "$TOOLBOX" && create=false
# A podman container that is no toolbox, without which(1): the runtime of a plain project.
podman container exists "$PLAIN" ||
    podman create --quiet --name "$PLAIN" "$PLAIN_IMAGE" sleep infinity >"$OUT/podman.log" 2>&1 ||
    die "run.sh: cannot create $PLAIN; see ${OUT#"$APEX_ROOT/"}/podman.log"
plain_id=$(podman inspect --format '{{.Id}}' "$PLAIN") || die "run.sh: cannot inspect $PLAIN"
podman start "$PLAIN" >/dev/null || die "run.sh: $PLAIN does not start"
if podman exec "$PLAIN" sh -c 'command -v which' >/dev/null; then die "run.sh: $PLAIN has which"; fi
endgroup

project=$HOME/Projects/apex-gnome
rm -rf "$project" && mkdir -p "${project%/*}"
git -c safe.directory='*' -C "$APEX_ROOT" archive --format=tar --prefix=apex-gnome/ HEAD | tar -xf - -C "${project%/*}"
rm -f "$project/.buildconfig"
printf 'import os\n\n\ndef f(a):\n    return undefined_name + a\n' >"$project/tests/e1_lsp.py"
: >"$project/tests/e2_typing.py"
# The typing case's project builds with meson, whose pipeline looks up ninja as it loads.
typing_project=$HOME/Projects/apex-meson
rm -rf "$typing_project" && mkdir -p "$typing_project"
printf "project('apex-meson', 'c')\nexecutable('apex-meson', 'main.c')\n" >"$typing_project/meson.build"
printf 'int main (void) { return 0; }\n' >"$typing_project/main.c"
: >"$typing_project/e2_typing.py"
# Two plain projects, each with its runtime in .buildconfig: the plain container, and jhbuild.
for name in plain jhbuild; do
    dir=$HOME/Projects/apex-$name
    rm -rf "$dir" && mkdir -p "$dir" && : >"$dir/e2_$name.py"
    runtime=jhbuild && [[ $name == plain ]] && runtime=podman:$plain_id
    printf '[default]\nname=Default\nruntime=%s\ntoolchain=default\ndefault=true\n' "$runtime" >"$dir/.buildconfig"
done

drop=$OUT/drop-caches
(while sleep 0.1; do [[ -f $drop ]] && { sync; echo 3 >/proc/sys/vm/drop_caches; rm -f "$drop"; }; done) &
dropper=$!
trap 'kill "$dropper" 2>/dev/null || true' EXIT

run=$(mktemp -d) && chmod 700 "$run"
# No desktop portal: it waits 25 s on RealtimeKit and the GNOME backend's interfaces, and Builder on it.
mkdir -p "$HOME/.local/share/dbus-1/services"
printf '[D-BUS Service]\nName=org.freedesktop.portal.Desktop\nExec=/bin/false\n' \
    >"$HOME/.local/share/dbus-1/services/org.freedesktop.portal.Desktop.service"
rc=0
env XDG_RUNTIME_DIR="$run" XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME LANG=C.UTF-8 GDK_DEBUG=no-portals ADW_DISABLE_PORTAL=1 \
    APEX_BUILDER_PROJECT="$project" APEX_BUILDER_LSP_FILE="$project/tests/e1_lsp.py" APEX_BUILDER_TYPING_FILE="$typing_project/e2_typing.py" \
    APEX_BUILDER_TYPING_PROJECT="$typing_project" APEX_BUILDER_TOOLBOX="$TOOLBOX" \
    APEX_BUILDER_PLAIN_PROJECT="$HOME/Projects/apex-plain" APEX_BUILDER_PLAIN_ID="$plain_id" APEX_BUILDER_PLAIN_LOG="$OUT/builder-plain.log" \
    APEX_BUILDER_JHBUILD_PROJECT="$HOME/Projects/apex-jhbuild" APEX_BUILDER_JHBUILD_LOG="$OUT/builder-jhbuild.log" \
    APEX_BUILDER_MEM="$HERE/mem.py" APEX_BUILDER_ATSPI="$HERE/atspi.py" APEX_BUILDER_DROP="$drop" APEX_BUILDER_CREATE="$create" APEX_BUILDER_PRESS="$HERE/press.py" \
    APEX_BUILDER_LOG="$OUT/builder-verbose.log" APEX_BUILDER_CREATE_LOG="$OUT/builder-create.log" \
    APEX_BUILDER_RENAMED_LOG="$OUT/builder-renamed.log" APEX_BUILDER_SETUP_LOG="$OUT/builder-setup.log" PROBE="$HERE/probe.js" \
    timeout "$SHELL_TIMEOUT" dbus-run-session -- bash -c '
        for setting in "enable-animations false" "cursor-blink false" "toolkit-accessibility true"; do
            gsettings set org.gnome.desktop.interface $setting
        done
        gsettings set org.gnome.desktop.notifications show-banners false
        gsettings set org.gnome.shell welcome-dialog-last-shown-version "999"
        exec gnome-shell --headless --virtual-monitor 1920x1080 --wayland-display=apex-builder --automation-script "$PROBE"
    ' >"$OUT/run.log" 2>&1 || rc=$?

if podman container exists "$TOOLBOX"; then
    driver=$(podman inspect --format '{{.HostConfig.LogConfig.Type}}' "$TOOLBOX") || die "run.sh: cannot inspect $TOOLBOX"
    [[ $driver == k8s-file ]] ||
        die "run.sh: $TOOLBOX logs to $driver, not k8s-file; toolbox run's --follow needs k8s-file without systemd"
    (cd "$HOME" && toolbox run --container "$TOOLBOX" sh -c 'command -v pylsp rust-analyzer typescript-language-server' >"$OUT/servers.txt") || true
fi
result=$(sed -n 's/.*APEXBUILDER //p' "$OUT/run.log" | tail -n 1)
[[ -n $result ]] || die "run.sh: no result (exit $rc); see ${OUT#"$APEX_ROOT/"}/run.log"
printf '%s\n' "$result" | jq . >"$OUT/run.json"
jq -e '.error == null' <<<"$result" >/dev/null || die "run.sh: the probe failed: $(jq -r .error <<<"$result")"

fails=0
# check WHAT JQ: one fact about the run, against run.json.
check() {
    if jq -e --argjson ff "$FIRST_FRAME_MS" --argjson rss "$RSS_MIB" --argjson pss "$PSS_MIB" --argjson stall "$STALL_MS" --argjson glue "$GLUE_MIB" \
        'def median: sort | .[length / 2 | floor]; '"$2" "$OUT/run.json" >/dev/null; then
        log "ok: $1"
    else
        log "not ok: $1"
        fails=$((fails + 1))
    fi
}

check "the window is titled Apex Code" '.starts | all(.title | startswith("Apex Code — "))'
check "cold start to the first painted frame, median of 3: at most ${FIRST_FRAME_MS} ms" '[.starts[].painted] | median <= $ff'
check "idle RSS of Apex Code's own processes, median of 10: at most ${RSS_MIB} MiB" '[.idle.samples[].rss] | median / 1024 <= $rss'
check "idle PSS, median of 10: at most ${PSS_MIB} MiB" '[.idle.samples[].pss] | median / 1024 <= $pss'
check "the language servers run through the toolbox's bridge, not a podman exec each" '.idle.samples[-1].apart | (any(test("apex-toolbox-exec ")) and all(startswith("podman exec") | not))'
check "the toolbox runtime's host side (clients, bridge, conmon), median of 10: at most ${GLUE_MIB} MiB RSS" '[.idle.samples[].glue.rss] | median / 1024 <= $glue'
check "the editor is named for its file" '.idle.names.nodes | any(.role == "text" and .name == "Editor for e1_lsp.py")'
for name in "New Page" "Build Details" "Sidebar Menu" "Open Pages" "Run Options"; do
    check "\"$name\" names a button and its toggle" \
        "[.idle.names.nodes[] | select(.name == \"$name\") | .role] | (index(\"button\") != null and index(\"toggle button\") != null)"
done
check "the Run button is named for running the project" '.idle.names.nodes | any(.role == "button" and (.name | startswith("Run Project")))'
check "no button, toggle button, tab list, progress bar, entry, list or label is unnamed" '.idle.names.nodes | all(.role == "text" or .name != "")'
check "the diagnostics button is named for its counts, not \"0 0\"" '.idle.names.nodes | any(.role == "button" and (.name | test("^Build Diagnostics: [0-9]+ errors?, [0-9]+ warnings?$")))'
check "the diagnostics button is named before any page has focus" '.idle.noPage.nodes | any(.role == "button" and (.name | test("^Build Diagnostics: [0-9]+ errors?, [0-9]+ warnings?$")))'
check "the diagnostics popover's tab list is not named \"Panels\"" '.idle.popover.pressed and ([.idle.popover.names.nodes[] | select(.role == "page tab list" and .name == "Panels")] | length) == ([.idle.names.nodes[] | select(.role == "page tab list" and .name == "Panels")] | length)'
check "the diagnostics popover's tab list is named \"Diagnostics\"" '.idle.popover.pressed and (.idle.popover.names.nodes | any(.role == "page tab list" and .name == "Diagnostics"))'
check "the page's progress bar is named \"Progress\", for loading and saving alike" '.idle.names.nodes | any(.role == "progress bar" and .name == "Progress")'
check "\"Sidebar views\" names the sidebar's switcher, whose segments are the boards' views, \"Project\" selected" \
    '[.idle.names.nodes | to_entries[] | select(.value.role == "page tab list" and .value.name == "Sidebar views") | .key] as [$i]
     | $i != null and [.idle.names.nodes[$i + 1:][] | select(.role == "radio button") | .name][:1] == ["Project"]'
check "the sidebar's pages the boards do not show move to the bottom panel: Build Targets, Manuals, To-Do, Unit Tests" \
    '.typing.toBottom | unique | length == 4'
check "\"Panels\" names the bottom panel's switcher, open, and not the closed one" \
    '(.idle.bottom.nodes | any(.role == "page tab list" and .name == "Panels")) and (.idle.names.nodes | any(.name == "Panels") | not)'
check "the bottom panel's tabs: Build Targets, Manuals, To-Do, Unit Tests, each named and taking keyboard focus" \
    '[.idle.bottom.nodes | to_entries[] | select(.value.role == "page tab list" and .value.name == "Panels") | .key] as [$i]
     | $i != null and ([.idle.bottom.nodes[$i + 1:][] | select(.role == "page tab")] as $tabs
     | ["Build Targets", "Manuals", "To-Do", "Unit Tests"] | all(. as $n | $tabs | any(.name == $n and .focusable)))
     and (.idle.bottom.nodes | all(.role != "page tab" or .name != ""))'
for name in "Pinned Pages" "Pages"; do
    check "\"$name\" names a tab list" ".idle.names.nodes | any(.role == \"page tab list\" and .name == \"$name\")"
done
check "the project tree and its filter are named" '[.idle.names.nodes[] | select(.role == "list" or .role == "entry") | .name] | (index("Project Tree") != null and index("Filter…") != null)'
check "every typed key drew a frame" '.typing.keys | length > 300 and all(. != null)'
check "typing for 60 s from a fresh start: no key over ${STALL_MS} ms" '.typing.keys | max <= $stall'
check "pylsp in the toolbox answers a completion, the toolbox stopped before the session" '.typing.completionItems > 0'
check "only the podman and host runtimes are looked up off the main thread; jhbuild's lookups stay on it" \
    '(.typing.offThread + .jhbuild.offThread) as $off | ($off | length > 0 and all(startswith("podman:") or . == "host"))
     and (.jhbuild.left | index("jhbuild") != null) and ($off | index("jhbuild") == null)'
check "no program is looked up in the toolbox on the main thread, from the start to the completion" '.typing.lookups > 0 and (.typing.mainThreadLookups | length == 0)'
check "a podman container without which: each program looked up there at most twice, once on the main thread" \
    '.plain.lookups | length > 0 and all(.count <= 2 and .mainThread <= 1)'
check "typing for 60 s in that container's project: no key over ${STALL_MS} ms" '.plain.keys | length > 300 and all(. != null) and max <= $stall'
if $create; then
    check "Create Toolbox makes $TOOLBOX, and pylsp itself starts in it without reopening the project" '.create.lspInToolboxAfterS != null'
    check "toolbox create runs with XDG_RUNTIME_DIR, which rootless podman needs and Builder's launcher clears" '.create.createHasRuntimeDir'
fi
check "a toolbox of its image named dev: its servers checked under that name, and no false Finish Setup" \
    '.renamed.checkedByName and (.renamed.offersFinishSetup | not)'
check "with a server missing, Apex Code offers Finish Setup, and it installs the server again in dev" '.setup.removed and .setup.pressed and .setup.restoredAfterS != null'
check "Finish Setup on dev makes no second toolbox" '.setup.restoredAfterS != null and (.setup.secondToolbox | not)'
check "the restored pylsp spawns without reopening the project" '.setup.spawnedBefore == 0 and .setup.spawnedAfterS != null'
if [[ $(wc -l <"$OUT/servers.txt" 2>/dev/null) == 3 ]]; then
    log "ok: $TOOLBOX has pylsp, rust-analyzer and typescript-language-server"
else
    log "not ok: $TOOLBOX has pylsp, rust-analyzer and typescript-language-server"
    fails=$((fails + 1))
fi

jq -r '[
    "first frame (ms): \([.starts[].painted] | map(tostring) | join(", "))",
    "idle RSS/PSS (MiB): \([.idle.samples[].rss] | sort | .[5] / 1024 | floor)/\([.idle.samples[].pss] | sort | .[5] / 1024 | floor)",
    "glue RSS (MiB): \([.idle.samples[].glue.rss] | sort | .[5] / 1024 * 10 | floor / 10)",
    "longest key (ms): \(.typing.keys | max)",
    "completion items: \(.typing.completionItems)"
] | join("; ")' "$OUT/run.json" >&2
# Start times move with the runner's CPU from one CI run to the next: name it beside them.
log "machine: $(nproc) CPUs, $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | sort -u | head -n 1)"
((fails == 0)) || die "run.sh: $fails check(s) failed; see ${OUT#"$APEX_ROOT/"}/run.json"
log "run.sh: every check passed"
