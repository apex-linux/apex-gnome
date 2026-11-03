#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat <<'EOF'
usage: guard.sh

G2's crash-guard phases, run by run.sh as root (podman exec) in a container of the built
image that booted its own systemd, with tests/shots at /w (read-only) and the run's
results at /out. A test user gets a real `systemd --user` with the image's user units,
unmodified: GNOME Shell's org.gnome.Shell@.service, the drop-in 50-apex.conf and
apex-shell-safe.service.

Phases, each leaving /out/guard-PHASE.{state,journal}:
  window     layer on, SIGABRT 65 s after start, when the layer has removed its marker:
             apex-shell-safe.service counts a late failure on the booted deployment
             (~/.local/state/apex/shell-guard-trips, `none 1` without ostree=) and
             layer-enabled stays true
  second     the same again on the same deployment: the second late failure trips,
             as below, and removes the counter; then layer-enabled=true again and the
             guard marker removed, for the phases after it
  trip       APEX_SHELL_TEST_FAULT=abort-after-enable: the shell aborts 5 s after
             enable, OnFailure= starts apex-shell-safe.service, which sets
             layer-enabled=false, leaves ~/.local/state/apex/shell-guard-tripped and
             removes the marker
  next       the next "login" (the unit started again, no fault): safe mode
  back-on    layer-enabled=true again (what apex-session-agent will offer): Apex again
  dark-off   color-scheme prefer-dark, then the probe clicks Quick Settings' Dark Style
             toggle off; /out/guard-dark-off.units lists the Apex user units afterwards,
             and default.target to show that the listing sees loaded units
  trip-warm  the trip again, with dconf.service already running
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
(($# == 0)) || { usage >&2; exit 2; }
# It masks logind and removes /run/systemd/seats as root: never outside run.sh's container.
[[ -e /run/.containerenv ]] || { echo "guard.sh: only inside run.sh's podman container" >&2; exit 2; }

readonly TEST_USER=g2
readonly TEST_UID=1000
readonly TEST_RUNTIME_DIR=/run/user/$TEST_UID
readonly UNIT=org.gnome.Shell@user.service
readonly GUARD=apex-shell-safe.service
readonly SCHEMA=io.github.apex_linux.Apex.Desktop
readonly FAULT_VAR=APEX_SHELL_TEST_FAULT

say() { printf '\n## %s\n' "$*"; }
cursor() { journalctl -n 0 --show-cursor -q 2>/dev/null | sed -n 's/^-- cursor: //p'; }
journal_since() { journalctl -o short-precise --no-pager -q --after-cursor="$1" _UID="$TEST_UID"; }
as_user() { runuser -u "$TEST_USER" -- env HOME="$TEST_HOME" XDG_RUNTIME_DIR="$TEST_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="unix:path=$TEST_RUNTIME_DIR/bus" "$@"; }
show() { as_user systemctl --user show "$@"; }

wait_for_active_state() {
    local unit=$1 states_regex=$2 timeout=$3 started=$4
    local deadline=$((SECONDS + timeout)) state
    while :; do
        state=$(show -p ActiveState --value "$unit")
        if [[ $state =~ ^($states_regex)$ ]]; then echo "$unit: $state after $((SECONDS - started))s"; return 0; fi
        ((SECONDS < deadline)) || { echo "$unit: still $state after $timeout s"; return 1; }
        sleep 0.5
    done
}

# Type=notify: returns at READY=1, or when the start fails. A shell still up from the
# previous phase would turn this start into a no-op.
start_shell() {
    local t0=$SECONDS
    if as_user systemctl --user -q is-active "$UNIT"; then
        echo "$UNIT is still active from the previous phase: stopping it"
        as_user systemctl --user stop "$UNIT"
    fi
    as_user systemctl --user reset-failed "$UNIT" "$GUARD" 2>/dev/null
    as_user systemctl --user start "$UNIT"
    echo "systemctl --user start $UNIT: rc=$? after $((SECONDS - t0))s"
}

# A drop-in cannot remove dependencies, so the test user gets a copy of the unit; the
# image's drop-ins, OnFailure=, SuccessExitStatus= and Type=notify still apply to it.
headless_shell_unit_without_gnome_session() {
    sed -e '/^RefuseManualStart=/d' -e '/^RefuseManualStop=/d' -e '/^Requisite=/d' -e '/^PartOf=/d' \
        -e '/^Before=gnome-session/d' -e '/^After=gnome-session/d' -e '/^AssertEnvironment=/d' \
        -e 's|^ExecStart=.*|ExecStart=/usr/bin/gnome-shell --headless --virtual-monitor 2880x1800 --wayland-display=apex-g2 --automation-script /w/probe.js --mode=%i|' \
        /usr/lib/systemd/user/org.gnome.Shell@.service
}

status_block() {
    show -p ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,NRestarts "$UNIT" | paste -sd' '
    show -p ActiveState,Result,ConditionResult,ExecMainStatus,InvocationID,StateChangeTimestamp "$GUARD" | paste -sd' '
    echo "layer-enabled=$(as_user gsettings get "$SCHEMA" layer-enabled)"
    echo "guard marker: $(ls -l --time-style=+%T "$TEST_HOME/.local/state/apex/shell-guard-tripped" 2>&1)"
    echo "guard counter: $(cat "$TEST_HOME/.local/state/apex/shell-guard-trips" 2>&1)"
    echo "starting marker: $(ls -l --time-style=+%T "$TEST_RUNTIME_DIR/apex-shell-starting" 2>&1)"
}

phase_end() {
    local name=$1 phase_cursor=$2
    sleep 1
    status_block | tee "/out/guard-$name.state"
    journal_since "$phase_cursor" >"/out/guard-$name.journal"
    say "phase $name: journal (filtered)"
    grep -E 'APEXG2|Apex|JS ERROR|org.gnome.Shell@user|apex-shell-safe|Condition check|unmet condition|core-dump|Main process exited|Failed with result|Triggering OnFailure|dconf|restart-dbus|Stopping dbus-broker' \
        "/out/guard-$name.journal" | cut -c1-600
}

say "boot"
systemctl is-system-running --wait
systemctl --failed --no-legend --plain | sed 's/^/failed: /'

say "no logind: gnome-shell's loginManager.js needs /run/systemd/seats absent"
systemctl mask --runtime --now systemd-logind.service 2>&1
rm -rf /run/systemd/seats

say "the test user and its systemd --user"
useradd -m -u "$TEST_UID" "$TEST_USER"
TEST_HOME=$(getent passwd "$TEST_USER" | cut -d: -f6)
getent passwd "$TEST_USER"
# Without logind, pam_systemd sets neither XDG_RUNTIME_DIR nor DBUS_SESSION_BUS_ADDRESS for
# the user manager, and systemd --user refuses to start without the first.
mkdir -p "/run/systemd/system/user@$TEST_UID.service.d"
printf '[Service]\nEnvironment=XDG_RUNTIME_DIR=%s DBUS_SESSION_BUS_ADDRESS=unix:path=%s/bus\n' "$TEST_RUNTIME_DIR" "$TEST_RUNTIME_DIR" \
    >"/run/systemd/system/user@$TEST_UID.service.d/90-g2-no-logind.conf"
systemctl daemon-reload
systemctl start "user@$TEST_UID.service"
systemctl show -p ActiveState,SubState "user@$TEST_UID.service" | paste -sd' '
if [[ $(systemctl show -p ActiveState --value "user@$TEST_UID.service") != active ]]; then
    journalctl --no-pager -q -u "user@$TEST_UID.service" | tail -20
    echo "G2-GUARD-ABORT: user@$TEST_UID.service did not start"
    exit 1
fi
as_user systemctl --user is-system-running --wait
as_user systemctl --user --failed --no-legend --plain | sed 's/^/user failed: /'

say "the image's own environment for the shell, before G2 sets anything"
{
    echo "# systemctl --user show-environment"
    as_user systemctl --user show-environment
    echo "# systemctl --user show -p Environment $UNIT"
    show -p Environment "$UNIT"
    echo "# end"
} | tee /out/guard-env.txt

say "the unit fixture: the image's unit without the gnome-session coupling"
install -d -o "$TEST_USER" -g "$TEST_USER" "$TEST_HOME/.config" "$TEST_HOME/.config/systemd" "$TEST_HOME/.config/systemd/user"
headless_shell_unit_without_gnome_session >"$TEST_HOME/.config/systemd/user/org.gnome.Shell@.service"
chown "$TEST_USER:" "$TEST_HOME/.config/systemd/user/org.gnome.Shell@.service"
diff -u /usr/lib/systemd/user/org.gnome.Shell@.service "$TEST_HOME/.config/systemd/user/org.gnome.Shell@.service"
as_user systemctl --user daemon-reload
as_user systemctl --user cat "$UNIT" "$GUARD"
show -p FragmentPath,DropInPaths,OnFailure,OnFailureJobMode,SuccessExitStatus,Type "$UNIT"
as_user gsettings set org.gnome.desktop.interface scaling-factor 2
as_user systemctl --user set-environment XDG_SESSION_TYPE=wayland

late_failure() {
    local name=$1 phase_cursor t0
    phase_cursor=$(cursor)
    as_user systemctl --user set-environment PROBE_WAIT=90
    t0=$SECONDS
    start_shell
    sleep 65
    echo "65 s after start: starting marker $([[ -e $TEST_RUNTIME_DIR/apex-shell-starting ]] && echo present || echo gone)" |
        tee "/out/guard-$name.marker65"
    as_user systemctl --user kill --kill-whom=main --signal=SIGABRT "$UNIT"
    wait_for_active_state "$UNIT" 'failed|inactive' 30 "$t0"
    wait_for_active_state "$GUARD" 'inactive|failed' 30 "$t0"
    as_user systemctl --user unset-environment PROBE_WAIT
    phase_end "$name" "$phase_cursor"
}

say "phase window: layer on, SIGABRT 65 s after start"
late_failure window

say "phase second: a second late failure on the same deployment"
late_failure second
as_user gsettings set "$SCHEMA" layer-enabled true
rm -f "$TEST_HOME/.local/state/apex/shell-guard-tripped"

say "phase trip: $FAULT_VAR=abort-after-enable"
phase_cursor=$(cursor)
echo "dconf.service before the trip: $(show -p ActiveState --value dconf.service)" | tee /out/guard-trip.dconf
as_user systemctl --user set-environment "$FAULT_VAR=abort-after-enable" PROBE_WAIT=30
t0=$SECONDS
start_shell
wait_for_active_state "$UNIT" 'failed|inactive' 60 "$t0"
wait_for_active_state "$GUARD" 'inactive|failed' 30 "$t0"
phase_end trip "$phase_cursor"

say "phase next: the next login, no fault"
phase_cursor=$(cursor)
as_user systemctl --user unset-environment "$FAULT_VAR" PROBE_WAIT
t0=$SECONDS
start_shell
wait_for_active_state "$UNIT" 'failed|inactive' 60 "$t0"
phase_end next "$phase_cursor"

say "phase back-on: layer-enabled=true again"
phase_cursor=$(cursor)
as_user gsettings set "$SCHEMA" layer-enabled true
t0=$SECONDS
start_shell
wait_for_active_state "$UNIT" 'failed|inactive' 60 "$t0"
phase_end back-on "$phase_cursor"

say "phase dark-off: Dark Style turned off in Quick Settings"
phase_cursor=$(cursor)
as_user gsettings set org.gnome.desktop.interface color-scheme prefer-dark
as_user systemctl --user set-environment G2_TURN_DARK_OFF=1
t0=$SECONDS
start_shell
wait_for_active_state "$UNIT" 'failed|inactive' 60 "$t0"
as_user systemctl --user unset-environment G2_TURN_DARK_OFF
{ as_user systemctl --user list-units --all --plain --no-legend --no-pager 'apex*' default.target && echo '# listed'; } |
    tee /out/guard-dark-off.units
as_user gsettings reset org.gnome.desktop.interface color-scheme
phase_end dark-off "$phase_cursor"

say "phase trip-warm: the trip again, with dconf.service already running"
phase_cursor=$(cursor)
as_user gsettings set org.gnome.desktop.interface scaling-factor 2
rm -f "$TEST_HOME/.local/state/apex/shell-guard-tripped"
echo "dconf.service before the trip: $(show -p ActiveState --value dconf.service)" | tee /out/guard-trip-warm.dconf
as_user systemctl --user set-environment "$FAULT_VAR=abort-after-enable" PROBE_WAIT=30
t0=$SECONDS
start_shell
wait_for_active_state "$UNIT" 'failed|inactive' 60 "$t0"
wait_for_active_state "$GUARD" 'inactive|failed' 30 "$t0"
as_user systemctl --user unset-environment "$FAULT_VAR" PROBE_WAIT
phase_end trip-warm "$phase_cursor"

say "the user's whole journal"
journalctl --no-pager -q -o short-precise _UID="$TEST_UID" >/out/guard-journal.txt
echo "JS ERROR lines: $(grep -c 'JS ERROR' /out/guard-journal.txt)"
