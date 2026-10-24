#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

readonly DEADLINE_MS=1000
readonly SHELL_TIMEOUT=90
readonly BEFORE='#ff0000' AFTER='#00ff00'

usage() {
    cat <<EOF
usage: tests/ptyxis/palette-test.sh [RPM_DIR]

Rewrites the profile's user palette under an open Ptyxis in a headless gnome-shell, as
apex-session-agent rewrites apex.palette, and fails unless the terminal shows the new
background within $DEADLINE_MS ms. As root in a throwaway fedora:$APEX_FEDORA container;
RPM_DIR holds the lane's built RPMs, without it the installed ptyxis is tested. Needs
gnome-shell, mesa-dri-drivers, dbus-daemon, python3-dbusmock, gcc, util-linux and jq;
the log lands in _build/ptyxis/palette/.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
headless_require_container palette-test.sh

out=$APEX_ROOT/_build/ptyxis/palette
rm -rf -- "$out"
mkdir -p -- "$out"
chmod 777 "$out"
[[ -z ${1:-} ]] || headless_install_rpm "$1"
rpm -q ptyxis >"$out/ptyxis.txt"

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

headless_run "$out/palette.log" "$PTYXIS_TESTS/palette-probe.js" "$SHELL_TIMEOUT" \
    "$PROFILE_SCHEMA palette 'apex'" \
    APEX_PALETTE_FILE="$palettes/apex.palette" APEX_PALETTE_REWRITE="$out/rewrite.palette"
log "palette-test.sh: shell exit $?"

result=$(sed -n 's/.*APEXPALETTE //p' "$out/palette.log")
[[ -n $result ]] || die "palette-test.sh: no result; see ${out#"$APEX_ROOT/"}/palette.log"
log "palette-test.sh: $result"
jq -e --argjson deadline "$DEADLINE_MS" \
    '.error == null and .before == [255, 0, 0] and .after == [0, 255, 0] and .ms <= $deadline' \
    <<<"$result" >/dev/null ||
    die "palette-test.sh: the open terminal did not take the rewritten palette within $DEADLINE_MS ms: $result"
log "palette-test.sh: the open terminal took the rewritten palette"
