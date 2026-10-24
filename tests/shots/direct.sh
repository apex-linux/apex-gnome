#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat <<'EOF'
usage: direct.sh main|kernel|fedora

G2's direct cases, run by run.sh as root in a throwaway container of its bus image (the
built image plus dbus-daemon), with tests/shots at /w (read-only) and the run's results
at /out. Each case is one headless shell under its own dbus-run-session, with a fresh
HOME and XDG_RUNTIME_DIR, a 2880x1800 virtual monitor at scale 2 (default-scale1:
1440x900 at scale 1, as the desktop VM runs) and probe.js as its automation script;
/out/CASE.log gets its output, /out/results-PART.txt its exit status. Every shell sees
fixtures.py's python-dbusmock services on the system bus (/out/fixtures-PART.txt) and a
wall clock that clock.c holds at G2_CLOCK. A case that times out stops the part (exit 3).
G2_SURFACE_SCENES=1 in direct.sh's environment also captures the shell surfaces' scenes.
The glass cases read frames through frame.c, built with glib2-devel's headers and
gi-compile-repository.

  main     every case, with the VM's real /proc/cmdline
  kernel   the apex.safe=1 case (run.sh binds a fixture over /proc/cmdline)
  fedora   the captures of Fedora's own gnome-shell build (run.sh's baseline image)
EOF
}

case ${1:-} in
    main | kernel | fedora) part=$1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
# It stops logind's seats and changes /run as root: never outside a throwaway container.
[[ -e /run/.containerenv || -e /.dockerenv ]] || { echo "direct.sh: only inside run.sh's or smoke.sh's container" >&2; exit 2; }

readonly SHELL_TIMEOUT=150
readonly EXIT_HUNG=3
readonly CLOCK_LIB=/run/g2-clock.so
readonly FRAME_DIR=/run/g2-frame
readonly G2_CLOCK='2026-09-28 09:41:00'
G2_CLOCK_EPOCH=$(date -u -d "$G2_CLOCK" +%s)
readonly G2_CLOCK_EPOCH
readonly FIXTURE_NAMES=(org.freedesktop.UPower org.freedesktop.NetworkManager org.bluez net.hadess.SwitcherooControl
    org.freedesktop.UPower.PowerProfiles)
# Two fixed workspaces: stock widens the active workspace dot by a factor that depends on
# the count. A 24-hour clock: in 12 hours a one-digit hour adds a figure space.
readonly NO_HOT_CORNER='org.gnome.desktop.interface enable-hot-corners false'
readonly TWO_SOURCES="org.gnome.desktop.input-sources sources [('xkb', 'us'), ('xkb', 'fr')]"
readonly CAPTURE_SETTINGS='org.gnome.desktop.interface enable-animations false;org.gnome.desktop.interface cursor-blink false;org.gnome.mutter dynamic-workspaces false;org.gnome.desktop.wm.preferences num-workspaces 2;org.gnome.desktop.interface clock-format 24h;org.gnome.desktop.interface show-battery-percentage true'

# The motion case needs animations, which the captures turn off.
readonly MOTION_SETTINGS=${CAPTURE_SETTINGS/enable-animations false/enable-animations true}

cat /proc/cmdline >"/out/cmdline-$part.txt"
# gnome-shell's loginManager.js takes its dummy manager only when /run/systemd/seats is
# missing, and timeLimitsManager.js needs a system bus.
rm -rf /run/systemd/seats
mkdir -p /run/dbus
# system.conf includes this file last: root may own the fixtures' names and call them.
mkdir -p /etc/dbus-1
{
    echo '<busconfig><policy user="root">'
    for name in "${FIXTURE_NAMES[@]}"; do
        printf '<allow own="%s"/><allow send_destination="%s"/>\n' "$name" "$name"
    done
    echo '</policy></busconfig>'
} >/etc/dbus-1/system-local.conf
dbus-daemon --system --fork || echo "no system bus"
mkdir -p "/out/fixtures-$part"
G2_POWER_PROFILES=1 python3 /w/fixtures.py "/out/fixtures-$part" >"/out/fixtures-$part.txt" 2>&1 || echo "fixtures.py: exit $?"
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
gcc -O2 -Wall -Werror -shared -fPIC -o "$CLOCK_LIB" /w/clock.c || { echo "direct.sh: cannot build clock.c" >&2; exit 1; }
# ld.so only warns when a preload is missing, and the shells would keep the real clock.
held=$(env LD_PRELOAD="$CLOCK_LIB" G2_CLOCK_EPOCH="$G2_CLOCK_EPOCH" date -u '+%F %T' 2>&1)
[[ $held == "$G2_CLOCK" ]] || { echo "direct.sh: $CLOCK_LIB does not hold the clock at $G2_CLOCK: $held" >&2; exit 1; }
# The glass cases read the frames the shell drew through frame.c (G2Frame-1.gir).
mkdir -p "$FRAME_DIR"
# shellcheck disable=SC2046 # pkg-config prints several flags
if ! gcc -O2 -Wall -Werror -shared -fPIC $(pkg-config --cflags glib-2.0) -o "$FRAME_DIR/libg2frame.so" /w/frame.c ||
    ! gi-compile-repository --includedir=/usr/share/gir-1.0 -o "$FRAME_DIR/G2Frame-1.typelib" /w/G2Frame-1.gir; then
    echo "direct.sh: cannot build frame.c and its typelib" >&2
    exit 1
