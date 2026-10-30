#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/headless.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/headless.sh"

PTYXIS_TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly PTYXIS_TESTS

readonly DEADLINE_MS=1000
readonly SHELL_TIMEOUT=90
readonly BEFORE='#ff0000' AFTER='#00ff00'
# libadwaita's accents, which apex-session-agent writes as the palette's Cursor.
readonly CARET_FROM=blue CARET_FROM_HEX='#3584e4' CARET_TO=green CARET_TO_HEX='#3a944a'
readonly APEX_SCHEMA_FIXTURE=$PTYXIS_TESTS/../layer/fixtures/io.github.apex_linux.Apex.Desktop.gschema.xml
readonly SCHEMA_DIR=/usr/share/glib-2.0/schemas

usage() {
    cat <<EOF
usage: tests/ptyxis/palette-test.sh [RPM_DIR [AGENT]]

Rewrites the profile's user palette under an open Ptyxis in a headless gnome-shell, as
apex-session-agent rewrites apex.palette, and fails unless the terminal shows the new
background within $DEADLINE_MS ms. Then starts apex-session-agent (AGENT, by default
tests/s2c/agent.sh's _build/s2c/apex-session-agent) with the accent $CARET_FROM, turns the
accent $CARET_TO, and fails unless the open terminal's caret turns $CARET_TO within
$DEADLINE_MS ms. As root in a throwaway fedora:$APEX_FEDORA container; RPM_DIR holds the
lane's built RPMs, without it the installed ptyxis is tested. Needs gnome-shell,
mesa-dri-drivers, dbus-daemon, python3-dbusmock, gcc, util-linux and jq; the logs land in
_build/ptyxis/palette/.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
headless_require_container palette-test.sh
agent=${2:-$APEX_ROOT/_build/s2c/apex-session-agent}
[[ -x $agent ]] || die "palette-test.sh: no agent at $agent (tests/s2c/agent.sh)"

out=$APEX_ROOT/_build/ptyxis/palette
rm -rf -- "$out"
mkdir -p -- "$out"
chmod 777 "$out"
[[ -z ${1:-} ]] || headless_install_rpm "$1" ptyxis
rpm -q ptyxis >"$out/ptyxis.txt"
install -m 644 "$APEX_SCHEMA_FIXTURE" "$SCHEMA_DIR/"
glib-compile-schemas "$SCHEMA_DIR" || die "palette-test.sh: glib-compile-schemas failed"

palette() {
    printf '[Palette]\nName=Apex\nBackground=%s\nForeground=#ffffff\nCursor=#ffffff\n' "$1"
    for i in $(seq 0 15); do printf 'Color%d=#808080\n' "$i"; done
}

headless_user
palettes=$HEADLESS_HOME/.local/share/org.gnome.Ptyxis/palettes
install -d -o "$USER_NAME" "$palettes"
palette "$BEFORE" >"$palettes/apex.palette"
palette "$AFTER" >"$out/rewrite.palette"
chown -R "$USER_NAME:" "$HEADLESS_HOME"
headless_bus "$out"

caret_accents=$(jq -nc --arg from "$CARET_FROM" --arg fromHex "$CARET_FROM_HEX" --arg to "$CARET_TO" \
    --arg toHex "$CARET_TO_HEX" '[{name: $from, hex: $fromHex}, {name: $to, hex: $toHex}]')
# A blinking caret would be off for some of the polls.
headless_run "$out/palette.log" "$PTYXIS_TESTS/palette-probe.js" "$SHELL_TIMEOUT" \
    "$PROFILE_SCHEMA palette 'apex'
org.gnome.Ptyxis cursor-blink-mode 'off'
org.gnome.desktop.interface accent-color '$CARET_FROM'" \
    APEX_PALETTE_FILE="$palettes/apex.palette" APEX_PALETTE_REWRITE="$out/rewrite.palette" \
    APEX_AGENT="$agent" APEX_AGENT_LOG="$out/agent.log" APEX_CARET_ACCENTS="$caret_accents" RUST_LOG=info
log "palette-test.sh: shell exit $?"

result=$(sed -n 's/.*APEXPALETTE //p' "$out/palette.log")
[[ -n $result ]] || die "palette-test.sh: no result; see ${out#"$APEX_ROOT/"}/palette.log"
log "palette-test.sh: $result"
jq -e --argjson deadline "$DEADLINE_MS" \
    '.error == null and .before == [255, 0, 0] and .after == [0, 255, 0] and .ms <= $deadline' \
    <<<"$result" >/dev/null ||
    die "palette-test.sh: the open terminal did not take the rewritten palette within $DEADLINE_MS ms: $result"
log "palette-test.sh: the open terminal took the rewritten palette"
rgb() { printf '[%d, %d, %d]' "0x${1:1:2}" "0x${1:3:2}" "0x${1:5:2}"; }
jq -e --argjson deadline "$DEADLINE_MS" --argjson from "$(rgb "$CARET_FROM_HEX")" \
    --argjson to "$(rgb "$CARET_TO_HEX")" \
    '.caret.agentRunning and .caret.before == $from and .caret.after == $to and .caret.ms <= $deadline' \
    <<<"$result" >/dev/null ||
    die "palette-test.sh: the open terminal's caret did not follow the accent within $DEADLINE_MS ms: $result"
log "palette-test.sh: the open terminal's caret followed the accent"
