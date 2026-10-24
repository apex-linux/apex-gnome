#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/headless.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/headless.sh"
# shellcheck source=SCRIPTDIR/../lib/pins.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/pins.sh"

S7_TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly S7_TESTS

readonly DEADLINE_MS=1000
readonly SHELL_TIMEOUT=180
readonly ACCENTS=(blue green pink)
readonly FOLDER=apexs7
readonly APEX_SCHEMA_FIXTURE=$S7_TESTS/../layer/fixtures/io.github.apex_linux.Apex.Desktop.gschema.xml
readonly SCHEMA_DIR=/usr/share/glib-2.0/schemas
readonly ICONS=/usr/share/icons
readonly AGENT=/usr/libexec/apex/apex-session-agent

usage() {
    cat <<EOF
usage: tests/s7/accent-test.sh RPM_DIR AGENT

S7's accent exit, end to end, in a headless gnome-shell at scale 2: Files on ~ in its grid,
GTK's file chooser on ~ and Spotlight on a query that finds the folder ~/$FOLDER, with
apex-session-agent (AGENT, from tests/s2c/agent.sh) running and the accent ${ACCENTS[0]}.
The accent then turns ${ACCENTS[*]:1}, one after the other, and each time all three must
draw the folder's body in the new accent's folder colour within $DEADLINE_MS ms. A second
shell, the control, runs without the agent and must still draw ${ACCENTS[0]} folders after
both changes. check.sh asserts both runs. The folder themes are apex-desktop
$APEX_DESKTOP_REV's (or APEX_DESKTOP_SRC, a checkout), built with its build-places.sh.
RPM_DIR holds the gnome-shell lane's RPMs. As root in a throwaway fedora:$APEX_FEDORA
container with nautilus, gjs, gtk4, ptyxis (whose settings the harness sets), mesa-dri-drivers, dbus-daemon, python3-dbusmock,
python3-gobject, gcc, util-linux, git-core and jq; captures and logs land in _build/s7/accent/.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
(($# == 2)) || { usage >&2; exit 2; }
headless_require_container accent-test.sh
for program in nautilus gjs python3 jq git; do
    command -v "$program" >/dev/null || die "accent-test.sh: no $program"
done
[[ -x $2 ]] || die "accent-test.sh: no agent at $2 (tests/s2c/agent.sh)"

out=$APEX_ROOT/_build/s7/accent
rm -rf -- "$out"
mkdir -p -- "$out"
chmod 777 "$out"

shopt -s nullglob
rpms=("$1"/gnome-shell-[0-9]*.x86_64.rpm "$1"/gnome-shell-common-[0-9]*.noarch.rpm)
shopt -u nullglob
((${#rpms[@]} == 2)) || die "accent-test.sh: expected the gnome-shell and gnome-shell-common RPMs in $1"
dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install "${rpms[@]}" ||
    die "accent-test.sh: cannot install ${rpms[*]}"
rpm -q gnome-shell nautilus gtk4 >"$out/rpms.txt"
grep -q 'gnome-shell-.*\.apex' "$out/rpms.txt" || die "accent-test.sh: the installed gnome-shell is not the lane's"
install -D -m 755 "$2" "$AGENT"
install -m 644 "$APEX_SCHEMA_FIXTURE" "$SCHEMA_DIR/"
glib-compile-schemas "$SCHEMA_DIR" || die "accent-test.sh: glib-compile-schemas failed"

desktop=${APEX_DESKTOP_SRC:-$APEX_ROOT/_build/s7/apex-desktop}
if [[ -z ${APEX_DESKTOP_SRC:-} ]]; then
    group "apex-desktop $APEX_DESKTOP_REV"
    git_() { git -c safe.directory='*' "$@"; }
    [[ -d $desktop/.git ]] || git_ init -q "$desktop"
    if [[ $(git_ -C "$desktop" rev-parse -q --verify HEAD 2>/dev/null) != "$APEX_DESKTOP_REV" ]]; then
        git_ -C "$desktop" fetch -q --depth 1 "$APEX_DESKTOP_URL" "$APEX_DESKTOP_REV" || die "accent-test.sh: cannot fetch apex-desktop"
        git_ -C "$desktop" checkout -q --detach "$APEX_DESKTOP_REV" || die "accent-test.sh: cannot check out apex-desktop"
    fi
    endgroup
fi
icons=$desktop/desktop/icons
bash "$icons/build-places.sh" "$ICONS" "$icons/places/folder.svg" "$icons/places/emblems" "$icons/accents" ||
    die "accent-test.sh: build-places.sh failed"
install -m 644 "$icons/index.theme" "$ICONS/Apex/index.theme"

# build-places.sh's colours: each accent's folder front, and its tab at 68 % of it.
accents_json=$(
    for accent in "${ACCENTS[@]}"; do
        front=$(awk -v a="$accent" '$1 == a { print $2 }' "$icons/accents")
        [[ $front =~ ^#[0-9a-f]{6}$ ]] || die "accent-test.sh: apex-desktop's accents has no $accent"
        tab='#'
        for i in 1 3 5; do printf -v tab '%s%02x' "$tab" $(((16#${front:i:2} * 68 + 50) / 100)); done
        jq -nc --arg name "$accent" --arg front "$front" --arg tab "$tab" '{name: $name, front: $front, tab: $tab}'
    done | jq -sc .
)

headless_user
home=$HEADLESS_HOME
install -d -o "$USER_NAME" "$home/$FOLDER"
chown -R "$USER_NAME:" "$home"
headless_bus "$out"

settings="org.gnome.desktop.interface icon-theme 'Apex'
org.gnome.desktop.interface accent-color '${ACCENTS[0]}'
org.gnome.nautilus.preferences default-folder-viewer 'icon-view'"
run_shell() {
    local name=$1
    shift
    # The container has no settings portal, so GTK reads icon-theme from GSettings.
    headless_run "$out/$name.log" "$S7_TESTS/probe.js" "$SHELL_TIMEOUT" "$settings" \
        XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME APEX_SHOTS="$out" APEX_RUN="$name" APEX_FOLDER="$FOLDER" \
        APEX_ACCENTS="$accents_json" APEX_CHOOSER="$S7_TESTS/chooser.js" "$@"
    log "accent-test.sh: $name shell exit $?"
    jq -nc --argjson accents "$accents_json" --argjson deadline "$DEADLINE_MS" --arg folder "$FOLDER" \
        --argjson result "$(sed -n 's/.*APEXS7 //p' "$out/$name.log" | tail -n 1 | grep . || echo null)" \
        '{accents: $accents, deadlineMs: $deadline, folder: $folder, result: $result}' >"$out/$name.json"
}
run_shell main RUST_LOG=info APEX_AGENT="$AGENT" APEX_AGENT_LOG="$out/agent.log"
run_shell control

status=0
"$S7_TESTS/check.sh" main "$out/main.json" || status=1
"$S7_TESTS/check.sh" control "$out/control.json" || status=1
((status == 0)) || die "accent-test.sh: see ${out#"$APEX_ROOT/"}"
log "accent-test.sh: Files, the file chooser and Spotlight took each accent's folders live; captures in ${out#"$APEX_ROOT/"}"