fi

run_case() {
    local name=$1 gsettings_triples=$2
    shift 2
    local home=/tmp/g2/$name/home run=/tmp/g2/$name/run start=$SECONDS rc left=no
    rm -rf "/tmp/g2/$name"
    mkdir -p "$home" "$run"
    chmod 700 "$run"
    # shellcheck disable=SC2016 # expanded by the case's own bash
    env -i HOME="$home" PATH=/usr/bin:/usr/sbin XDG_RUNTIME_DIR="$run" LANG=C.UTF-8 \
        DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket \
        G2_CASE="$name" G2_CAPTURES=/out/captures G2_SETTINGS="$gsettings_triples" \
        G2_SCALE=2 G2_MONITOR=2880x1800 TZ=UTC G2_CLOCK_LIB="$CLOCK_LIB" G2_CLOCK_EPOCH="$G2_CLOCK_EPOCH" \
        G2_SURFACE_SCENES="${G2_SURFACE_SCENES:-0}" G2_WAYLAND_DISPLAY=apex-g2 "$@" \
        timeout "$SHELL_TIMEOUT" dbus-run-session -- bash -c '
            set -u
            gsettings set org.gnome.desktop.interface scaling-factor "$G2_SCALE"
            gsettings set org.gnome.shell welcome-dialog-last-shown-version "\"999\""
            IFS=";" read -ra triples <<<"$G2_SETTINGS"
            for t in "${triples[@]}"; do
                [ -n "$t" ] || continue
                read -r schema key value <<<"$t"
                gsettings set "$schema" "$key" "$value"
            done
            echo "G2-SETTINGS scaling-factor=$(gsettings get org.gnome.desktop.interface scaling-factor)" \
                "color-scheme=$(gsettings get org.gnome.desktop.interface color-scheme)" \
                "layer-enabled=$(gsettings get io.github.apex_linux.Apex.Desktop layer-enabled)"
            # Only reads of the wall clock stand still: timers and frames keep the real clocks.
            exec env LD_PRELOAD="$G2_CLOCK_LIB" \
                gnome-shell --headless --virtual-monitor "$G2_MONITOR" \
                --wayland-display="$G2_WAYLAND_DISPLAY" --automation-script /w/probe.js
        ' >"/out/$name.log" 2>&1
    rc=$?
    [[ -e $run/apex-shell-starting ]] && left=yes
    RESULT="$name exit=$rc secs=$((SECONDS - start)) marker-after-exit=$left"
    echo "== $name: exit $rc, marker after exit: $left"
}

# A late probe means main.js's startup-complete handler never ran in that shell.
run_and_record_case() {
    local name=$1
    run_case "$@"
    if grep -q 'APEXG2-LATE' "/out/$name.log"; then
        mv "/out/$name.log" "/out/$name.late.log"
        echo "== $name: the probe started late; once more"
        run_case "$@"
    fi
    printf '%s\n' "$RESULT" >>"/out/results-$part.txt"
    if [[ $RESULT == "$name exit=124 "* ]]; then
        echo "== $name: no report within $SHELL_TIMEOUT s; the shell hung, and the cases after it would wait as long"
        exit "$EXIT_HUNG"
    fi
}

