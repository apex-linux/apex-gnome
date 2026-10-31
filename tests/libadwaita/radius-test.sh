#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/headless.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/headless.sh"

LIBADWAITA_TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly LIBADWAITA_TESTS

readonly DEADLINE_MS=1000
readonly SHELL_TIMEOUT=90
# VTE's own critical, present in --stock too: the headless terminal's first size is 0 columns.
readonly VTE_ZERO_COLUMNS="void vte_terminal_set_size(VteTerminal*, long int, long int): assertion 'columns >= 1' failed"

usage() {
    cat <<EOF
usage: tests/libadwaita/radius-test.sh RPM_DIR | --stock | --late RPM_DIR

Rewrites \$XDG_CONFIG_HOME/gtk-4.0/apex.css from a 14 px window radius to 0 px under an
open Ptyxis in a headless gnome-shell, atomically, as apex-session-agent writes it.
With RPM_DIR, the lane's libadwaita from it, the window's corner must turn square
within $DEADLINE_MS ms; with --stock, Fedora's own libadwaita, it must stay rounded.
With --late, a first login: Ptyxis starts with no gtk-4.0/ at all, so stock-rounded and
with no warning or critical but VTE's 0-column one, then gtk-4.0/apex.css appears at 0 px and the
corner must turn square within $DEADLINE_MS ms.
As root in a throwaway fedora:$APEX_FEDORA container, with ptyxis, gnome-shell,
mesa-dri-drivers, dbus-daemon, python3-dbusmock, gcc, util-linux and jq installed; the
log lands in _build/libadwaita/radius/.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    "") usage >&2; exit 2 ;;
esac
headless_require_container radius-test.sh
command -v ptyxis >/dev/null || die "radius-test.sh: no ptyxis, the libadwaita window it opens"

out=$APEX_ROOT/_build/libadwaita/radius
rm -rf -- "$out"
mkdir -p -- "$out"
chmod 777 "$out"
late=0
if [[ $1 == --stock ]]; then
    expect=rounded
    [[ $(rpm -q libadwaita) != *.apex* ]] || die "radius-test.sh --stock: the installed libadwaita is Apex's"
else
    expect=square
    if [[ $1 == --late ]]; then
        late=1
        shift
        [[ -n ${1:-} ]] || { usage >&2; exit 2; }
    fi
    headless_install_rpm "$1" libadwaita
fi
rpm -q libadwaita ptyxis >"$out/rpms.txt"

sheet() {
    printf ':root { --window-radius: %s; }\n' "$1"
    printf 'window.maximized, window.fullscreen, window.tiled, window.tiled-top, window.tiled-bottom,\n'
    printf 'window.tiled-left, window.tiled-right, window.solid-csd { --window-radius: 0px; }\n'
}

headless_user
config=$HEADLESS_HOME/.config/gtk-4.0
install -d -o "$USER_NAME" "$HEADLESS_HOME/.config"
rm -rf -- "$config"
((late)) || { install -d -o "$USER_NAME" "$config" && sheet 14px >"$config/apex.css"; }
sheet 0px >"$out/rewrite.css"
chown -R "$USER_NAME:" "$HEADLESS_HOME"
headless_bus "$out"

# The container has no settings portal for libadwaita to read color-scheme from.
headless_run "$out/radius.log" "$LIBADWAITA_TESTS/radius-probe.js" "$SHELL_TIMEOUT" \
    "org.gnome.Ptyxis interface-style 'light'" \
    APEX_CSS_FILE="$config/apex.css" APEX_CSS_REWRITE="$out/rewrite.css"
log "radius-test.sh: shell exit $?"

result=$(sed -n 's/.*APEXRADIUS //p' "$out/radius.log")
[[ -n $result ]] || die "radius-test.sh: no result; see ${out#"$APEX_ROOT/"}/radius.log"
log "radius-test.sh: $result"
jq -e '.error == null and .square_before == false' <<<"$result" >/dev/null ||
    die "radius-test.sh: the window was not rounded before the rewrite: $result"
if ((late)); then
    warnings=$(grep -E '\(ptyxis:[0-9]+\): [A-Za-z-]+-(WARNING|CRITICAL)' "$out/radius.log" |
        awk -v m="$VTE_ZERO_COLUMNS" '!(index($0, "VTE-CRITICAL") && index($0, m))')
    [[ -z $warnings ]] || die "radius-test.sh --late: Ptyxis warned with no gtk-4.0/apex.css: $warnings"
    log "radius-test.sh: with no gtk-4.0/ Ptyxis started rounded and warned nothing"
fi
if [[ $expect == square ]]; then
    jq -e --argjson deadline "$DEADLINE_MS" '.square_after and .ms <= $deadline' <<<"$result" >/dev/null ||
        die "radius-test.sh: the open window did not take the 0 px radius within $DEADLINE_MS ms: $result"
    log "radius-test.sh: the open window took the rewritten apex.css"
else
    jq -e '.square_after == false' <<<"$result" >/dev/null ||
        die "radius-test.sh: Fedora's libadwaita followed apex.css, so the test proves nothing: $result"
    log "radius-test.sh: Fedora's libadwaita kept the window rounded"
fi
