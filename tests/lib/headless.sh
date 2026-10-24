# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A headless gnome-shell for the app tests; its bus, fixtures and clock follow tests/shots/direct.sh's run_case.

HEADLESS_LIB=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HEADLESS_LIB
# shellcheck source=SCRIPTDIR/../../.github/scripts/lib.sh
. "$HEADLESS_LIB/../../.github/scripts/lib.sh"

readonly SHOTS=$HEADLESS_LIB/../shots
readonly USER_NAME=apex
readonly MONITOR=2880x1800
readonly SCALE=2
readonly CLOCK_LIB=/run/apex-ptyxis-clock.so
readonly CLOCK='2026-10-24 10:24:00'
readonly FIXTURE_NAMES=(org.freedesktop.UPower org.freedesktop.NetworkManager org.bluez)
# apex-desktop's values (schemas/90_apex.gschema.override, dconf/distro.d/50-apex-ptyxis).
readonly PROFILE_UUID=d14b2180d28c41f3a9ee7785f4daa697
readonly PROFILE_SCHEMA=org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$PROFILE_UUID/
readonly APEX_SETTINGS="org.gnome.desktop.interface font-name 'Adwaita Sans 10.125'
org.gnome.desktop.interface monospace-font-name 'JetBrains Mono 9.75'
org.gnome.desktop.interface font-hinting 'none'
org.gnome.Ptyxis profile-uuids ['$PROFILE_UUID']
org.gnome.Ptyxis default-profile-uuid '$PROFILE_UUID'
$PROFILE_SCHEMA label 'Apex'
$PROFILE_SCHEMA cell-height-scale 1.21"
readonly CAPTURE_SETTINGS="org.gnome.desktop.interface enable-animations false
org.gnome.desktop.interface cursor-blink false
org.gnome.desktop.notifications show-banners false
org.gnome.shell welcome-dialog-last-shown-version '999'
org.gnome.desktop.interface scaling-factor $SCALE"

headless_require_container() {
    [[ -e /run/.containerenv || -e /.dockerenv ]] || die "$1: only inside a throwaway container"
    ((EUID == 0)) || die "$1: runs as root, and the shell as the user $USER_NAME"
}

# headless_install_rpm DIR NAME: the lane's built NAME package from DIR.
headless_install_rpm() {
    local dir=$1 name=$2 rpms
    shopt -s nullglob
    rpms=("$dir/$name"-[0-9]*.x86_64.rpm)
    shopt -u nullglob
    ((${#rpms[@]} == 1)) || die "expected one $name x86_64 RPM in $dir"
    dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install "${rpms[0]}" ||
        die "cannot install ${rpms[0]}"
}

# Sets HEADLESS_HOME, the user's home.
headless_user() {
    id "$USER_NAME" >/dev/null 2>&1 || useradd -m "$USER_NAME"
    HEADLESS_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
}

# Sets HEADLESS_SHIM (the PATH entry) and CLOCK_EPOCH.
headless_bus() {
    local log_dir=$1 held
    rm -rf /run/systemd/seats
    mkdir -p /run/dbus /etc/dbus-1 /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
    {
        echo '<busconfig><policy user="root">'
        for name in "${FIXTURE_NAMES[@]}"; do
            printf '<allow own="%s"/><allow send_destination="%s"/>\n' "$name" "$name"
        done
        echo '</policy></busconfig>'
    } >/etc/dbus-1/system-local.conf
    [[ -S /run/dbus/system_bus_socket ]] || dbus-daemon --system --fork || log "no system bus"
    python3 "$SHOTS/fixtures.py" "$log_dir" >"$log_dir/fixtures.txt" 2>&1 || log "fixtures.py: exit $?"
    gcc -O2 -Wall -Werror -shared -fPIC -o "$CLOCK_LIB" "$SHOTS/clock.c" || die "cannot build tests/shots/clock.c"
    CLOCK_EPOCH=$(date -u -d "$CLOCK" +%s)
    held=$(env LD_PRELOAD="$CLOCK_LIB" G2_CLOCK_EPOCH="$CLOCK_EPOCH" date -u '+%F %T' 2>&1)
    [[ $held == "$CLOCK" ]] || die "$CLOCK_LIB does not hold the clock at $CLOCK: $held"
    # Ptyxis's agent spawns through systemd-run when it answers --version; there is no user manager here.
    HEADLESS_SHIM=$(mktemp -d)
    printf '#!/bin/sh\nexit 1\n' >"$HEADLESS_SHIM/systemd-run"
    chmod 755 "$HEADLESS_SHIM" "$HEADLESS_SHIM/systemd-run"
}

# headless_run LOG PROBE TIMEOUT SETTINGS [NAME=VALUE...]: one shell with PROBE as its automation script.
headless_run() {
    local log=$1 probe=$2 timeout=$3 settings=$4 run
    shift 4
    run=$(mktemp -d)
    chown "$USER_NAME:" "$run" && chmod 700 "$run"
    # shellcheck disable=SC2016 # expanded by the user's bash
    runuser -u "$USER_NAME" -- env -i HOME="$HEADLESS_HOME" PATH="$HEADLESS_SHIM:/usr/bin:/usr/sbin" \
        XDG_RUNTIME_DIR="$run" LANG=C.UTF-8 TZ=UTC CLOCK_LIB="$CLOCK_LIB" G2_CLOCK_EPOCH="$CLOCK_EPOCH" \
        DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket PROBE="$probe" MONITOR="$MONITOR" \
        SETTINGS="$APEX_SETTINGS"$'\n'"$CAPTURE_SETTINGS"$'\n'"$settings" "$@" \
        timeout "$timeout" dbus-run-session -- bash -c '
            while read -r schema key value; do
                [[ -n $schema ]] || continue
                gsettings set "$schema" "$key" "$value" || exit 1
            done <<<"$SETTINGS"
            exec env LD_PRELOAD="$CLOCK_LIB" gnome-shell --headless --virtual-monitor "$MONITOR" \
                --wayland-display=apex-ptyxis --automation-script "$PROBE"
        ' >"$log" 2>&1
}
