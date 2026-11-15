#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
HEADLESS_NO_PTYXIS=1
# shellcheck source=SCRIPTDIR/../lib/headless.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/headless.sh"

BUILDER_TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly BUILDER_TESTS
readonly SHELL_TIMEOUT=180

usage() {
    cat <<EOF
usage: tests/builder/shoot.sh [RPM_DIR]

Captures Apex Code in a headless gnome-shell at scale 2, light and dark, as root in a
throwaway fedora:$APEX_FEDORA container. RPM_DIR holds the lane's built RPMs
(_build/gnome-builder/out); without it the installed gnome-builder is captured. A user
'$USER_NAME' opens fixture.sh's apex-gnome project with dock.js, board 40's file, in a
1240x762 window at the board's place. The captures and logs land in _build/gnome-builder/shots/.

It needs gnome-shell, mesa-dri-drivers, dbus-daemon, python3-dbusmock, gcc, git-core and the
Apex fonts (jetbrains-mono-fonts-all, adwaita-sans-fonts), python3-gobject and at-spi2-core for
atspi.py, which must find the editor and the project tree named; and no podman: without it, Apex Code
offers no toolbox, which the boards do not show.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
headless_require_container shoot.sh
! command -v podman >/dev/null || die "shoot.sh: podman is installed, so Apex Code would offer a toolbox the boards do not show"

out=$APEX_ROOT/_build/gnome-builder/shots
rm -rf -- "$out"
mkdir -p -- "$out"
chmod 777 "$out"
[[ -z ${1:-} ]] || headless_install_rpm "$1" gnome-builder
rpm -q gnome-builder >"$out/gnome-builder.txt"

headless_user
project=$HEADLESS_HOME/Projects/apex-gnome
runuser -u "$USER_NAME" -- bash "$BUILDER_TESTS/fixture.sh" "$project" || die "shoot.sh: fixture.sh failed"
headless_bus "$out"

shoot() {
    local name=$1 variant=$2 rc=0 crash
    local settings="org.gnome.builder style-variant '$variant'"$'\n'"org.gnome.builder restore-previous-files false"
    settings+=$'\n'"org.gnome.desktop.interface toolkit-accessibility true"
    headless_run "$out/$name.log" "$BUILDER_TESTS/shoot-probe.js" "$SHELL_TIMEOUT" "$settings" \
        APEX_SHOTS="$out" APEX_SHOT="$name" APEX_BUILDER_PROJECT="$project" APEX_BUILDER_ATSPI="$BUILDER_TESTS/atspi.py" \
        APEX_BUILDER_FILE=desktop/shell/js/ui/apex/dock/dock.js GDK_DEBUG=no-portals ADW_DISABLE_PORTAL=1 || rc=$?
    log "shoot.sh: $name: exit $rc"
    if crash=$(shell_crash "$out/$name.log" "$rc"); then log "shoot.sh: $name: $crash"; return 1; fi
    grep -q 'APEXBUILDERSHOT ' "$out/$name.log" && [[ -s $out/$name.png ]]
}

status=0
shoot light light || status=1
shoot dark dark || status=1
((status == 0)) || die "shoot.sh: a capture failed; see ${out#"$APEX_ROOT/"}/*.log"
log "shoot.sh: captures in ${out#"$APEX_ROOT/"}"
