#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/headless.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/headless.sh"

PTYXIS_TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly PTYXIS_TESTS

readonly SHELL_TIMEOUT=120

usage() {
    cat <<EOF
usage: tests/ptyxis/shoot.sh [RPM_DIR]

Captures the Ptyxis window in a headless gnome-shell at scale 2, light and dark, as root
in a throwaway fedora:$APEX_FEDORA container (just ptyxis-shots). RPM_DIR holds the
lane's built RPMs (_build/ptyxis/out); without it the installed ptyxis is captured. A
user '$USER_NAME' opens the sessions of the design canvas's board 32, typed into the
terminals by a virtual keyboard, so the statuses come from bash's shell integration
(vte.sh); the split captures add board 33's right split of apex-gnome. The captures and
logs land in _build/ptyxis/shots/. With APEX_PTYXIS_TARGETS=1 each capture also writes
contrast-test.sh's targets, read over AT-SPI (python3-gobject, at-spi2-core), and the four
scenes are taken again in high contrast (hc-light, hc-dark, hc-split-light, hc-split-dark)
and, light, with GNOME's Large Text (large, split-large) for layout-test.sh.

It needs gnome-shell, mesa-dri-drivers, dbus-daemon, python3-dbusmock, gcc, util-linux and
the Apex fonts (jetbrains-mono-fonts-all, adwaita-sans-fonts). G2's clock.c and fixtures.py
(tests/shots) are used as they are.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
headless_require_container shoot.sh

out=$APEX_ROOT/_build/ptyxis/shots
rm -rf -- "$out"
mkdir -p -- "$out"
chmod 777 "$out"
[[ -z ${1:-} ]] || headless_install_rpm "$1" ptyxis
rpm -q ptyxis >"$out/ptyxis.txt"

headless_user
home=$HEADLESS_HOME
fixtures=$home/.apex-fixtures
install -d -o "$USER_NAME" "$home/bin" "$fixtures" "$home/src/apex-gnome" "$home/src/apex-system" \
    "$home/src/apex-desktop" "$home/apex-image"
gcc -O2 -Wall -Werror -o "$home/bin/fixture" "$PTYXIS_TESTS/fixture.c" || die "cannot build fixture.c"
for program in claude just cargo rpmbuild ssh git; do
    cp "$home/bin/fixture" "$home/bin/$program"
done
"$PTYXIS_TESTS/sessions.sh" "$fixtures"
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
headless_bus "$out"
atspi=$out/contrast-atspi.py
install -m 644 "$PTYXIS_TESTS/contrast-atspi.py" "$atspi"

shoot() {
    local name=$1 scene=$2 scheme=$3 style=$4 contrast=${5:-false} text=${6:-1.0}
    local settings="org.gnome.desktop.interface color-scheme '$scheme'"$'\n'"org.gnome.Ptyxis interface-style '$style'"
    settings+=$'\n'"org.gnome.desktop.a11y.interface high-contrast $contrast"
    settings+=$'\n'"org.gnome.desktop.interface text-scaling-factor $text"
    headless_run "$out/$name.log" "$PTYXIS_TESTS/probe.js" "$SHELL_TIMEOUT" "$settings" \
        APEX_SHOTS="$out" APEX_SHOT="$name" APEX_SCENE="$scene" ${APEX_PTYXIS_TARGETS:+APEX_SHOT_ATSPI="$atspi"}
    log "shoot.sh: $name: exit $?"
    grep -q 'APEXPTYXIS ' "$out/$name.log" && [[ -s $out/$name.png ]]
}

status=0
# The container has no settings portal for libadwaita to read color-scheme from.
shoot light sessions default light || status=1
shoot dark sessions prefer-dark dark || status=1
shoot split-light split default light || status=1
shoot split-dark split prefer-dark dark || status=1
# High contrast and large text for contrast-test.sh and layout-test.sh alone: signoff's captures stay the four above.
if [[ -n ${APEX_PTYXIS_TARGETS:-} ]]; then
    shoot hc-light sessions default light true || status=1
    shoot hc-dark sessions prefer-dark dark true || status=1
    shoot hc-split-light split default light true || status=1
    shoot hc-split-dark split prefer-dark dark true || status=1
    shoot large sessions default light false 1.25 || status=1
    shoot split-large split default light false 1.25 || status=1
fi
((status == 0)) || die "shoot.sh: a capture failed; see ${out#"$APEX_ROOT/"}/*.log"
log "shoot.sh: captures in ${out#"$APEX_ROOT/"}"
