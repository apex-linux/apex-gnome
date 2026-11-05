#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Apex Code's E1 lane case: started, named over AT-SPI, and answered by pylsp in fedora-toolbox-45, against E1's budgets.

# shellcheck disable=SC2016 # jq's programs and the session's bash -c name their own $ variables
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

usage() {
    cat <<USAGE
usage: tests/builder/run.sh [RPM_DIR]

Installs the lane's gnome-builder from RPM_DIR (_build/gnome-builder/out by default),
creates the fedora-toolbox-45 toolbox with the language servers Apex Code offers, and
runs a headless gnome-shell, as root, whose automation script (probe.js):
- starts Apex Code on a copy of this repository three times, after a discarded start,
  each after the page cache is dropped: E1's first frame, at most ${BUILDER_FIRST_FRAME_MS:-1900} ms (median);
- opens tests/e1_lsp.py, waits 30 s, and samples Apex Code's own process tree ten
  times: E1's RSS and PSS, at most ${BUILDER_RSS_MIB:-360} and ${BUILDER_PSS_MIB:-270} MiB (median);
- reads the editor's name and E0's eight unnamed buttons over AT-SPI;
- types into tests/e1_lsp.py and waits for pylsp, in the toolbox, to answer a completion.
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
readonly IMAGE=registry.fedoraproject.org/fedora-toolbox:45
readonly SETUP='sudo dnf -y -q install rust-analyzer cargo rust python3-lsp-server python3-pyflakes nodejs-npm && sudo npm install -g --no-fund --no-audit typescript-language-server typescript'
readonly FIRST_FRAME_MS=${BUILDER_FIRST_FRAME_MS:-1900}
readonly RSS_MIB=${BUILDER_RSS_MIB:-360}
readonly PSS_MIB=${BUILDER_PSS_MIB:-270}
readonly SHELL_TIMEOUT=900

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

group "fedora-toolbox-45"
# The toolbox shares the account's home from passwd; CI's HOME (/github/home) is not it.
HOME=$(getent passwd "$(id -un)" | cut -d: -f6)
export HOME SHELL=/bin/bash
# podman without systemd: no cgroup controllers to delegate, no journald, overlay through fuse.
mkdir -p /etc/containers
[[ -f /etc/containers/containers.conf ]] ||
    printf '[containers]\npids_limit=0\nlog_driver="k8s-file"\n[engine]\ncgroup_manager="cgroupfs"\nevents_logger="file"\n' >/etc/containers/containers.conf
[[ -f /etc/containers/storage.conf ]] ||
    printf '[storage]\ndriver="overlay"\n[storage.options.overlay]\nmount_program="/usr/bin/fuse-overlayfs"\n' >/etc/containers/storage.conf
# Fedora's toolbox loads through /run/host, which only tmpfiles.d/toolbox.conf links on a booted host.
[[ -e /run/host ]] || ln -s ../ /run/host
toolbox_failed() {
    tail -n 20 "$OUT/toolbox.log" >&2
    die "run.sh: $1; see ${OUT#"$APEX_ROOT/"}/toolbox.log"
}
if ! podman container exists "$TOOLBOX"; then
    toolbox create --assumeyes --image "$IMAGE" "$TOOLBOX" >"$OUT/toolbox.log" 2>&1 || toolbox_failed "toolbox create failed"
    toolbox run --container "$TOOLBOX" sh -c "$SETUP" >>"$OUT/toolbox.log" 2>&1 || toolbox_failed "the toolbox setup failed"
fi
(cd "$HOME" && toolbox run --container "$TOOLBOX" sh -c 'command -v pylsp rust-analyzer typescript-language-server' >"$OUT/servers.txt") ||
    die "run.sh: $TOOLBOX lacks a language server"
endgroup

project=$HOME/Projects/apex-gnome
rm -rf "$project" && mkdir -p "${project%/*}"
git -c safe.directory='*' -C "$APEX_ROOT" archive --format=tar --prefix=apex-gnome/ HEAD | tar -xf - -C "${project%/*}"
rm -f "$project/.buildconfig"
printf 'import os\n\n\ndef f(a):\n    return undefined_name + a\n' >"$project/tests/e1_lsp.py"

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
    APEX_BUILDER_PROJECT="$project" APEX_BUILDER_LSP_FILE="$project/tests/e1_lsp.py" \
    APEX_BUILDER_MEM="$HERE/mem.py" APEX_BUILDER_ATSPI="$HERE/atspi.py" APEX_BUILDER_DROP="$drop" \
    APEX_BUILDER_LOG="$OUT/builder-verbose.log" PROBE="$HERE/probe.js" \
    timeout "$SHELL_TIMEOUT" dbus-run-session -- bash -c '
        for setting in "enable-animations false" "cursor-blink false" "toolkit-accessibility true"; do
            gsettings set org.gnome.desktop.interface $setting
        done
        gsettings set org.gnome.desktop.notifications show-banners false
        gsettings set org.gnome.shell welcome-dialog-last-shown-version "999"
        exec gnome-shell --headless --virtual-monitor 1920x1080 --wayland-display=apex-builder --automation-script "$PROBE"
    ' >"$OUT/run.log" 2>&1 || rc=$?

result=$(sed -n 's/.*APEXBUILDER //p' "$OUT/run.log" | tail -n 1)
[[ -n $result ]] || die "run.sh: no result (exit $rc); see ${OUT#"$APEX_ROOT/"}/run.log"
printf '%s\n' "$result" | jq . >"$OUT/run.json"
jq -e '.error == null' <<<"$result" >/dev/null || die "run.sh: the probe failed: $(jq -r .error <<<"$result")"

fails=0
# check WHAT JQ: one fact about the run, against run.json.
check() {
    if jq -e --argjson ff "$FIRST_FRAME_MS" --argjson rss "$RSS_MIB" --argjson pss "$PSS_MIB" \
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
check "the editor is named for its file" '.idle.names.nodes | any(.role == "text" and .name == "Editor for e1_lsp.py")'
for name in "New Page" "Build Details" "Sidebar Menu" "Open Pages" "Run Options"; do
    check "\"$name\" names a button and its toggle" \
        "[.idle.names.nodes[] | select(.name == \"$name\") | .role] | (index(\"button\") != null and index(\"toggle button\") != null)"
done
check "the Run button is named for running the project" '.idle.names.nodes | any(.role == "button" and (.name | startswith("Run Project")))'
check "no button or toggle button is unnamed" '.idle.names.nodes | all(.role == "text" or .name != "")'
check "pylsp in the toolbox answers a completion" '.server.completionItems > 0'

jq -r '"first frame (ms): \([.starts[].painted] | map(tostring) | join(", ")); idle RSS/PSS (MiB): \([.idle.samples[].rss] | sort | .[5] / 1024 | floor)/\([.idle.samples[].pss] | sort | .[5] / 1024 | floor); completion items: \(.server.completionItems)"' "$OUT/run.json" >&2
((fails == 0)) || die "run.sh: $fails check(s) failed; see ${OUT#"$APEX_ROOT/"}/run.json"
log "run.sh: every check passed"
