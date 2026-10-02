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
/out/CASE.log gets its output, /out/results-PART.txt its exit status.

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
# It stops logind's seats and changes /run as root: never outside run.sh's container.
[[ -e /run/.containerenv ]] || { echo "direct.sh: only inside run.sh's podman container" >&2; exit 2; }

readonly SHELL_TIMEOUT=150
# Two fixed workspaces: stock widens the active workspace dot by a factor that depends on
# the count. A 24-hour clock: in 12 hours a one-digit hour adds a figure space.
readonly CAPTURE_SETTINGS='org.gnome.desktop.interface enable-animations false;org.gnome.desktop.interface cursor-blink false;org.gnome.mutter dynamic-workspaces false;org.gnome.desktop.wm.preferences num-workspaces 2;org.gnome.desktop.interface clock-format 24h'

cat /proc/cmdline >"/out/cmdline-$part.txt"
# gnome-shell's loginManager.js takes its dummy manager only when /run/systemd/seats is
# missing, and timeLimitsManager.js needs a system bus.
rm -rf /run/systemd/seats
mkdir -p /run/dbus
dbus-daemon --system --fork || echo "no system bus"
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

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
        G2_SCALE=2 G2_MONITOR=2880x1800 "$@" \
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
                "layer-enabled=$(gsettings get io.github.sekirokenjii.Apex.Desktop layer-enabled)"
            exec gnome-shell --headless --virtual-monitor "$G2_MONITOR" \
                --wayland-display=apex-g2 --automation-script /w/probe.js
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
}

: >"/out/results-$part.txt"
case $part in
    kernel)
        run_and_record_case kernel-safe ''
        exit 0 ;;
    fedora)
        run_and_record_case fedora-light "$CAPTURE_SETTINGS;org.gnome.desktop.interface color-scheme prefer-light" G2_SCENES=1
        run_and_record_case fedora-dark "$CAPTURE_SETTINGS;org.gnome.desktop.interface color-scheme prefer-dark" G2_SCENES=1
        exit 0 ;;
esac

run_and_record_case default "$CAPTURE_SETTINGS" G2_SCENES=1
run_and_record_case default-scale1 "$CAPTURE_SETTINGS" G2_SCENES=1 G2_SCALE=1 G2_MONITOR=1440x900
run_and_record_case dark-style "$CAPTURE_SETTINGS;org.gnome.desktop.interface color-scheme prefer-dark" G2_SCENES=1 G2_TURN_DARK_OFF=1
run_and_record_case stock-light "$CAPTURE_SETTINGS;org.gnome.desktop.interface color-scheme prefer-light" APEX_SHELL_SAFE=1 G2_SCENES=1
run_and_record_case stock-dark "$CAPTURE_SETTINGS;org.gnome.desktop.interface color-scheme prefer-dark" APEX_SHELL_SAFE=1 G2_SCENES=1
run_and_record_case safe-env '' APEX_SHELL_SAFE=1
run_and_record_case layer-disabled 'io.github.sekirokenjii.Apex.Desktop layer-enabled false'
run_and_record_case fault-configure '' APEX_SHELL_TEST_FAULT=configure
run_and_record_case fault-enable '' APEX_SHELL_TEST_FAULT=enable PROBE_WAIT=10
run_and_record_case fault-abort '' APEX_SHELL_TEST_FAULT=abort-after-enable PROBE_WAIT=20
