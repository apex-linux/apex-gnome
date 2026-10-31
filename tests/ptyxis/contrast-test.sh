#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

PTYXIS_TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly PTYXIS_TESTS
# WCAG 2.2 AA: 1.4.3 for text, 1.4.11 for the status glyphs; CIELAB L* apart for needs you and running.
readonly TEXT_RATIO=4.5 GLYPH_RATIO=3 STATUS_LIGHTNESS=10
readonly SHOTS=(light dark split-light split-dark)
# Apex's own gaps, pending the owner: each under WCAG AA in its capture, at today's ratio.
readonly GAP="the owner's decision on boards 32 and 33's contrast (2026-10-31)"
readonly PINS='{
  "light selectedRow:just vm-image · running": 4.26, "light selectedRow:now": 4.26, "light selectedRow:running": 2.81,
  "light group:toolbox": 4.26, "light group:ssh": 4.26, "light header:tag": 4.39,
  "dark selectedRow:running": 2.7,
  "split-light selectedRow:claude · needs you": 4.26, "split-light selectedRow:now": 4.26,
  "split-light group:toolbox": 4.26, "split-light group:ssh": 4.26, "split-light paneHeader:tag": 4.39,
  "split-light dimmedPaneHeader:path": 2.68, "split-light dimmedPaneHeader:tag": 2.53,
  "split-dark dimmedPaneHeader:path": 3.96, "split-dark dimmedPaneHeader:tag": 3.53
}'

usage() {
    cat <<EOF
usage: tests/ptyxis/contrast-test.sh [SHOTS_DIR]

Boards 32 and 33's contrast in shoot.sh's captures, which APEX_PTYXIS_TARGETS=1 has it take
with the targets contrast-atspi.py reads over AT-SPI (SHOTS_DIR, by default
_build/ptyxis/shots). contrast.py measures each target's ink against its ground as drawn: the
sidebar's labels and status glyphs, the content header's and each pane header's labels, and
each pane's terminal output, in light and dark, the unfocused pane dimmed. Text wants
$TEXT_RATIO:1 and a glyph $GLYPH_RATIO:1; the footer's needs-you and running glyphs want L* $STATUS_LIGHTNESS apart, so
they differ in lightness and not hue alone. A target under its ratio is a known gap at
today's ratio (PINS): a lower one fails, and so does one that reaches its ratio, so the fix
also removes the pin. It needs python3 and jq.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
shots=${1:-$APEX_ROOT/_build/ptyxis/shots}

python3 "$PTYXIS_TESTS/contrast.py" --selftest || die "contrast-test.sh: contrast.py's selftest failed"

# VERDICTS: a line per target of a contrast.json, PASS, FAIL or GAP, for the shot named by $shot.
# shellcheck disable=SC2016 # a jq program
readonly VERDICTS='.[] | select(.kind != "glyph" or .region == "group" or .status != null)
    | (if .kind == "glyph" then $glyph else $text end) as $min
    | "\(.region):\(.part // .status // .name)" as $key | $pins["\($shot) \($key)"] as $today
    | "\($shot) \($key): \(.ink) on \(.ground) at \(.ratio):1" as $what
    | if .ratio == null then "FAIL \($what), not measured"
      elif $today == null then (if .ratio >= $min then "PASS \($what), at least \($min):1" else "FAIL \($what), under \($min):1" end)
      elif .ratio < $today then "FAIL \($what), under today'"'"'s \($today):1"
      elif .ratio >= $min then "FAIL \($what) reaches \($min):1: a known gap until \($gap), but it holds now: remove its pin"
      else "GAP  \($what), under \($min):1 (\($gap))" end'

verdicts() {
    jq -r --arg shot "$1" --arg gap "$GAP" --argjson pins "$PINS" --argjson text "$TEXT_RATIO" \
        --argjson glyph "$GLYPH_RATIO" "$VERDICTS" "$2"
}

failures=0 gaps=0
fail() {
    failures=$((failures + 1))
    log "FAIL - $*"
}
# expect WHAT JQ: one fact about $shot's measurements.
expect() {
    if jq -e "$2" "$shots/$shot.contrast.json" >/dev/null; then log "ok - $shot: $1"; else fail "$shot: $1"; fi
}
for shot in "${SHOTS[@]}"; do
    frame=$(sed -n 's/.*APEXPTYXIS \({.*}\)$/\1/p' "$shots/$shot.log" | jq -r '.frame[2]')
    [[ -s $shots/$shot.targets.json && $frame =~ ^[0-9]+$ ]] ||
        die "contrast-test.sh: no targets for $shot; run shoot.sh with APEX_PTYXIS_TARGETS=1"
    python3 "$PTYXIS_TESTS/contrast.py" "$shots/$shot.png" "$shots/$shot.targets.json" "$frame" >"$shots/$shot.contrast.json"
    while IFS= read -r line; do
        case $line in
            PASS*) log "ok - ${line#PASS }" ;;
            GAP*) gaps=$((gaps + 1)); log "gap - ${line#GAP  }" ;;
            *) fail "${line#FAIL }" ;;
        esac
    done < <(verdicts "$shot" "$shots/$shot.contrast.json")
    expect "the footer's four status glyphs, the selected row and the content header are measured" \
        '([.[] | select(.region == "footer" and .kind == "glyph") | .status] == ["needs you", "running", "failed", "done"])
         and any(.region == "selectedRow") and any(.region == "header")'
    expect "needs you and running differ in lightness, not hue alone: L* $STATUS_LIGHTNESS apart" \
        "[.[] | select(.region == \"footer\" and .kind == \"glyph\") | .lightness] | (.[0] - .[1]) | fabs >= $STATUS_LIGHTNESS"
    [[ $shot != split-* ]] ||
        expect "the unfocused pane's header and output are measured dimmed" \
            'any(.region == "dimmedPaneHeader") and any(.region == "dimmedBody") and any(.region == "paneHeader")'
done

# The checks themselves: a session's name drawn in its row's own fill must fail.
if verdicts light <(jq 'map(if .region == "row" and .kind == "text" then .ink = .ground | .ratio = 1 else . end)' \
    "$shots/light.contrast.json") | grep -q '^FAIL light row:'; then
    log "ok - a session's name in its row's fill colour fails"
else
    fail "a session's name in its row's fill colour passes the checks"
fi

((failures == 0)) || die "contrast-test.sh: $failures check(s) failed; see ${shots#"$APEX_ROOT/"}/*.contrast.json"
log "contrast-test.sh: boards 32 and 33 hold AA but for $gaps known gap(s)"
