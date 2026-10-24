#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SHOTS=$HERE/../shots
. "$HERE/../../.github/scripts/lib.sh"

readonly APEX_DESKTOP_URL=https://github.com/apex-linux/apex-desktop
readonly APEX_DESKTOP_REV=c8afa2efaf597c6183932ff77cfde38a550e54f8

usage() {
    cat <<EOF
usage: tests/nautilus/shoot.sh [RPM_DIR]

Captures the Files window in a headless gnome-shell at scale 2, light and dark, as root
in a throwaway fedora:$APEX_FEDORA container (just nautilus-shots). RPM_DIR holds the
lane's built RPMs (_build/nautilus/out); without it the installed nautilus is captured.
A user 'apex' has board 27's home (home.py), apex-desktop's Apex icon theme and schema
(from $APEX_DESKTOP_REV, or APEX_DESKTOP_SRC, a checkout) and its fonts. Each case also
dumps the window's accessible tree (a11y.py), and check.py asserts what the board says:
the footer, the item count. Captures, trees and logs land in _build/nautilus/shots/.

It needs gnome-shell, mesa-dri-drivers, dbus-daemon, python3-dbusmock, gcc, util-linux,
at-spi2-core, python3-gobject, inkscape, git-core, glycin-thumbnailer and the Apex fonts
(adwaita-sans-fonts, jetbrains-mono-fonts-all). G2's clock.c and fixtures.py (tests/shots)
are used as they are.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
[[ -e /run/.containerenv || -e /.dockerenv ]] || die "shoot.sh: only inside a throwaway container"
((EUID == 0)) || die "shoot.sh: runs as root, and the shell as the user apex"

readonly USER_NAME=apex
readonly SHELL_TIMEOUT=120
readonly CLOCK_LIB=/run/apex-files-clock.so
readonly FIXTURE_NAMES=(org.freedesktop.UPower org.freedesktop.NetworkManager org.bluez)
readonly CLOCK='2026-10-21 10:24:00'
readonly MONITOR=2880x1800
readonly SCALE=2
readonly SPEC_ODT='Apex Fedora — Spec.odt'
readonly APEX_SCHEMAS=/run/apex-schemas
readonly SEARCH_QUERY=apex
# apex-desktop's values (schemas/90_apex.gschema.override).
readonly APEX_SETTINGS="org.gnome.desktop.interface font-name 'Adwaita Sans 10.125'
org.gnome.desktop.interface monospace-font-name 'JetBrains Mono 9.75'
org.gnome.desktop.interface font-hinting 'none'
org.gnome.desktop.interface icon-theme 'Apex'"
readonly CAPTURE_SETTINGS="org.gnome.desktop.interface enable-animations false
org.gnome.desktop.interface cursor-blink false
org.gnome.desktop.notifications show-banners false
org.gnome.shell welcome-dialog-last-shown-version '999'
org.gnome.desktop.interface clock-format '24h'
org.gnome.desktop.interface scaling-factor $SCALE"

git_() { git -c safe.directory='*' "$@"; }

out=$APEX_ROOT/_build/nautilus/shots
rm -rf -- "$out"
mkdir -p -- "$out"

if [[ -n ${1:-} ]]; then
    shopt -s nullglob
    rpms=("$1"/nautilus-[0-9]*.x86_64.rpm "$1"/nautilus-extensions-[0-9]*.x86_64.rpm)
    ((${#rpms[@]} == 2)) || die "expected the nautilus and nautilus-extensions x86_64 RPMs in $1"
    dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install "${rpms[@]}" ||
        die "cannot install ${rpms[*]}"
fi
rpm -q nautilus nautilus-extensions >"$out/nautilus.txt"

group "apex-desktop $APEX_DESKTOP_REV: the Apex icon theme and schema"
desktop=${APEX_DESKTOP_SRC:-$APEX_ROOT/_build/nautilus/apex-desktop}
if [[ -z ${APEX_DESKTOP_SRC:-} ]]; then
    [[ -d $desktop/.git ]] || git_ init -q "$desktop"
    if [[ $(git_ -C "$desktop" rev-parse -q --verify HEAD 2>/dev/null) != "$APEX_DESKTOP_REV" ]]; then
        git_ -C "$desktop" fetch -q --depth 1 "$APEX_DESKTOP_URL" "$APEX_DESKTOP_REV" || die "cannot fetch apex-desktop"
        git_ -C "$desktop" checkout -q --detach "$APEX_DESKTOP_REV" || die "cannot check out apex-desktop"
    fi
fi
# The theme as apex-desktop.spec's %build and %install make it, without Colloid's app icons.
icons=$(mktemp -d)
(
    cd -- "$desktop" &&
        mkdir -p "$icons/symbolic" &&
        for f in desktop/icons/symbolic/*.svg; do
            n=${f##*/}
            bash desktop/icons/fill-strokes.sh "$f" "$icons/symbolic/${n%.svg}-symbolic.svg" || exit 1
        done &&
        bash desktop/icons/build-places.sh "$icons/themes" desktop/icons/places/folder.svg \
            desktop/icons/places/emblems desktop/icons/accents &&
        bash desktop/icons/build-mimetypes.sh "$icons/themes" desktop/icons/mimetypes/file.svg \
            desktop/icons/mimetypes/kinds desktop/icons/mimetypes/types
) >"$out/icons.log" 2>&1 || die "cannot build the Apex icon theme; see ${out#"$APEX_ROOT/"}/icons.log"
rm -rf /usr/share/icons/Apex
install -Dm0644 "$desktop/desktop/icons/index.theme" /usr/share/icons/Apex/index.theme
install -Dm0644 -t /usr/share/icons/Apex/symbolic "$icons"/symbolic/*-symbolic.svg
cp -a "$icons/themes/Apex/." /usr/share/icons/Apex/
gtk4-update-icon-cache -q -t -f /usr/share/icons/Apex 2>/dev/null || true
# Its own directory, so the no-schema case can leave it out.
install -Dm0644 -t "$APEX_SCHEMAS" "$desktop"/desktop/schemas/io.github.apex_linux.Apex.Desktop.gschema.xml
glib-compile-schemas --strict "$APEX_SCHEMAS" || die "glib-compile-schemas failed on the Apex schema"
endgroup

id "$USER_NAME" >/dev/null 2>&1 || useradd -m "$USER_NAME"
home=$(getent passwd "$USER_NAME" | cut -d: -f6)
python3 "$HERE/home.py" "$home" "$CLOCK" || die "home.py failed"
chown -R "$USER_NAME:" "$home"

# From here to the shell's exec, the steps of tests/shots/direct.sh and its run_case,
# as tests/ptyxis/shoot.sh takes them: keep the three in step.
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
python3 "$SHOTS/fixtures.py" "$out" >"$out/fixtures.txt" 2>&1 || log "fixtures.py: exit $?"
gcc -O2 -Wall -Werror -shared -fPIC -o "$CLOCK_LIB" "$SHOTS/clock.c" || die "cannot build tests/shots/clock.c"
clock_epoch=$(date -u -d "$CLOCK" +%s)
held=$(env LD_PRELOAD="$CLOCK_LIB" G2_CLOCK_EPOCH="$clock_epoch" date -u '+%F %T' 2>&1)
[[ $held == "$CLOCK" ]] || die "$CLOCK_LIB does not hold the clock at $CLOCK: $held"

shoot() {
    local name=$1 scheme=$2 viewer=$3 args=$4 extra=$5 query=$6 schemas=$7 press=${8:-} run rc settings
    run=$(mktemp -d)
    chown "$USER_NAME:" "$run" && chmod 700 "$run"
    rm -rf "$home/.config/dconf" "$home/.local/share/gvfs-metadata" "$home/.cache/thumbnails"
    settings="$APEX_SETTINGS"$'\n'"$CAPTURE_SETTINGS"$'\n'"org.gnome.desktop.interface color-scheme '$scheme'"
    settings+=$'\n'"org.gnome.nautilus.preferences default-folder-viewer '$viewer'"
    [[ -z $extra ]] || settings+=$'\n'"$extra"
    # shellcheck disable=SC2016 # expanded by the user's bash
    runuser -u "$USER_NAME" -- env -i HOME="$home" PATH="/usr/bin:/usr/sbin" XDG_RUNTIME_DIR="$run" \
        LANG=C.UTF-8 TZ=UTC APEX_SHOTS="$out" APEX_SHOT="$name" APEX_FILES_ARGS="$args" APEX_A11Y="$HERE/a11y.py" \
        APEX_FILES_SEARCH="$query" APEX_A11Y_PRESS="$press" ${schemas:+GSETTINGS_SCHEMA_DIR="$schemas"} \
        CLOCK_LIB="$CLOCK_LIB" G2_CLOCK_EPOCH="$clock_epoch" GTK_A11Y=atspi \
        DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket SETTINGS="$settings" \
        timeout "$SHELL_TIMEOUT" dbus-run-session -- bash -c '
            while read -r schema key value; do
                gsettings set "$schema" "$key" "$value" || exit 1
            done <<<"$SETTINGS"
            exec env LD_PRELOAD="$CLOCK_LIB" gnome-shell --headless --virtual-monitor '"$MONITOR"' --wayland-display=apex-files \
                --automation-script '"$HERE"'/probe.js
        ' >"$out/$name.log" 2>&1
    rc=$?
    log "shoot.sh: $name: exit $rc"
    grep -q '^.*APEXFILES ' "$out/$name.log" && [[ -s $out/$name.png ]]
}

home_args=$(printf '["--new-window", "%s"]' "$home")
documents_args=$(printf '["--new-window", "--select", "%s/Documents/%s"]' "$home" "$SPEC_ODT")

chmod 777 "$out"
status=0
details_on="io.github.apex_linux.Apex.Desktop files-details-pane true"
for scheme in light dark; do
    color=default
    [[ $scheme == dark ]] && color=prefer-dark
    shoot "home-$scheme" "$color" icon-view "$home_args" "" "" "$APEX_SCHEMAS" || status=1
    shoot "documents-$scheme" "$color" list-view "$documents_args" "$details_on" "" "$APEX_SCHEMAS" || status=1
    shoot "search-$scheme" "$color" list-view "$home_args" "" "$SEARCH_QUERY" "$APEX_SCHEMAS" || status=1
done
shoot search-documents-light default list-view "$home_args" "" "$SEARCH_QUERY" "$APEX_SCHEMAS" "Documents 3" || status=1
shoot noschema-light default icon-view "$home_args" "" "" "" || status=1
((status == 0)) || die "shoot.sh: a capture failed; see ${out#"$APEX_ROOT/"}/*.log"
python3 "$HERE/check.py" "$out" || die "shoot.sh: the captures' assertions failed"
log "shoot.sh: captures in ${out#"$APEX_ROOT/"}"
