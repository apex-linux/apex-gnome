#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/headless.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/headless.sh"

S2C_TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly S2C_TESTS

readonly DEADLINE_MS=1000
readonly SHELL_TIMEOUT=180
readonly APEX_SCHEMA_FIXTURE=$S2C_TESTS/../layer/fixtures/io.github.apex_linux.Apex.Desktop.gschema.xml
readonly SCHEMA_DIR=/usr/share/glib-2.0/schemas
readonly AGENT=/usr/libexec/apex/apex-session-agent
readonly RED='#ff0000'
readonly RED_UUID=5e2c0000000000000000000000000ed0
readonly RED_SCHEMA=org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$RED_UUID/

usage() {
    cat <<EOF
usage: tests/s2c/radius-test.sh RPM_DIR AGENT

S2c's live window radius, end to end, in a headless gnome-shell at scale 2: with
apex-session-agent (AGENT, from tests/s2c/agent.sh) running and window-corner-radius
at 14, it opens Ptyxis, Files and Settings' Apex Desktop panel beside a maximised Ptyxis,
presses the Corner Radius row's "0" through AT-SPI, and fails unless every open window
turns square within $DEADLINE_MS ms of the press while the maximised one stays square.
RPM_DIR holds the lanes' libadwaita, gnome-control-center and nautilus RPMs. As root in a
throwaway fedora:$APEX_FEDORA container with ptyxis, gnome-shell, mesa-dri-drivers,
dbus-daemon, dconf, python3-dbusmock, python3-gobject, at-spi2-core, gcc, util-linux and
jq; the captures (s2c-14.png, s2c-0.png) and logs land in _build/s2c/radius/.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
(($# == 2)) || { usage >&2; exit 2; }
headless_require_container radius-test.sh
for program in ptyxis dconf python3 jq; do
    command -v "$program" >/dev/null || die "radius-test.sh: no $program"
done
[[ -x $2 ]] || die "radius-test.sh: no agent at $2 (tests/s2c/agent.sh)"

out=$APEX_ROOT/_build/s2c/radius
rm -rf -- "$out"
mkdir -p -- "$out"
chmod 777 "$out"

shopt -s nullglob
rpms=("$1"/libadwaita-[0-9]*.x86_64.rpm "$1"/gnome-control-center-[0-9]*.x86_64.rpm
    "$1"/gnome-control-center-filesystem-[0-9]*.noarch.rpm "$1"/nautilus-[0-9]*.x86_64.rpm
    "$1"/nautilus-extensions-[0-9]*.x86_64.rpm)
shopt -u nullglob
((${#rpms[@]} == 5)) || die "radius-test.sh: expected libadwaita, gnome-control-center(-filesystem) and nautilus(-extensions) in $1"
dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install "${rpms[@]}" ||
    die "radius-test.sh: cannot install ${rpms[*]}"
rpm -q libadwaita gnome-control-center nautilus ptyxis >"$out/rpms.txt"
grep -q 'libadwaita-.*\.apex' "$out/rpms.txt" || die "radius-test.sh: the installed libadwaita is not the lane's"
install -D -m 755 "$2" "$AGENT"
install -m 644 "$APEX_SCHEMA_FIXTURE" "$SCHEMA_DIR/"
glib-compile-schemas "$SCHEMA_DIR" || die "radius-test.sh: glib-compile-schemas failed"

headless_user
home=$HEADLESS_HOME
palettes=$home/.local/share/org.gnome.Ptyxis/palettes
install -d -o "$USER_NAME" "$home/.local" "$home/.local/share" "$home/.local/share/org.gnome.Ptyxis" "$palettes"
{
    printf '[Palette]\nName=S2c Red\nBackground=%s\nForeground=%s\nCursor=%s\n' "$RED" "$RED" "$RED"
    for i in $(seq 0 15); do printf 'Color%d=%s\n' "$i" "$RED"; done
} >"$palettes/s2c-red.palette"
chown -R "$USER_NAME:" "$home"
headless_bus "$out"

# The container has no settings portal for libadwaita to read color-scheme from.
headless_run "$out/s2c.log" "$S2C_TESTS/probe.js" "$SHELL_TIMEOUT" \
    "org.gnome.Ptyxis interface-style 'light'
org.gnome.Ptyxis profile-uuids ['$PROFILE_UUID', '$RED_UUID']
$RED_SCHEMA label 'S2c Red'
$RED_SCHEMA palette 's2c-red'
io.github.apex_linux.Apex.Desktop window-corner-radius 14" \
    XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME ADW_DEBUG_COLOR_SCHEME=default \
    RUST_LOG=info APEX_SHELL_GUARD_MARKER=/tmp/apex-s2c-guard APEX_AGENT="$AGENT" \
    APEX_AGENT_LOG="$out/agent.log" APEX_CLICK="$S2C_TESTS/click.py" APEX_RED_PROFILE="$RED_UUID" APEX_SHOTS="$out" \
    APEX_CSS_FILE="$home/.config/gtk-4.0/apex.css"
log "radius-test.sh: shell exit $?"

result=$(sed -n 's/.*APEXS2C //p' "$out/s2c.log")
[[ -n $result ]] || die "radius-test.sh: no result; see ${out#"$APEX_ROOT/"}/s2c.log"
log "radius-test.sh: $result"
jq -r '.windows | to_entries[] | "radius-test.sh: \(.key): \(.value.ms // "-") ms"' <<<"$result" || true
check() {
    jq -e --argjson deadline "$DEADLINE_MS" "$1" <<<"$result" >/dev/null || die "radius-test.sh: $2: $result"
}
check '.error == null' "the probe failed"
check '.agent_running and .agent_running_after' "apex-session-agent was not running throughout"
check '.maximised and .windows.maximised.before.square and .windows.maximised.after.square' \
    "the maximised window was not square before and after"
check '[.windows.ptyxis, .windows.files, .windows.settings] | all(.before.square == false)' \
    "a window was not rounded at 14 px before the press"
check '.key == 0 and (.css | test(":root \\{ --window-radius: 0px;"))' "the press did not reach window-corner-radius and apex.css"
# shellcheck disable=SC2016 # jq's own $deadline
check '[.windows.ptyxis, .windows.files, .windows.settings] | all(.after.square and .ms <= $deadline)' \
    "a window did not turn square within $DEADLINE_MS ms of the press"
log "radius-test.sh: Ptyxis, Files and Settings took the 0 px radius live; captures in ${out#"$APEX_ROOT/"}"
