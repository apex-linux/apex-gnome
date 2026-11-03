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

# --- next-point.yml: updates-testing beside the scripts' own repositories, apart from the stable lane ---
printf '#!/bin/sh\necho "$*"\n' >"$TMP/dnf5" && chmod +x "$TMP/dnf5"
np_dnf5() { NEXT_POINT_DNF5=$TMP/dnf5 "$APEX_ROOT/.github/scripts/next-point.sh" dnf5 "$@"; }
check "next-point: updates-testing joins --repo=updates" "-y --repo=fedora --repo=updates --repo=updates-testing install x" \
    "$(np_dnf5 -y --repo=fedora --repo=updates install x)"
check "next-point: updates-testing-source joins --repo=updates-source" \
    "-q --repo=fedora-source --repo=updates-source --repo=updates-testing-source download --source gnome-shell" \
    "$(np_dnf5 -q --repo=fedora-source --repo=updates-source download --source gnome-shell)"
check "next-point: a call naming no repository enables updates-testing" "--enable-repo=updates-testing -y remove x" \
    "$(np_dnf5 -y remove x)"
check "next-point: a call naming only fedora keeps to it" "--repo=fedora install x" "$(np_dnf5 --repo=fedora install x)"
mkdir -p "$TMP/np-bin"
check_true "next-point: the shim installs ahead of dnf5 on PATH" \
    env NEXT_POINT_SHIM="$TMP/np-bin/dnf5" PATH="$TMP/np-bin:$PATH" "$APEX_ROOT/.github/scripts/next-point.sh" shim
check_false "next-point: a shim that is not the dnf5 on PATH dies" \
    env NEXT_POINT_SHIM="$TMP/np-bin/dnf5" PATH="/usr/bin:/bin" "$APEX_ROOT/.github/scripts/next-point.sh" shim
printf '%s\n' '## direct.sh main' '# 1865 passed, 0 failed, 50 known gaps' >"$TMP/np-g2.log"
printf '%s\n' 'ok - lock-light: a' 'not ok - lock-dark: b' 'ok - greeter: c' 'PASS captures board 12' \
    '# 2 passed, 0 failed, 0 known gaps' '# 28 passed, 2 failed, 0 known gaps' >"$TMP/np-signoff.log"
np_counts() { "$APEX_ROOT/.github/scripts/next-point.sh" counts "$@"; }
check "next-point: counts g2 reads patched.sh's last summary" 1865/0 "$(np_counts g2 "$TMP/np-g2.log")"
check "next-point: counts goldens reads goldens.sh's, the last" 28/2 "$(np_counts goldens "$TMP/np-signoff.log")"
check "next-point: counts shoot counts shoot.sh's TAP lines" 2/1 "$(np_counts shoot "$TMP/np-signoff.log")"
check "next-point: a log without a summary counts ?" "? ?" \
    "$(np_counts goldens "$TMP/dnf5") $(np_counts shoot "$TMP/np-g2.log")"
check "next-point: a missing log counts ?" "? ?" "$(np_counts g2 "$TMP/none") $(np_counts shoot "$TMP/none")"
for cut in "ARG GA_REACHED=0" "ARG GA_REACHED=1" "ARG GA_REACHED=1|FROM x|ARG GA_REACHED" ""; do
    tr '|' '\n' <<<"ARG REPOS_BASE=https://dl.fedoraproject.org/pub/fedora/linux|$cut|FROM x" >"$TMP/np-Containerfile"
    "$APEX_ROOT/.github/scripts/next-point.sh" reopen "$TMP/np-Containerfile" 2>/dev/null
    check "next-point: reopen after '${cut:-the ARG deleted}' gives apex-lane GA_REACHED=0" \
        "--repos-base https://dl.fedoraproject.org/pub/fedora/linux --ga-reached 0" \
        "$("$APEX_ROOT/tests/lib/image-args.sh" "$TMP/np-Containerfile" 2>/dev/null | paste -sd ' ')"
done
# shellcheck disable=SC2016 # the fake's own script, expanded when it runs
printf '%s\n' '#!/bin/sh' 'case $NP_FAKE in fail) exit 1 ;; empty) exit 0 ;; esac' \
    'case " $* " in *" --repo=updates-testing "*) echo "$NP_TESTING" ;; *) echo pkg-1.0-1.fc45 ;; esac' >"$TMP/np-repoquery"
