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

# --- lane.sh reads apex-lane's arguments from apex-image's Containerfile ------------------
image_args() {
    printf '%s\n' "$@" >"$TMP/Containerfile"
    "$APEX_ROOT/tests/lib/image-args.sh" "$TMP/Containerfile" 2>/dev/null | paste -sd ' '
}
readonly REPOS_ARG='ARG REPOS_BASE=https://dl.fedoraproject.org/pub/fedora/linux'
for ga in 0 1; do
    check "image-args: GA_REACHED=$ga is passed on" "--repos-base https://dl.fedoraproject.org/pub/fedora/linux --ga-reached $ga" \
        "$(image_args FROM x "$REPOS_ARG" "ARG GA_REACHED=$ga")"
done
check "image-args: apex-image's two declarations, the default before FROM and the bare one after" \
    "--repos-base https://dl.fedoraproject.org/pub/fedora/linux --ga-reached 0" \
    "$(image_args "ARG GA_REACHED=0" "$REPOS_ARG" FROM x "ARG GA_REACHED")"
check "image-args: no ARG GA_REACHED (the admission cut) leaves the flag out" \
    "--repos-base https://dl.fedoraproject.org/pub/fedora/linux" "$(image_args FROM x "$REPOS_ARG")"
for bad in "ARG GA_REACHED=2" "ARG GA_REACHED=yes" "ARG GA_REACHED=" "ARG GA_REACHED"; do
    printf '%s\n' "$REPOS_ARG" "$bad" >"$TMP/Containerfile"
    check_false "image-args: '$bad' dies" "$APEX_ROOT/tests/lib/image-args.sh" "$TMP/Containerfile"
done
printf '%s\n' "ARG GA_REACHED=1" >"$TMP/Containerfile"
check_false "image-args: no ARG REPOS_BASE dies" "$APEX_ROOT/tests/lib/image-args.sh" "$TMP/Containerfile"

# --- signoff.yml runs on a pull request that can change the captures ---------------------
signoff_paths() { printf '%s\n' "$@" | "$APEX_ROOT/.github/scripts/signoff-paths.sh" 2>/dev/null; }
for f in desktop/shell/data/theme/apex/_input.scss packaging/pkgs/gnome-shell/patches/0010-panel.patch \
    tests/shots/probe.js tests/shots/direct.sh tests/shots/signoff.sh tests/shots/fixtures.py tests/shots/glass.js \
    tests/shell/shoot.sh tests/lib/pins.sh tests/layer/fixtures/io.github.apex_linux.Apex.Desktop.gschema.xml \
    .github/workflows/signoff.yml desktop/control-center/panels/apex/settings-tiles.json desktop/nautilus/src/apex/apex-count-bar.c \
    desktop/ptyxis/src/apex/apex-glyph.c packaging/pkgs/gnome-control-center/check.sh packaging/pkgs/nautilus/patches/0001-build.patch \
    packaging/pkgs/ptyxis/check.sh packaging/pkgs/libadwaita/check.sh tests/control-center/bindings.py tests/nautilus/check.py \
    tests/ptyxis/fixture.c; do
    check "signoff runs on a pull request changing $f" touches=true "$(signoff_paths README.md "$f")"
done
for f in tests/shots/README.md tests/shots/selftest.sh tests/shots/assert.sh tests/shots/stable.sh \
    tests/s2c/radius-test.sh tests/s7/accent-test.sh tests/libadwaita/radius-test.sh tests/laptop/selftest.sh \
    .github/workflows/ci.yml docs/x.md; do
    check "signoff skips a pull request changing only $f" touches=false "$(signoff_paths "$f")"
done
check "signoff skips a pull request with no changed path" touches=false "$(signoff_paths)"

if ((FAILS > 0)); then
    die "selftest: $FAILS failure(s)"
fi
log "selftest: all $TESTS checks passed"