: >"/out/results-$part.txt"
case $part in
    kernel)
        run_and_record_case kernel-safe ''
        exit 0 ;;
    fedora)
        run_and_record_case fedora-light "$CAPTURE_SETTINGS;org.gnome.desktop.interface color-scheme prefer-light" G2_SCENES=1
        run_and_record_case fedora-dark "$CAPTURE_SETTINGS;org.gnome.desktop.interface color-scheme prefer-dark" G2_SCENES=1
        run_and_record_case fedora-glass "$CAPTURE_SETTINGS" G2_GLASS=1
        exit 0 ;;
esac

run_and_record_case default "$CAPTURE_SETTINGS" G2_SCENES=1 G2_A11Y=1
run_and_record_case default-scale1 "$CAPTURE_SETTINGS" G2_SCENES=1 G2_SCALE=1 G2_MONITOR=1440x900
run_and_record_case dark-style "$CAPTURE_SETTINGS;org.gnome.desktop.interface color-scheme prefer-dark" G2_SCENES=1 G2_A11Y=1 G2_TURN_DARK_OFF=1
run_and_record_case high-contrast "$CAPTURE_SETTINGS;org.gnome.desktop.a11y.interface high-contrast true" G2_A11Y=1
run_and_record_case large-text "$CAPTURE_SETTINGS;org.gnome.desktop.interface text-scaling-factor 1.25" G2_A11Y=1
# The headless pointer starts at 0,0, in the hot corner, which its first motion would trip.
run_and_record_case dock-intellihide "$CAPTURE_SETTINGS;$NO_HOT_CORNER" G2_DOCK=1
run_and_record_case dock-intellihide-dark "$CAPTURE_SETTINGS;$NO_HOT_CORNER;org.gnome.desktop.interface color-scheme prefer-dark" G2_DOCK=1
python3 /w/fixtures.py --gpus 1 >"/out/fixtures-one-gpu.txt" 2>&1 || echo "fixtures.py --gpus 1: exit $?"
run_and_record_case dock-one-gpu "$CAPTURE_SETTINGS" G2_ONE_GPU=1
python3 /w/fixtures.py --gpus 2 >>"/out/fixtures-one-gpu.txt" 2>&1 || echo "fixtures.py --gpus 2: exit $?"
# The indicators get shells of their own, as default, default-scale1 and dark-style.
run_and_record_case indicators "$CAPTURE_SETTINGS;$NO_HOT_CORNER;$TWO_SOURCES" G2_INDICATORS=1
run_and_record_case indicators-scale1 "$CAPTURE_SETTINGS;$NO_HOT_CORNER;$TWO_SOURCES" G2_INDICATORS=1 G2_SCALE=1 G2_MONITOR=1440x900
run_and_record_case indicators-dark "$CAPTURE_SETTINGS;$NO_HOT_CORNER;$TWO_SOURCES;org.gnome.desktop.interface color-scheme prefer-dark" G2_INDICATORS=1
run_and_record_case stock-light "$CAPTURE_SETTINGS;org.gnome.desktop.interface color-scheme prefer-light" APEX_SHELL_SAFE=1 G2_SCENES=1
run_and_record_case stock-dark "$CAPTURE_SETTINGS;org.gnome.desktop.interface color-scheme prefer-dark" APEX_SHELL_SAFE=1 G2_SCENES=1
run_and_record_case safe-env '' APEX_SHELL_SAFE=1
run_and_record_case layer-disabled 'io.github.apex_linux.Apex.Desktop layer-enabled false'
run_and_record_case layer-cycles "$CAPTURE_SETTINGS" G2_CYCLES=3
run_and_record_case motion "$MOTION_SETTINGS" G2_MOTION=1
run_and_record_case idle "$CAPTURE_SETTINGS;$NO_HOT_CORNER" G2_IDLE=1
run_and_record_case fault-configure '' APEX_SHELL_TEST_FAULT=configure
run_and_record_case fault-enable '' APEX_SHELL_TEST_FAULT=enable PROBE_WAIT=10
run_and_record_case fault-abort '' APEX_SHELL_TEST_FAULT=abort-after-enable PROBE_WAIT=20
run_and_record_case glass "$CAPTURE_SETTINGS" G2_GLASS=1 GI_TYPELIB_PATH="$FRAME_DIR"