chmod +x "$TMP/np-repoquery"
np_allow() {
    env NEXT_POINT_DNF5="$TMP/np-repoquery" NP_FAKE="$1" NP_TESTING="$2" \
        "$APEX_ROOT/.github/scripts/next-point.sh" allowlist "$TMP/np-allow" 2>"$TMP/np-allow.err"
}
check_true "next-point: allowlist, something moves" np_allow ok pkg-1.1-1.fc45
check "next-point: allowlist names the moved build" pkg-1.1-1.fc45 "$(sort -u "$TMP/np-allow")"
check_true "next-point: allowlist, nothing moves, is not a failure" np_allow ok pkg-1.0-1.fc45
check "next-point: nothing moves leaves the allowlist empty and says so" "0 1" \
    "$(wc -c <"$TMP/np-allow") $(grep -c '(nothing moves)' "$TMP/np-allow.err")"
check_false "next-point: allowlist, dnf5 failing, dies" np_allow fail ''
check "next-point: a failed query says it could not ask" 1 "$(grep -c 'cannot ask' "$TMP/np-allow.err")"
check_false "next-point: allowlist, dnf5 finding no build, dies" np_allow empty ''
check_false "next-point: reopen of no Containerfile dies" "$APEX_ROOT/.github/scripts/next-point.sh" reopen "$TMP/none"
check "next-point.yml: dispatch and schedule only, no lane cache" "" \
    "$(grep -nE 'pull_request|push:|actions/cache|APEX_LANE_CACHE' "$APEX_ROOT/.github/workflows/next-point.yml" | grep -vE '^[0-9]+: *#')"
check "next-point.yml: the report waits on and prints every job's result" "1 1" \
    "$(grep -c 'needs: \[lane, g2, signoff, apps, libadwaita, ptyxis\]' "$APEX_ROOT/.github/workflows/next-point.yml") \
$(grep -cE 'app (libadwaita|ptyxis)\)' "$APEX_ROOT/.github/workflows/next-point.yml")"
check "next-point.sh: run by next-point.yml alone" ".github/workflows/next-point.yml" \
    "$(cd "$APEX_ROOT" && grep -l 'next-point.sh' .github/workflows/*.yml | paste -sd ' ')"
check "the stable lane names no updates-testing: lane.sh and image-args.sh fetch as before" "" \
    "$(grep -l 'updates-testing' "$APEX_ROOT/tests/lib/lane.sh" "$APEX_ROOT/tests/lib/image-args.sh")"

# --- lint/tokens.sh: colours stay in _apex-tokens.scss, and every token is used ---------------
TK=$TMP/tokens
TAB=$'\t'
mkdir -p "$TK/root/theme"
tokens_case() {
    printf '%s\n' "\$apex_fg: #1d1d21;" "\$apex_dim: .5;" "\$apex_spare: 1px;" >"$TK/root/theme/_apex-tokens.scss"
    printf '%s\n' "#panel { color: \$apex_fg; }" ".a { color: rgba(\$apex_fg, \$apex_dim); }" "$@" >"$TK/root/theme/_x.scss"
    printf '%s\n' "\`\$apex_spare\` in the README only" >"$TK/root/README.md"
}
tokens_allow() { printf '%s\n' "\$apex_spare${TAB}unused, for the test" "$@" >"$TK/allow"; }
tokens_run() { APEX_TOKENS_THEME="$TK/root/theme" APEX_TOKENS_ROOT="$TK/root" APEX_TOKENS_ALLOW="$TK/allow" "$APEX_ROOT/lint/tokens.sh"; }
tokens_case
tokens_allow
check_true "tokens: tokens only, an id selector and an allowed unused token pass" tokens_run
printf '' >"$TK/allow"
check_false "tokens: a token used only in a README is unused" tokens_run
tokens_allow
for bad in '.b { color: #fff; }' '.b { box-shadow: 0 1px 2px rgba(0, 0, 0, .2); }' ".b { color: rgba(\$apex_fg, .9); }" \
    '.b { color: rgb(1, 2, 3); }'; do
    tokens_case "$bad"
    check_false "tokens: '$bad' is a colour literal" tokens_run
done
tokens_case ".b { color: transparentize(\$apex_fg, 1 - \$apex_dim); }" '.c { color: #fff; } // #000 in a comment'
tokens_allow "_x.scss:4${TAB}the white, for the test"
check_true "tokens: an allowed FILE:LINE passes, a comment and a token-only expression do not count" tokens_run
tokens_allow "_x.scss:4${TAB}the white, for the test" "_x.scss:9${TAB}gone"
check_false "tokens: a stale entry fails" tokens_run
check_true "tokens: the repository's theme passes with lint/tokens.allow" "$APEX_ROOT/lint/tokens.sh"

if ((FAILS > 0)); then
    die "selftest: $FAILS failure(s)"
fi
log "selftest: all $TESTS checks passed"
