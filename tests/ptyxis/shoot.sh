#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

readonly SHELL_TIMEOUT=120

usage() {
    cat <<EOF
usage: tests/ptyxis/shoot.sh [RPM_DIR]

Captures the Ptyxis window in a headless gnome-shell at scale 2, light and dark, as root
in a throwaway fedora:$APEX_FEDORA container (just ptyxis-shots). RPM_DIR holds the
lane's built RPMs (_build/ptyxis/out); without it the installed ptyxis is captured. A
user '$USER_NAME' opens the sessions of the design canvas's board 32, typed into the
terminals by a virtual keyboard, so the statuses come from bash's shell integration
(vte.sh). The captures and logs land in _build/ptyxis/shots/.

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
[[ -z ${1:-} ]] || headless_install_rpm "$1"
rpm -q ptyxis >"$out/ptyxis.txt"

headless_user
home=$HEADLESS_HOME
fixtures=$home/.apex-fixtures
install -d -o "$USER_NAME" "$home/bin" "$fixtures" "$home/src/apex-gnome" "$home/src/apex-system" \
    "$home/src/apex-desktop" "$home/apex-image"
gcc -O2 -Wall -Werror -o "$home/bin/fixture" "$PTYXIS_TESTS/fixture.c" || die "cannot build fixture.c"
for program in claude just cargo rpmbuild ssh; do
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

shoot() {
    local name=$1 scheme=$2 style=$3
    headless_run "$out/$name.log" "$PTYXIS_TESTS/probe.js" "$SHELL_TIMEOUT" \
        "org.gnome.desktop.interface color-scheme '$scheme'"$'\n'"org.gnome.Ptyxis interface-style '$style'" \
        APEX_SHOTS="$out" APEX_SHOT="$name"
    log "shoot.sh: $name: exit $?"
    grep -q 'APEXPTYXIS ' "$out/$name.log" && [[ -s $out/$name.png ]]
}

status=0
# The container has no settings portal for libadwaita to read color-scheme from.
shoot light default light || status=1
shoot dark prefer-dark dark || status=1
((status == 0)) || die "shoot.sh: a capture failed; see ${out#"$APEX_ROOT/"}/*.log"
log "shoot.sh: captures in ${out#"$APEX_ROOT/"}"
