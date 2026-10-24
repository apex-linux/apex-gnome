# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A headless gnome-shell for tests/control-center; headless_bus and headless_run copy tests/ptyxis/lib.sh's.

CC_TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly CC_TESTS
# shellcheck source=SCRIPTDIR/../../.github/scripts/lib.sh
. "$CC_TESTS/../../.github/scripts/lib.sh"

readonly SHOTS=$CC_TESTS/../shots
readonly USER_NAME=apex
readonly MONITOR=2880x1800
readonly SCALE=2
readonly CLOCK_LIB=/run/apex-control-center-clock.so
readonly CLOCK='2026-10-21 14:02:00'
readonly FIXTURE_NAMES=(org.freedesktop.UPower org.freedesktop.NetworkManager org.bluez)
readonly APEX_SCHEMA_FIXTURE=$CC_TESTS/../layer/fixtures/io.github.apex_linux.Apex.Desktop.gschema.xml
readonly APEX_SCHEMA_DIR=/usr/share/glib-2.0/schemas
readonly MANIFEST=/usr/share/apex/manifest.json
readonly IMAGE_VERSION=45.20261008.131
# apex-desktop's values (schemas/90_apex.gschema.override).
readonly APEX_SETTINGS="org.gnome.desktop.interface font-name 'Adwaita Sans 10.125'
org.gnome.desktop.interface font-hinting 'none'
org.gnome.desktop.interface show-battery-percentage true
org.gnome.desktop.interface clock-show-weekday true
org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close'
org.gnome.desktop.background picture-uri 'file://$CC_TESTS/wallpaper-light.svg'
org.gnome.desktop.background picture-uri-dark 'file://$CC_TESTS/wallpaper-dark.svg'"
readonly CAPTURE_SETTINGS="org.gnome.desktop.interface cursor-blink false
org.gnome.desktop.notifications show-banners false
org.gnome.shell welcome-dialog-last-shown-version '999'
org.gnome.desktop.interface scaling-factor $SCALE"

headless_require_container() {
    [[ -e /run/.containerenv || -e /.dockerenv ]] || die "$1: only inside a throwaway container"
    ((EUID == 0)) || die "$1: runs as root, and the shell as the user $USER_NAME"
}

headless_install_rpms() {
    local dir=$1 rpms
    shopt -s nullglob
    rpms=("$dir"/gnome-control-center-[0-9]*.x86_64.rpm "$dir"/gnome-control-center-filesystem-[0-9]*.noarch.rpm)
    shopt -u nullglob
    ((${#rpms[@]} == 2)) || die "expected the gnome-control-center and -filesystem RPMs in $dir"
    dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install "${rpms[@]}" ||
        die "cannot install ${rpms[*]}"
}

# headless_apex_schema yes|no: installs apex-desktop's schema, as tests/layer/fixtures holds it, or removes it.
headless_apex_schema() {
    if [[ $1 == yes ]]; then
        install -m 644 "$APEX_SCHEMA_FIXTURE" "$APEX_SCHEMA_DIR/"
    else
        rm -f -- "$APEX_SCHEMA_DIR/${APEX_SCHEMA_FIXTURE##*/}"
    fi
    glib-compile-schemas "$APEX_SCHEMA_DIR" || die "glib-compile-schemas failed"
}

# The booted image's manifest, as apexctl build manifest writes it; the header reads only its version.
headless_manifest() {
    mkdir -p -- "${MANIFEST%/*}"
    printf '{"schema": 1, "name": "apex", "fedora": 45, "version": "%s"}\n' "$IMAGE_VERSION" >"$MANIFEST"
}

# Sets HEADLESS_HOME, the user's home.
headless_user() {
    id "$USER_NAME" >/dev/null 2>&1 || useradd -m "$USER_NAME"
    HEADLESS_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
}

# Sets CLOCK_EPOCH.
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
}

# headless_run LOG PROBE TIMEOUT SETTINGS [NAME=VALUE...]: one shell with PROBE as its automation script.
headless_run() {
    local log=$1 probe=$2 timeout=$3 settings=$4 run
    shift 4
    run=$(mktemp -d)
    chown "$USER_NAME:" "$run" && chmod 700 "$run"
    # shellcheck disable=SC2016 # expanded by the user's bash
    runuser -u "$USER_NAME" -- env -i HOME="$HEADLESS_HOME" PATH=/usr/bin:/usr/sbin \
        XDG_RUNTIME_DIR="$run" XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME LANG=C.UTF-8 TZ=UTC CLOCK_LIB="$CLOCK_LIB" \
        G2_CLOCK_EPOCH="$CLOCK_EPOCH" DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket \
        PROBE="$probe" MONITOR="$MONITOR" CC_TESTS="$CC_TESTS" \
        SETTINGS="$APEX_SETTINGS"$'\n'"$CAPTURE_SETTINGS"$'\n'"$settings" "$@" \
        timeout "$timeout" dbus-run-session -- bash -c '
            while read -r schema key value; do
                [[ -n $schema ]] || continue
                gsettings set "$schema" "$key" "$value" || exit 1
            done <<<"$SETTINGS"
            exec env LD_PRELOAD="$CLOCK_LIB" gnome-shell --headless --virtual-monitor "$MONITOR" \
                --wayland-display=apex-control-center --automation-script "$PROBE"
        ' >"$log" 2>&1
}
