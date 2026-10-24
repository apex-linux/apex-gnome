#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# desktop/ptyxis ships inside Ptyxis: its licence, and the paths the lane lets Source1 add.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

readonly SOURCE1=$APEX_ROOT/desktop/ptyxis
readonly RECIPE=$APEX_ROOT/packaging/pkgs/ptyxis

fails=0
flunk() {
    fails=$((fails + 1))
    printf 'FAIL: %s\n' "$*" >&2
}

mapfile -t files < <(cd "$SOURCE1" && find . -type f -printf '%P\n' | LC_ALL=C sort)
((${#files[@]} > 0)) || flunk "desktop/ptyxis is empty"

read -ra allowed <<<"$(sed -n 's/^source1_paths=//p' "$RECIPE/pkg.env")"
for f in "${files[@]}"; do
    [[ $(head -n 3 -- "$SOURCE1/$f") == *'SPDX-License-Identifier: GPL-3.0-or-later'* ]] ||
        flunk "desktop/ptyxis/$f has no GPL-3.0-or-later SPDX line, Ptyxis's licence"
    inside=false
    for p in "${allowed[@]}"; do
        [[ $f == "$p" || ($p == */ && $f == "$p"*) ]] && inside=true
    done
    $inside || flunk "desktop/ptyxis/$f is outside the ptyxis recipe's source1_paths (${allowed[*]})"
done

while IFS= read -r p; do
    [[ -f $RECIPE/patches/$p ]] || flunk "series names $p, which is not in patches/"
done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$RECIPE/series")

if ((fails > 0)); then
    die "tests/ptyxis/selftest.sh: $fails failure(s)"
fi
log "tests/ptyxis/selftest.sh: ${#files[@]} files of desktop/ptyxis checked"
