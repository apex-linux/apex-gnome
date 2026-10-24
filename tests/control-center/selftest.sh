#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# desktop/control-center ships inside gnome-control-center: its licence, the paths the lane lets Source1 add, and the patches' From: lines.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

readonly SOURCE1=$APEX_ROOT/desktop/control-center
readonly RECIPE=$APEX_ROOT/packaging/pkgs/gnome-control-center
readonly OWNER_FROM='From: Thuong Vo <66083331+SekiroKenjii@users.noreply.github.com>'
readonly SPDX='SPDX-License-Identifier: GPL-2.0-or-later'

fails=0
flunk() {
    fails=$((fails + 1))
    printf 'FAIL: %s\n' "$*" >&2
}

mapfile -t files < <(cd "$SOURCE1" && find . -type f -printf '%P\n' | LC_ALL=C sort)
((${#files[@]} > 0)) || flunk "desktop/control-center is empty"

read -ra allowed <<<"$(sed -n 's/^source1_paths=//p' "$RECIPE/pkg.env")"
for f in "${files[@]}"; do
    [[ $(head -n 3 -- "$SOURCE1/$f") == *"$SPDX"* ]] ||
        flunk "desktop/control-center/$f has no GPL-2.0-or-later SPDX line, gnome-control-center's licence"
    inside=false
    for p in "${allowed[@]}"; do
        [[ $f == "$p" || ($p == */ && $f == "$p"*) ]] && inside=true
    done
    $inside || flunk "desktop/control-center/$f is outside the recipe's source1_paths (${allowed[*]})"
done

while IFS= read -r p; do
    [[ -f $RECIPE/patches/$p ]] || { flunk "series names $p, which is not in patches/"; continue; }
    grep -Fxq -- "$OWNER_FROM" "$RECIPE/patches/$p" || flunk "$p is not from the owner ($OWNER_FROM)"
done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$RECIPE/series")

if ((fails > 0)); then
    die "tests/control-center/selftest.sh: $fails failure(s)"
fi
log "tests/control-center/selftest.sh: ${#files[@]} files of desktop/control-center checked"
