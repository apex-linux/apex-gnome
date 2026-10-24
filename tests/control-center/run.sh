#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

readonly SHELL_TIMEOUT=180

usage() {
    cat <<EOF
usage: tests/control-center/run.sh [RPM_DIR]

Opens the Apex Desktop panel ('gnome-control-center apex') in a headless gnome-shell at
scale 2, as root in a throwaway fedora:$APEX_FEDORA container (just control-center-run).
RPM_DIR holds the lane's built RPMs (_build/control-center/out); without it the installed
gnome-control-center runs. For a user '$USER_NAME', with apex-desktop's schema from
tests/layer/fixtures, it captures board 11 at both scroll positions, light and dark, and
checks every row against its key both ways through AT-SPI (bindings.py). Without the
schema it captures and checks the explanation the panel shows instead. The captures and
logs land in _build/control-center/shots/.

It needs gnome-shell, mesa-dri-drivers, dbus-daemon, python3-dbusmock, python3-gobject,
at-spi2-core, gcc, util-linux and adwaita-sans-fonts. G2's clock.c and fixtures.py
(tests/shots) are used as they are.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
headless_require_container run.sh

out=$APEX_ROOT/_build/control-center/shots
rm -rf -- "$out"
mkdir -p -- "$out"
chmod 777 "$out"
[[ -z ${1:-} ]] || headless_install_rpms "$1"
rpm -q gnome-control-center >"$out/gnome-control-center.txt"

headless_manifest
headless_user
headless_bus "$out"

# run_case NAME SCHEME [NAME=VALUE...]: one shell; libadwaita has no settings portal here, so ADW_DEBUG_COLOR_SCHEME.
run_case() {
    local name=$1 scheme=$2
    shift 2
    headless_run "$out/$name.log" "$CC_TESTS/probe.js" "$SHELL_TIMEOUT" "" \
        APEX_SHOTS="$out" APEX_SHOT="$name" ADW_DEBUG_COLOR_SCHEME="$scheme" "$@"
    log "run.sh: $name: exit $?"
    grep -q 'APEXCC ' "$out/$name.log" && [[ -s $out/$name.png ]] || return 1
    ! grep -q '"check":false' "$out/$name.log"
}

status=0
headless_apex_schema yes
run_case light default APEX_SCROLL=1 APEX_CHECK=rows || status=1
run_case dark prefer-dark APEX_SCROLL=1 || status=1
headless_apex_schema no
run_case no-schema default APEX_CHECK=no-schema || status=1
grep -h '^ok \|^FAIL \|APEXCC-' "$out"/*.log || true
((status == 0)) || die "run.sh: a case failed; see ${out#"$APEX_ROOT/"}/*.log"
log "run.sh: every row is bound; captures in ${out#"$APEX_ROOT/"}"
