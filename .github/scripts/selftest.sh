#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Against fakes only: no network, no root, no KVM.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require awk sed mktemp git find

FAILS=0
TESTS=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { TESTS=$((TESTS + 1)); }
flunk() {
    TESTS=$((TESTS + 1))
    FAILS=$((FAILS + 1))
    printf 'FAIL: %s\n' "$*" >&2
}

check() {
    local name=$1 expected=$2 actual=$3
    if [[ $expected == "$actual" ]]; then pass; else flunk "$name: expected '$expected', got '$actual'"; fi
}

check_true() {
    local name=$1
    shift
    if (set +e; "$@") >/dev/null 2>&1; then pass; else flunk "$name: expected success"; fi
}
check_false() {
    local name=$1
    shift
    if (set +e; "$@") >/dev/null 2>&1; then flunk "$name: expected failure"; else pass; fi
}

# --- desktop/shell ships inside gnome-shell under gnome-shell's licence -------------------
# JSON has no comments: the Settings tile colours mirror gnome-control-center's copy byte for byte.
readonly SPDX_EXEMPT=js/ui/apex/spotlight/settings-tiles.json
unlicensed=$(cd "$APEX_ROOT/desktop/shell" && find . -type f -printf '%P\n' | LC_ALL=C sort | while IFS= read -r f; do
    [[ $f == "$SPDX_EXEMPT" ]] && continue
    [[ $(head -n 3 -- "$f") == *'SPDX-License-Identifier: GPL-2.0-or-later'* ]] || printf '%s ' "$f"
done)
check "desktop/shell: every file is GPL-2.0-or-later (SPDX)" "" "$unlicensed"
readonly TILES_CANONICAL=desktop/control-center/panels/apex/settings-tiles.json
check "desktop/shell's Settings tile colours are gnome-control-center's, byte for byte" "" \
    "$(cmp -- "$APEX_ROOT/$TILES_CANONICAL" "$APEX_ROOT/desktop/shell/$SPDX_EXEMPT" 2>&1)"
read -ra allowed <<<"$(sed -n 's/^source1_paths=//p' "$APEX_ROOT/packaging/pkgs/gnome-shell/pkg.env")"
outside=$(cd "$APEX_ROOT/desktop/shell" && find . -type f -printf '%P\n' | LC_ALL=C sort | while IFS= read -r f; do
    for p in "${allowed[@]}"; do
        [[ $f == "$p" || ($p == */ && $f == "$p"*) ]] && continue 2
    done
    printf '%s ' "$f"
done)
check "desktop/shell: every file is in the gnome-shell recipe's source1_paths" "" "$outside"

# --- .gitignore: biometric data never gets tracked --------------------------------------
for f in a.pgm B.PGM x/print.Variant rec.ioctl x/y/rec.UMOCKDEV cap.pcap cap.PcapNG var/lib/fprint/u/1; do
    check_true ".gitignore ignores $f" git -C "$APEX_ROOT" check-ignore -q --no-index "$f"
done
check_false ".gitignore keeps the layer's fixtures" \
    git -C "$APEX_ROOT" check-ignore -q --no-index tests/layer/fixtures/apex-shell-safe.service

if ((FAILS > 0)); then
    die "selftest: $FAILS failure(s)"
fi
log "selftest: all $TESTS checks passed"
