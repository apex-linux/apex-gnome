#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../../.github/scripts/lib.sh"

usage() {
    cat <<EOF
usage: tests/ptyxis/shoot.sh [RPM_DIR]

Captures the Ptyxis window in a headless gnome-shell at scale 2, light and dark, as root
in a throwaway fedora:$APEX_FEDORA container (just ptyxis-shots). RPM_DIR holds the
lane's built RPMs (_build/ptyxis/out); without it the installed ptyxis is captured. A
user 'apex' opens the sessions of the design canvas's board 32, typed into the terminals
by a virtual keyboard, so the statuses come from bash's shell integration (vte.sh). The
captures and logs land in _build/ptyxis/shots/.

It needs gnome-shell, mesa-dri-drivers, dbus-daemon, gcc, util-linux and the Apex fonts
(jetbrains-mono-fonts-all, adwaita-sans-fonts).
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
[[ -e /run/.containerenv || -e /.dockerenv ]] || die "shoot.sh: only inside a throwaway container"
((EUID == 0)) || die "shoot.sh: runs as root, and the shell as the user apex"

readonly USER_NAME=apex
readonly SHELL_TIMEOUT=120
readonly MONITOR=2880x1800
readonly SCALE=2
# apex-desktop's values (schemas/90_apex.gschema.override, dconf/distro.d/50-apex-ptyxis).
readonly PROFILE_UUID=d14b2180d28c41f3a9ee7785f4daa697
readonly APEX_SETTINGS="org.gnome.desktop.interface font-name 'Adwaita Sans 10.125'
org.gnome.desktop.interface monospace-font-name 'JetBrains Mono 9.75'
org.gnome.desktop.interface font-hinting 'none'
org.gnome.Ptyxis profile-uuids ['$PROFILE_UUID']
org.gnome.Ptyxis default-profile-uuid '$PROFILE_UUID'
org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$PROFILE_UUID/ label 'Apex'
org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$PROFILE_UUID/ cell-height-scale 1.21"
readonly CAPTURE_SETTINGS="org.gnome.desktop.interface enable-animations false
org.gnome.desktop.interface cursor-blink false
org.gnome.desktop.notifications show-banners false
org.gnome.shell welcome-dialog-last-shown-version '999'
org.gnome.desktop.interface scaling-factor $SCALE"

out=$APEX_ROOT/_build/ptyxis/shots
rm -rf -- "$out"
mkdir -p -- "$out"

if [[ -n ${1:-} ]]; then
    shopt -s nullglob
    rpms=("$1"/ptyxis-[0-9]*.x86_64.rpm)
    ((${#rpms[@]} == 1)) || die "expected one ptyxis x86_64 RPM in $1"
    dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install "${rpms[0]}" ||
        die "cannot install ${rpms[0]}"
fi
rpm -q ptyxis >"$out/ptyxis.txt"

id "$USER_NAME" >/dev/null 2>&1 || useradd -m "$USER_NAME"
home=$(getent passwd "$USER_NAME" | cut -d: -f6)
fixtures=$home/.apex-fixtures
install -d -o "$USER_NAME" "$home/bin" "$fixtures" "$home/src/apex-gnome" "$home/src/apex-system" \
    "$home/src/apex-desktop" "$home/apex-image"
gcc -O2 -Wall -Werror -o "$home/bin/fixture" "$HERE/fixture.c" || die "cannot build fixture.c"
for program in claude just cargo rpmbuild ssh; do
    cp "$home/bin/fixture" "$home/bin/$program"
done
"$HERE/sessions.sh" "$fixtures"
printf 'fedora-45\n' >"$home/src/apex-desktop/.toolbox"
cat >>"$home/.bashrc" <<'EOF'
export PATH=$HOME/bin:$PATH APEX_FIXTURES=$HOME/.apex-fixtures
apex_fixture_toolbox() {
    [[ -f .toolbox ]] || return 0
    printf '\e]666;vte.container.name=%s\e\\\e]666;vte.container.runtime=toolbox\e\\' "$(<.toolbox)"
    PS1='\[\e[35m\]⬢ \[\e[34m\]\w\[\e[2m\] $ \[\e[0m\]'
}
PS1='\[\e[34m\]\w\[\e[2m\] $ \[\e[0m\]'
__apex_postexec() { printf '\e]666;vte.shell.postexec=%s\e\\' "$?"; }
__vte_precmd() { __vte_termprop_signal vte.shell.precmd; }
PROMPT_COMMAND=(__apex_postexec "${PROMPT_COMMAND[@]}" apex_fixture_toolbox)
EOF
chown -R "$USER_NAME:" "$home"

rm -rf /run/systemd/seats
mkdir -p /run/dbus /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
[[ -S /run/dbus/system_bus_socket ]] || dbus-daemon --system --fork || log "no system bus"
# Ptyxis's agent spawns through systemd-run when it answers --version; there is no user manager here.
shim=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' >"$shim/systemd-run"
chmod 755 "$shim" "$shim/systemd-run"

shoot() {
    local name=$1 scheme=$2 style=$3 run rc
    run=$(mktemp -d)
    chown "$USER_NAME:" "$run" && chmod 700 "$run"
    # shellcheck disable=SC2016 # expanded by the user's bash
    runuser -u "$USER_NAME" -- env -i HOME="$home" PATH="$shim:/usr/bin:/usr/sbin" XDG_RUNTIME_DIR="$run" \
        LANG=C.UTF-8 TZ=UTC APEX_SHOTS="$out" APEX_SHOT="$name" \
        SETTINGS="$APEX_SETTINGS"$'\n'"$CAPTURE_SETTINGS"$'\n'"org.gnome.desktop.interface color-scheme '$scheme'"$'\n'"org.gnome.Ptyxis interface-style '$style'" \
        timeout "$SHELL_TIMEOUT" dbus-run-session -- bash -c '
            while read -r schema key value; do
                gsettings set "$schema" "$key" "$value" || exit 1
            done <<<"$SETTINGS"
            exec gnome-shell --headless --virtual-monitor '"$MONITOR"' --wayland-display=apex-ptyxis \
                --automation-script '"$HERE"'/probe.js
        ' >"$out/$name.log" 2>&1
    rc=$?
    log "shoot.sh: $name: exit $rc"
    grep -q '^.*APEXPTYXIS ' "$out/$name.log" && [[ -s $out/$name.png ]]
}

chmod 777 "$out"
status=0
# The container has no settings portal for libadwaita to read color-scheme from.
shoot light default light || status=1
shoot dark prefer-dark dark || status=1
((status == 0)) || die "shoot.sh: a capture failed; see ${out#"$APEX_ROOT/"}/*.log"
log "shoot.sh: captures in ${out#"$APEX_ROOT/"}"
