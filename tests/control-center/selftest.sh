#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# desktop/control-center ships inside gnome-control-center: its licence, the paths the lane lets Source1 add, and the patches' From: lines.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

readonly SOURCE1=$APEX_ROOT/desktop/control-center
readonly RECIPE=$APEX_ROOT/packaging/pkgs/gnome-control-center
readonly OWNER_FROM='From: Thuong Vo <66083331+SekiroKenjii@users.noreply.github.com>'
readonly SPDX='SPDX-License-Identifier: GPL-2.0-or-later'
# Files that cannot carry a line of their own: apex-system's interface, copied byte for byte (apex-image
# compares the two), and the JSON tile table, which the shell's Spotlight mirrors byte for byte.
readonly CONTRACTS=(panels/apex/io.github.apex_linux.Apex.Update1.xml panels/apex/settings-tiles.json)
readonly TILES=$SOURCE1/panels/apex/settings-tiles.json

fails=0
flunk() {
    fails=$((fails + 1))
    printf 'FAIL: %s\n' "$*" >&2
}

mapfile -t files < <(cd "$SOURCE1" && find . -type f -printf '%P\n' | LC_ALL=C sort)
((${#files[@]} > 0)) || flunk "desktop/control-center is empty"

read -ra allowed <<<"$(sed -n 's/^source1_paths=//p' "$RECIPE/pkg.env")"
for f in "${files[@]}"; do
    [[ " ${CONTRACTS[*]} " == *" $f "* || $(head -n 3 -- "$SOURCE1/$f") == *"$SPDX"* ]] ||
        flunk "desktop/control-center/$f has no GPL-2.0-or-later SPDX line, gnome-control-center's licence"
    inside=false
    for p in "${allowed[@]}"; do
        [[ $f == "$p" || ($p == */ && $f == "$p"*) ]] && inside=true
    done
    $inside || flunk "desktop/control-center/$f is outside the recipe's source1_paths (${allowed[*]})"
done

python3 - "$TILES" <<'PY' || flunk "panels/apex/settings-tiles.json is not the tile table's format"
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
table = json.loads(raw)
assert raw == json.dumps(table, indent=2, sort_keys=True) + "\n", "not sorted, 2-space, newline-terminated"
for panel, colour in table.items():
    assert re.fullmatch(r"[a-z][a-z-]*", panel), panel
    assert colour == "accent" or re.fullmatch(r"#[0-9a-f]{6}", colour), (panel, colour)
PY

while IFS= read -r p; do
    [[ -f $RECIPE/patches/$p ]] || { flunk "series names $p, which is not in patches/"; continue; }
    grep -Fxq -- "$OWNER_FROM" "$RECIPE/patches/$p" || flunk "$p is not from the owner ($OWNER_FROM)"
done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$RECIPE/series")

# a11y.py ports tests/shots/a11y.js's focus rule and contrast ratio: the rule's numbers must match, the ratio known pairs.
python3 -B - "$APEX_ROOT/tests/shots/a11y.js" "$APEX_ROOT/tests/control-center" <<'PY' || flunk "contrast.py drifted from tests/shots/a11y.js"
import re, sys
js = open(sys.argv[1], encoding="utf-8").read()
sys.path.insert(0, sys.argv[2])
import contrast
for name in ("FOCUS_MARGIN", "FOCUS_CHANGED"):
    assert int(re.search(rf"const {name} = (\d+);", js)[1]) == getattr(contrast, name), name
assert int(re.search(r"Math\.round\((\d+) \* \(width \+ height\) \* after\.scale\)", js)[1]) == contrast.PERIMETER_SIDES
for fg, bg, want in (((255, 255, 255), (0, 0, 0), 21.0), ((0x76, 0x76, 0x76), (255, 255, 255), 4.54),
                     ((0x35, 0x84, 0xe4), (255, 255, 255), 3.77)):
    assert round(contrast.ratio(fg, bg), 2) == want, (fg, bg, contrast.ratio(fg, bg))
PY

if ((fails > 0)); then
    die "tests/control-center/selftest.sh: $fails failure(s)"
fi
log "tests/control-center/selftest.sh: ${#files[@]} files of desktop/control-center checked"
