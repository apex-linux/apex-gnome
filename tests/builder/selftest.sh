#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# desktop/gnome-builder ships inside GNOME Builder (Apex Code): its licence, and the paths the lane lets Source1 add.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

readonly SOURCE1=$APEX_ROOT/desktop/gnome-builder
readonly RECIPE=$APEX_ROOT/packaging/pkgs/gnome-builder
readonly OWNER_FROM='From: Thuong Vo <66083331+SekiroKenjii@users.noreply.github.com>'

fails=0
flunk() {
    fails=$((fails + 1))
    printf 'FAIL: %s\n' "$*" >&2
}

mapfile -t files < <(cd "$SOURCE1" && find . -type f -printf '%P\n' | LC_ALL=C sort)
((${#files[@]} > 0)) || flunk "desktop/gnome-builder is empty"

read -ra allowed <<<"$(sed -n 's/^source1_paths=//p' "$RECIPE/pkg.env")"
for f in "${files[@]}"; do
    [[ $(head -n 3 -- "$SOURCE1/$f") == *'SPDX-License-Identifier: GPL-3.0-or-later'* ]] ||
        flunk "desktop/gnome-builder/$f has no GPL-3.0-or-later SPDX line, GNOME Builder's licence"
    inside=false
    for p in "${allowed[@]}"; do
        [[ $f == "$p" || ($p == */ && $f == "$p"*) ]] && inside=true
    done
    $inside || flunk "desktop/gnome-builder/$f is outside the gnome-builder recipe's source1_paths (${allowed[*]})"
done

while IFS= read -r p; do
    [[ -f $RECIPE/patches/$p ]] || { flunk "series names $p, which is not in patches/"; continue; }
    grep -Fxq -- "$OWNER_FROM" "$RECIPE/patches/$p" || flunk "$p is not from the owner ($OWNER_FROM)"
done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$RECIPE/series")

if ((fails > 0)); then
    die "tests/builder/selftest.sh: $fails failure(s)"
fi
log "tests/builder/selftest.sh: ${#files[@]} files of desktop/gnome-builder checked"
