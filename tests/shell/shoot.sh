#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SHOTS=$HERE/../shots
. "$HERE/../../.github/scripts/lib.sh"

readonly APEX_DESKTOP_URL=https://github.com/apex-linux/apex-desktop
readonly APEX_DESKTOP_REV=f1a2f930f7e16ab7c7fde8f3a178d2e3ad9666ac

usage() {
    cat <<EOF
usage: tests/shell/shoot.sh RPM_DIR

The lock screen and the greeter of the gnome-shell RPMs in RPM_DIR (the lane's
_build/gnome-shell/out), headless at scale 2, as root in a throwaway fedora:$APEX_FEDORA
container (just lock-shots). gdm-mock.py stands in for GDM: it asks one question and
fails every answer, so no case can unlock; lock-refused's GDM refuses even to ask, and
lock-fingerprint's also runs gdm-fingerprint against fprintd-mock.py's reader. Each lock
case locks, answers wrongly (lock-fingerprint fails a scan), blanks and wakes the screen; each greeter case (--mode=gdm) shows the user list, then the
prompt. check.py asserts the cases' logs and the mock's. The users apex and guest come
from accounts-daemon; the wallpapers, the greeter's background and its logo are apex-desktop's ($APEX_DESKTOP_REV, or
APEX_DESKTOP_SRC, a checkout). Captures and logs land in _build/gnome-shell/shots/.

It needs mesa-dri-drivers, dbus-daemon, python3-dbusmock, python3-gobject, gcc,
accountsservice, librsvg2-tools, openssl, git-core and the Apex fonts (adwaita-sans-fonts,
jetbrains-mono-fonts-all). G2's clock.c and fixtures.py (tests/shots) are used as they are.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    '') usage >&2; exit 2 ;;
esac
[[ -e /run/.containerenv || -e /.dockerenv ]] || die "shoot.sh: only inside a throwaway container"
((EUID == 0)) || die "shoot.sh: runs as root, and the shells as the users apex and gdm-greeter"

readonly USER_NAME=apex
readonly GREETER_USER=gdm-greeter
readonly SHELL_TIMEOUT=120
readonly CLOCK_LIB=/run/apex-lock-clock.so
readonly FIXTURE_NAMES=(org.freedesktop.UPower org.freedesktop.NetworkManager org.bluez)
readonly GDM_NAME=org.gnome.DisplayManager
readonly LOGIND_NAME=org.freedesktop.login1
readonly FPRINT_NAME=net.reactivated.Fprint
# layer.js warns that this names no fault phase as it loads: the witness that it loaded.
readonly LOAD_WITNESS=APEX_SHELL_TEST_FAULT=load-witness
readonly CLOCK='2026-10-21 10:24:00'
readonly MONITOR=2880x1800
readonly SCALE=2
readonly BACKGROUNDS=/usr/share/backgrounds/apex
readonly APEX_SETTINGS="org.gnome.desktop.interface font-name 'Adwaita Sans 10.125'
org.gnome.desktop.interface monospace-font-name 'JetBrains Mono 9.75'
org.gnome.desktop.interface font-hinting 'none'
org.gnome.desktop.interface clock-show-weekday true
org.gnome.desktop.notifications show-in-lock-screen false
org.gnome.desktop.background picture-uri 'file://$BACKGROUNDS/apex-facets-light.png'
org.gnome.desktop.background picture-uri-dark 'file://$BACKGROUNDS/apex-facets-dark.png'"
readonly CAPTURE_SETTINGS="org.gnome.desktop.interface enable-animations false
org.gnome.desktop.interface cursor-blink false
org.gnome.desktop.notifications show-banners false
org.gnome.shell welcome-dialog-last-shown-version '999'
org.gnome.desktop.interface clock-format '24h'
org.gnome.desktop.interface scaling-factor $SCALE"

git_() { git -c safe.directory='*' "$@"; }

out=$APEX_ROOT/_build/gnome-shell/shots
rm -rf -- "$out"
mkdir -p -- "$out"

shopt -s nullglob
rpms=("$1"/gnome-shell-[0-9]*.x86_64.rpm "$1"/gnome-shell-common-[0-9]*.noarch.rpm)
((${#rpms[@]} == 2)) || die "expected the gnome-shell and gnome-shell-common RPMs in $1"
dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install "${rpms[@]}" ||
    die "cannot install ${rpms[*]}"
rpm -q gnome-shell gnome-shell-common >"$out/gnome-shell.txt"
grep -q '\.apex' "$out/gnome-shell.txt" ||
    die "the installed gnome-shell is not an Apex build: $(rpm -q gnome-shell)"
# What apex-desktop ships for the layer: its schema (the layer tests' fixture).
cp "$APEX_ROOT/tests/layer/fixtures/io.github.apex_linux.Apex.Desktop.gschema.xml" /usr/share/glib-2.0/schemas/
glib-compile-schemas --strict /usr/share/glib-2.0/schemas || die "glib-compile-schemas failed"

group "apex-desktop $APEX_DESKTOP_REV: the wallpapers and the greeter's background and logo"
desktop=${APEX_DESKTOP_SRC:-$APEX_ROOT/_build/gnome-shell/apex-desktop}
if [[ -z ${APEX_DESKTOP_SRC:-} ]]; then
    [[ -d $desktop/.git ]] || git_ init -q "$desktop"
    if [[ $(git_ -C "$desktop" rev-parse -q --verify HEAD 2>/dev/null) != "$APEX_DESKTOP_REV" ]]; then
        git_ -C "$desktop" fetch -q --depth 1 "$APEX_DESKTOP_URL" "$APEX_DESKTOP_REV" || die "cannot fetch apex-desktop"
        git_ -C "$desktop" checkout -q --detach "$APEX_DESKTOP_REV" || die "cannot check out apex-desktop"
    fi
fi
# As apex-desktop.spec's %build renders them.
mkdir -p "$BACKGROUNDS"
for variant in light dark; do
    rsvg-convert -w 3840 -h 2400 -o "$BACKGROUNDS/apex-facets-$variant.png" \
        "$desktop/desktop/wallpapers/apex-facets-$variant.svg" || die "cannot render the $variant wallpaper"
    rsvg-convert -w 2880 -h 1800 -o "$BACKGROUNDS/apex-greeter-$variant.png" \
        "$desktop/desktop/wallpapers/apex-greeter-$variant.svg" || die "cannot render the $variant greeter background"
done
# build-logo.sh outlines the text with inkscape and fits the width to it; this keeps the
# template's text as text, in a width it cannot outgrow.
sed -e 's/@WIDTH@/240/g' -e 's/@WORDMARK_X@/84/' -e 's/@CENTER@/120/' -e "s/@VERSION@/$APEX_FEDORA/" \
    "$desktop/desktop/gdm/logo.svg" >/usr/share/pixmaps/apex-gdm-logo.svg || die "cannot write the gdm logo"
cp "$desktop/desktop/gdm/zz_apex-login-screen.gschema.override" /usr/share/glib-2.0/schemas/
glib-compile-schemas --strict /usr/share/glib-2.0/schemas || die "glib-compile-schemas failed"
endgroup

add_user() {
    id "$1" >/dev/null 2>&1 || useradd -m -c "$2" "$1"
    # A password, so the lock screen locks: the mock, not PAM, answers, and fails every answer.
    usermod -p "$(openssl passwd -6 "$1-is-never-asked")" "$1"
    # accounts-daemon lists the users it has cached, as after a first login.
    install -Dm0600 /dev/stdin "/var/lib/AccountsService/users/$1" <<<$'[User]\nSystemAccount=false'
}
add_user "$USER_NAME" Apex
add_user guest Guest
id "$GREETER_USER" >/dev/null 2>&1 || useradd -r -m -d /run/$GREETER_USER "$GREETER_USER"

# From here to the shell's exec, the steps of tests/shots/direct.sh and its run_case, as
# tests/nautilus/shoot.sh takes them, but with logind's mock: the shield needs a logind.
mkdir -p /run/systemd/seats
mkdir -p /run/dbus /etc/dbus-1 /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
{
    echo '<busconfig><policy user="root">'
    for name in "${FIXTURE_NAMES[@]}" "$GDM_NAME" "$LOGIND_NAME" "$FPRINT_NAME"; do
        printf '<allow own="%s"/><allow send_destination="%s"/>\n' "$name" "$name"
    done
    printf '</policy><policy context="default">'
    printf '<allow send_destination="%s"/>' "$GDM_NAME" "$LOGIND_NAME" "$FPRINT_NAME"
    printf '</policy></busconfig>\n'
} >/etc/dbus-1/system-local.conf
[[ -S /run/dbus/system_bus_socket ]] || dbus-daemon --system --fork || die "no system bus"
python3 "$SHOTS/fixtures.py" "$out" >"$out/fixtures.txt" 2>&1 || log "fixtures.py: exit $?"
/usr/libexec/accounts-daemon >"$out/accounts-daemon.log" 2>&1 &
python3 -m dbusmock --system --template logind >"$out/fixture-logind.log" 2>&1 &
for _ in $(seq 100); do
    gdbus call --system -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.NameHasOwner \
        "$LOGIND_NAME" 2>/dev/null | grep -q true && break
    sleep 0.1
done
# One logind session per user, its id in XDG_SESSION_ID as pam_systemd would set it.
session_of() { printf 'c%s' "$(id -u "$1")"; }
for user in "$USER_NAME" "$GREETER_USER"; do
    gdbus call --system -d "$LOGIND_NAME" -o /org/freedesktop/login1 -m org.freedesktop.DBus.Mock.AddSession \
        "$(session_of "$user")" seat0 "$(id -u "$user")" "$user" true >/dev/null || die "cannot add $user's logind session"
done
gcc -O2 -Wall -Werror -shared -fPIC -o "$CLOCK_LIB" "$SHOTS/clock.c" || die "cannot build tests/shots/clock.c"
clock_epoch=$(date -u -d "$CLOCK" +%s)
held=$(env LD_PRELOAD="$CLOCK_LIB" G2_CLOCK_EPOCH="$clock_epoch" date -u '+%F %T' 2>&1)
[[ $held == "$CLOCK" ]] || die "$CLOCK_LIB does not hold the clock at $CLOCK: $held"

# shoot NAME USER MODE SCHEME QUESTION [SETTING...] [-- ENV...]
shoot() {
    local name=$1 user=$2 mode=$3 scheme=$4 question=$5 run rc settings home mock fprintd=''
    local -a fingerprint=()
    shift 5
    settings="$APEX_SETTINGS"$'\n'"$CAPTURE_SETTINGS"$'\n'"org.gnome.desktop.interface color-scheme '$scheme'"
    while (($#)) && [[ $1 != -- ]]; do settings+=$'\n'"$1"; shift; done
    (($#)) && shift
    home=$(getent passwd "$user" | cut -d: -f6)
    rm -rf "$home/.config/dconf"
    run=$(mktemp -d)
    chown "$user:" "$run" && chmod 700 "$run"
    if [[ " $* " == *" APEX_FINGERPRINT=1 "* ]]; then
        fingerprint=(--fingerprint)
        python3 "$HERE/fprintd-mock.py" "$out/$name.fprintd.log" 2>"$out/$name.fprintd.err" &
        fprintd=$!
    fi
    python3 "$HERE/gdm-mock.py" "$out/$name.gdm.log" "$question" "${fingerprint[@]}" 2>"$out/$name.gdm.err" &
    mock=$!
    for _ in $(seq 100); do
        grep -qx "owns $GDM_NAME" "$out/$name.gdm.log" 2>/dev/null &&
            { [[ -z $fprintd ]] || grep -qx "owns $FPRINT_NAME" "$out/$name.fprintd.log" 2>/dev/null; } && break
        sleep 0.1
    done
    # shellcheck disable=SC2016 # expanded by the user's bash
    runuser -u "$user" -- env -i HOME="$home" PATH="/usr/bin:/usr/sbin" XDG_RUNTIME_DIR="$run" \
        LANG=C.UTF-8 TZ=UTC XDG_SESSION_ID="$(session_of "$user")" APEX_SHOTS="$out" APEX_SHOT="$name" APEX_USER="$USER_NAME" \
        CLOCK_LIB="$CLOCK_LIB" G2_CLOCK_EPOCH="$clock_epoch" "$LOAD_WITNESS" "$@" \
        DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket SETTINGS="$settings" \
        timeout "$SHELL_TIMEOUT" dbus-run-session -- bash -c '
            while read -r schema key value; do
                gsettings set "$schema" "$key" "$value" || exit 1
            done <<<"$SETTINGS"
            exec env LD_PRELOAD="$CLOCK_LIB" gnome-shell --headless --virtual-monitor '"$MONITOR"' \
                --wayland-display=apex-lock --mode='"$mode"' --automation-script '"$HERE"'/probe.js
        ' >"$out/$name.log" 2>&1
    rc=$?
    kill "$mock" ${fprintd:+"$fprintd"} 2>/dev/null
    wait "$mock" 2>/dev/null
    log "shoot.sh: $name: exit $rc"
    grep -q '^.*APEXLOCK ' "$out/$name.log"
}

chmod 777 "$out"
status=0
lock_off="io.github.apex_linux.Apex.Desktop disabled-features ['lock']"
for scheme in light dark; do
    color=default
    [[ $scheme == dark ]] && color=prefer-dark
    shoot "lock-$scheme" "$USER_NAME" user "$color" 'Password:' || status=1
    shoot "greeter-$scheme" "$GREETER_USER" gdm "$color" 'Password:' -- GDM_GREETER_TEST=1 || status=1
done
shoot lock-question "$USER_NAME" user default 'Verification code:' || status=1
shoot lock-disabled "$USER_NAME" user default 'Password:' "$lock_off" || status=1
shoot lock-safe "$USER_NAME" user default 'Password:' -- APEX_SHELL_SAFE=1 || status=1
shoot lock-refused "$USER_NAME" user default '' || status=1
shoot lock-high-contrast "$USER_NAME" user default 'Password:' "org.gnome.desktop.a11y.interface high-contrast true" || status=1
shoot lock-large-text "$USER_NAME" user default 'Password:' "org.gnome.desktop.interface text-scaling-factor 1.25" || status=1
# authselect locks GDM's fingerprint key off; an image with a reader enables the feature.
if ! authselect enable-feature with-fingerprint >"$out/authselect.log" 2>&1 || ! dconf update; then
    die "authselect cannot enable with-fingerprint; see ${out#"$APEX_ROOT/"}/authselect.log"
fi
shoot lock-fingerprint "$USER_NAME" user default 'Password:' -- APEX_FINGERPRINT=1 || status=1
if ! authselect disable-feature with-fingerprint >>"$out/authselect.log" 2>&1 || ! dconf update; then
    log "authselect: cannot disable with-fingerprint"
fi
((status == 0)) || die "shoot.sh: a case failed; see ${out#"$APEX_ROOT/"}/*.log"
python3 "$HERE/check.py" "$out" || die "shoot.sh: the cases' assertions failed"
log "shoot.sh: captures in ${out#"$APEX_ROOT/"}"
