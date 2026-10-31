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
RPM_DIR holds the lane's built RPMs (_build/gnome-control-center/out); without it the installed
gnome-control-center runs. For a user '$USER_NAME', with apex-desktop's schema from
tests/layer/fixtures, it captures board 11 at both scroll positions, light and dark, and
checks every row against its key both ways through AT-SPI (bindings.py). Without the
schema it captures and checks the explanation the panel shows instead. It captures
Appearance (board 23) light and dark on a gnome-backgrounds wallpaper, and appearance.py
checks that the name and note follow the wallpaper. It captures Power (board 24) with an
NVIDIA card under umockdev, and power.py checks the Graphics and Display group: the refresh
row against its key both ways, and the card's row following power/runtime_status. With
apex-desktop's keybindings and schema override ($APEX_DESKTOP_REV, or APEX_DESKTOP_SRC, a
checkout), installed for that case only, it opens Keyboard, and keyboard.py checks that the
shortcut list shows Open Spotlight on Super+Space and the input-source switch on
Alt+Super+Space and Shift+Alt+Super+Space. Then, with
update1.py standing in for apex-updated on the system bus, it opens System > Software
Updates and captures board 18 light and dark, and updates.py checks each state's texts
and that each button makes its Update1 call; board 26's two dialogs are captured dark too. The captures and logs land in
_build/control-center/shots/.

It needs gnome-shell, mesa-dri-drivers, dbus-daemon, python3-dbusmock, python3-gobject,
at-spi2-core, gcc, util-linux, adwaita-sans-fonts, python3-dbus, systemd,
gnome-backgrounds, umockdev and git-core. G2's clock.c and fixtures.py
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
# CASE_SETTINGS holds extra "schema key value" lines for that shell.
run_case() {
    local name=$1 scheme=$2
    shift 2
    headless_run "$out/$name.log" "$CC_TESTS/probe.js" "$SHELL_TIMEOUT" "${CASE_SETTINGS:-}" \
        APEX_SHOTS="$out" APEX_SHOT="$name" ADW_DEBUG_COLOR_SCHEME="$scheme" "$@"
    log "run.sh: $name: exit $?"
    grep -q 'APEXCC ' "$out/$name.log" && [[ -s $out/$name.png ]] || return 1
    ! grep -q '"check":false\|"ready":false\|"before":false' "$out/$name.log"
}

status=0
headless_apex_schema yes
run_case light default APEX_SCROLL=1 "APEX_CHECK=bindings.py rows" || status=1
run_case dark prefer-dark APEX_SCROLL=1 || status=1
headless_apex_schema no
run_case no-schema default "APEX_CHECK=bindings.py no-schema" || status=1
headless_apex_schema yes
# Board 23: amber.xml's wallpaper as it lists it, so the chooser has an active item to ring.
amber="org.gnome.desktop.background picture-uri 'file:///usr/share/backgrounds/gnome/amber-l.jxl'
org.gnome.desktop.background picture-uri-dark 'file:///usr/share/backgrounds/gnome/amber-d.jxl'
org.gnome.desktop.background primary-color '#F57511'
org.gnome.desktop.background secondary-color '#DD4C38'"
CASE_SETTINGS=$amber run_case appearance-light default APEX_OPEN=background APEX_SCROLL=1 APEX_READY=thumbnails.py \
    "APEX_CHECK=appearance.py amber" || status=1
CASE_SETTINGS=$amber run_case appearance-dark prefer-dark APEX_OPEN=background APEX_SCROLL=1 APEX_READY=thumbnails.py \
    || status=1
run_case appearance-custom default APEX_OPEN=background APEX_READY=thumbnails.py "APEX_CHECK=appearance.py custom" \
    || status=1

# Board 24: Power with headless_dgpu's graphics under umockdev, then without an NVIDIA card.
headless_dgpu "$out/dgpu.devices"
dgpu="APEX_LAUNCH=umockdev-run -d $out/dgpu.devices --"
run_case power-light default APEX_OPEN=power APEX_SCROLL=1 "$dgpu" "APEX_CHECK=power.py dgpu" || status=1
run_case power-dark prefer-dark APEX_OPEN=power APEX_SCROLL=1 "$dgpu" || status=1
run_case power-no-dgpu default APEX_OPEN=power "APEX_CHECK=power.py plain" || status=1

# S1b: Spotlight and the input-source switch in Keyboard's shortcut list, on apex-desktop's keys.
headless_apex_desktop yes
run_case keyboard default APEX_OPEN=keyboard APEX_SCROLL=1 "APEX_CLICK=keyboard.py locate" "APEX_CHECK=keyboard.py" || status=1
headless_apex_desktop no

# update_case SCENARIO NAME SCHEME [NAME=VALUE...]: System > Software Updates on update1.py's SCENARIO.
update_case() {
    local scenario=$1 name=$2 scheme=$3 log=$out/update1-$2.log
    shift 3
    if [[ $scenario == unavailable ]]; then
        headless_update1_stop
    else
        headless_update1 "$scenario" "$log"
    fi
    run_case "$name" "$scheme" "APEX_OPEN=system software-updates" APEX_UPDATE1_LOG="$log" "$@"
}

update_case ready updates-light default APEX_SCROLL=1 "APEX_CHECK=updates.py ready" || status=1
update_case ready updates-dark prefer-dark APEX_SCROLL=1 || status=1
for scenario in up-to-date available waiting downloading health-failure fallback unavailable; do
    update_case "$scenario" "updates-$scenario" default "APEX_CHECK=updates.py $scenario" || status=1
done
# Board 26 dark: its two dialogs.
for scenario in health-failure fallback; do
    update_case "$scenario" "updates-$scenario-dark" prefer-dark || status=1
done
update_case fallback updates-fallback-changes default "APEX_BEFORE=updates.py show-changes" || status=1
headless_update1_stop
grep -h '^ok \|^FAIL \|APEXCC-' "$out"/*.log || true
((status == 0)) || die "run.sh: a case failed; see ${out#"$APEX_ROOT/"}/*.log"
log "run.sh: every row is bound, Appearance, Power and Keyboard check out and every Software Updates state is checked; captures in ${out#"$APEX_ROOT/"}"
