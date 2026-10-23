#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/selftest.sh

G2's own logic, without a VM or an image: png.js and compare.js, the token file as
assert.sh reads it, the top-bar, clock and layer-cycle assertions against reports built
for them, and fixtures.py on a private bus, read back through libnm, gnome-bluetooth and
UPower's D-Bus API as the shell reads them. Needs gjs and jq (without them it skips, or
fails with APEX_SHOTS_TESTS_NO_SKIP=1), GdkPixbuf for png.js's cross-check against
libpng, and for the fixtures dbus-daemon, python3-dbusmock and the NM and GnomeBluetooth
typelibs. Output is TAP.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
esac

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
NO_SKIP=${APEX_SHOTS_TESTS_NO_SKIP:-0}

tests=0
failed=0
ok() { tests=$((tests + 1)); printf 'ok %d - %s\n' "$tests" "$*"; }
not_ok() { tests=$((tests + 1)); failed=$((failed + 1)); printf 'not ok %d - %s\n' "$tests" "$*"; }
expect_eq() {
    local name=$1 expected=$2 actual=$3
    if [[ $expected == "$actual" ]]; then ok "$name"; else not_ok "$name (expected '$expected', got '$actual')"; fi
}

for tool in gjs jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        if [[ $NO_SKIP == 1 ]]; then
            printf 'not ok 1 - %s not found, but APEX_SHOTS_TESTS_NO_SKIP=1\n1..1\n' "$tool"
            exit 1
        fi
        printf '1..0 # SKIP %s not found\n' "$tool"
        exit 0
    fi
done

T=$(mktemp -d "${TMPDIR:-/tmp}/apex-shots-test.XXXXXX")
trap 'kill "$(head -n 1 "$T/bus.pid" 2>/dev/null)" 2>/dev/null; rm -rf "$T"' EXIT
# shellcheck source=tests/shots/lib.sh
. "$HERE/lib.sh"

test_png_js() {
    local png_rc=0 line
    gjs -m "$HERE/png-test.js" "$T" >"$T/png.tap" 2>&1 || png_rc=$?
    while IFS= read -r line; do
        case $line in
            'ok '*'# SKIP '*) tests=$((tests + 1)); printf 'ok %d # SKIP png.js: %s\n' "$tests" "${line#*# SKIP }" ;;
            'ok '*) ok "png.js: ${line#* - }" ;;
            'not ok '*) not_ok "png.js: ${line#* - }" ;;
        esac
    done <"$T/png.tap"
    if ((png_rc != 0)) && ! grep -q '^not ok' "$T/png.tap"; then
        not_ok "png-test.js exited $png_rc: $(tail -n 3 "$T/png.tap" | paste -sd'|' -)"
    fi
}

write_compare_fixtures() {
    cat >"$T/make.js" <<EOF
import GLib from 'gi://GLib';
import * as Png from 'file://$HERE/png.js';

function image(width, height, changed = []) {
    const rgba = new Uint8Array(width * height * 4).fill(200);
    for (const [x, y] of changed)
        rgba[(y * width + x) * 4] = 7;
    return {width, height, rgba};
}
const write = (name, img) => GLib.file_set_contents('$T/' + name, Png.encode(img));
write('base.png', image(40, 30));
write('same.png', image(40, 30));
write('in-mask.png', image(40, 30, [[2, 1], [39, 3]]));
write('outside.png', image(40, 30, [[2, 1], [10, 20], [12, 22]]));
write('smaller.png', image(39, 30));
EOF
    gjs -m "$T/make.js"
}

compare_status() {
    local plan=$1
    printf '%s\n' "$plan" >"$T/plan.json"
    local rc=0
    gjs -m "$HERE/compare.js" "$T/plan.json" "$T/results.json" 2>"$T/compare.err" || rc=$?
    echo "$rc"
}
pair() {
    local name=$1 actual=$2 masks=${3:-}
    printf '{"name": "%s", "expected": "%s/base.png", "actual": "%s/%s", "diff": "%s/%s-diff.png", "masks": [%s]}' \
        "$name" "$T" "$T" "$actual" "$T" "$name" "$masks"
}

test_compare_js() {
    local panel='{"name": "panel", "x": 0, "y": 0, "width": 40, "height": 4}'
    write_compare_fixtures
    expect_eq "compare.js: identical captures are equal" 0 "$(compare_status "[$(pair same same.png)]")"
    expect_eq "compare.js: and nothing differs" 0 "$(jq '.[0].differing' "$T/results.json")"
    expect_eq "compare.js: differences inside the masks do not count" 0 "$(compare_status "[$(pair masked in-mask.png "$panel")]")"
    expect_eq "compare.js: the masked pixels are counted" 160 "$(jq '.[0].masked' "$T/results.json")"
    expect_eq "compare.js: a difference outside the masks fails" 1 "$(compare_status "[$(pair outside outside.png "$panel")]")"
    expect_eq "compare.js: it counts the differing pixels" 2 "$(jq '.[0].differing' "$T/results.json")"
    expect_eq "compare.js: and bounds them" '{"x":10,"y":20,"width":3,"height":3}' "$(jq -c '.[0].box' "$T/results.json")"
    if [[ -s $T/outside-diff.png ]]; then ok "compare.js: it writes the difference image"; else not_ok "compare.js: it writes the difference image"; fi
    expect_eq "compare.js: one failing pair fails the plan" 1 \
        "$(compare_status "[$(pair same same.png), $(pair outside outside.png)]")"
    expect_eq "compare.js: captures of different sizes cannot be compared" 2 "$(compare_status "[$(pair smaller smaller.png)]")"
    expect_eq "compare.js: and say so" '"sizes differ: 40x30 against 39x30"' "$(jq -c '.[0].error' "$T/results.json")"
    expect_eq "compare.js: a missing capture cannot be compared" 2 "$(compare_status "[$(pair missing missing.png)]")"
    expect_eq "compare.js: a plan it cannot read is an error, not a difference" 2 "$(compare_status 'not json')"
}

test_token_file() {
    local token_lines missing
    cat >"$T/tokens.scss" <<'EOF'
// a comment line
$apex_a: if($variant == 'light', rgba(1, 2, 3, .5), rgba(4, 5, 6, .25));
$apex_b: if($variant == "dark", #111111, #222222); // trailing comment
$apex_c: 12px !default;
$panel_bg_color: $apex_a;
EOF
    # shellcheck disable=SC2016 # SCSS variables, not shell ones
    expect_eq "tokens: if() splits at its top-level commas; comments, !default and upstream reassignments" \
        '{"apex_a":{"light":"rgba(1, 2, 3, .5)","dark":"rgba(4, 5, 6, .25)"},"apex_b":{"light":"#222222","dark":"#111111"},"apex_c":{"light":"12px","dark":"12px"},"panel_bg_color":{"light":"$apex_a","dark":"$apex_a"}}' \
        "$(tokens_json "$T/tokens.scss" | jq -c .)"
    expect_eq "tokens: colours become bytes, alpha rounded" '[[1,2,3,128],[34,34,34,255],[250,250,252,115]]' \
        "$(jq -nc "$JQ_DEFS [(\"rgba(1, 2, 3, .5)\" | rgba), (\"#222\" | rgba), (\"rgba(250,250,252,0.45)\" | rgba)]")"
    expect_eq "tokens: St's rounding of alpha is within one step" true \
        "$(jq -n "$JQ_DEFS \"#fafafc72\" | colour_is(\"rgba(250, 250, 252, .45)\")")"

    # shellcheck disable=SC2016 # SCSS and jq variables, not shell ones
    token_lines=$(grep -c '^\$apex_' "$TOKEN_FILE")
    expect_eq "tokens: every \$apex_ line of _apex-tokens.scss is read" "$token_lines" \
        "$(tokens_json | jq '[keys[] | select(startswith("apex_"))] | length')"
    # shellcheck disable=SC2016 # SCSS and jq variables, not shell ones
    missing=$(LC_ALL=C comm -23 <(grep -o '\$t\.apex_[a-z0-9_]*' "$HERE/assert.sh" | sed 's/^\$t\.//' | LC_ALL=C sort -u) \
        <(tokens_json | jq -r 'keys[]' | LC_ALL=C sort))
    expect_eq "tokens: every token the top-bar assertions use is in _apex-tokens.scss" '' "$missing"
}

# What S1a cannot draw yet holds the values the built image measured (tests/shots/README.md).
# shellcheck disable=SC2016 # a jq program
REPORT_OF_A_BAR_DRAWN_FROM_TOKENS='
($t.apex_bar_height | px) as $h | ($t.apex_bar_padding | px) as $pad | ($t.apex_bar_pill_padding | px) as $pp
| ($t.apex_bar_fg | hex) as $fg | ($t.apex_bar_hover | hex) as $hover
| ($t.apex_bar_dot_size | px) as $dot | ($t.apex_radius_workspace_dot | px) as $dot_radius
| ($t.apex_bar_clock_gap | px) as $clock_gap | ($t.apex_bar_clock_dot_size | px) as $clock_dot
| ($t.apex_bar_icon_size | px) as $icon | ($t.apex_font_bar_size | px) as $text_size
| ["bluetooth-active-symbolic", "network-wireless-signal-excellent-symbolic", "battery-level-80-symbolic"] as $glyphs
| ($glyphs | map({name: ., width: $icon, height: $icon, iconSize: $icon})) as $glyph_sizes
| {height: ($t.apex_bar_pill_height | px), radius: ($t.apex_radius_bar_pill | px), background: "#00000000",
   hover: {background: $hover}, checked: {background: $hover}, padding: {left: $pp, right: $pp}} as $pill
| {height: $h, foreground: $fg} as $button
| {size: ($t.apex_font_bar_size | px), weight: ($t.apex_font_bar_weight | tonumber), features: null} as $font
| {monitorScale: 2, topBar: {
    panel: {height: $h, width: 1440, background: ($t.apex_bar | hex), foreground: $fg, font: $font,
        transition: ($t.apex_bar_transition | rtrimstr("ms") | tonumber)},
    left: {padding: {left: 0, right: 0}, spacing: ($t.apex_bar_gap | px)},
    right: {padding: {left: 0, right: 0}, spacing: ($t.apex_bar_gap | px)},
    activities: ($button + {x: 0, pill: ($pill + {x: $pad, spacing: ($t.apex_bar_dots_gap | px),
        padding: {left: ($pp + ($t.apex_bar_diamond_size | px) + ($t.apex_bar_activities_gap | px)), right: $pp}})}),
    clock: ($button + {pill: ($pill + {x: 670, width: 100}),
        label: {font: ($font + {weight: ($t.apex_font_bar_emphasis_weight | tonumber)}), foreground: $fg}}),
    status: ($button + {x: (1440 - $pad - 90), width: (90 + $pad),
        pill: ($pill + {x: (1440 - $pad - 90), width: 90, spacing: ($t.apex_bar_status_gap | px)})}),
    statusGlyphs: $glyph_sizes,
    statusLabels: [{text: "87%", font: ($font + {size: ($t.apex_font_bar_percentage_size | px)}), foreground: $fg}],
    accent: "#3584e4ff",
    lockScreen: {status: {x: 1342, width: 98, pill: {x: 1342, width: 98}},
        statusHover: {background: "#00000000", boxShadow: {color: "#ffffff2b", inset: true, x: 0, y: 0, blur: 0, spread: 100}}},
    largeText: {textScalingFactor: 1.25, barHeight: $h, clockPillHeight: ($t.apex_bar_pill_height | px),
        clockText: {size: (1.25 * $text_size), weight: ($t.apex_font_bar_emphasis_weight | tonumber), height: 24, naturalHeight: 21},
        statusGlyphs: $glyph_sizes},
    diamond: {box: {x: 16, y: 8, width: 60, height: 48}, colour: $fg, inkPixels: 180},
    dots: [{active: true, x: 38, y: 12.5, width: 25, height: $dot, opacity: 1, radius: $dot_radius},
           {active: false, x: 68.875, y: 13.375, width: 5.25, height: 5.25, opacity: 0.498, radius: $dot_radius}],
    withDot: {dot: {visible: true, width: $clock_dot, height: $clock_dot, radius: ($t.apex_radius_clock_dot | px),
            background: $fg},
        labelWidth: 120, pillWidth: (120 + 2 * $pp + 2 * ($clock_gap + $clock_dot))},
    clockTextGap: 7.041,
    clockShowsWeekday: false,
    corner: {name: "panelActivities", type: "ActivitiesButton", x: 0, y: 0, width: 84, height: $h},
    dnd: {off: $glyphs, on: (["notifications-disabled-symbolic"] + $glyphs)},
    leftItems: [{accessibleName: "Activities", label: null, pill: {x: $pad, y: 4, width: 76, height: 24, radius: 12}}],
    rightItems: [{accessibleName: "System", label: null, pill: {x: 1337, y: 4, width: 95, height: 24, radius: 12}}],
    opaque: {error: "io.github.apex_linux.Apex.Desktop has no translucent-top-bar key"},
    glass: []}}'
# shellcheck disable=SC2016 # a jq program
HEX_DEF='def hex: rgba | map([., 16] | "0123456789abcdef"[(.[0] / .[1] | floor):(.[0] / .[1] | floor) + 1]
                                    + "0123456789abcdef"[(.[0] % .[1]):(.[0] % .[1]) + 1]) | "#" + join("");'

# shellcheck disable=SC2016 # jq programs
GAP_CLOSERS='the active dot at 22|.topBar.dots[0].width = 22
inactive dots at full size and .45|.topBar.dots[1] |= (.width = 7 | .height = 7 | .opacity = 0.451)
the hot-corner zone|.topBar.corner = {name: "hot-corner", type: "Actor", x: 0, y: 0, width: 4, height: 4}
the status-pill filter|.topBar.dnd.on = .topBar.dnd.off
no Bluetooth glyph|.topBar.statusGlyphs |= map(select(.name != "bluetooth-active-symbolic"))
the focused-app name|.topBar.leftItems += [{accessibleName: "Desktop", label: {text: "Desktop", weight: 700}}]
the search button|.topBar.rightItems |= [{accessibleName: "Search (Super+Space)", pill: {width: 32, height: 24, radius: 12}}] + .
the solid bar|.topBar.opaque = {background: ($t.apex_bar_solid | hex), boxShadow: {color: ($t.apex_border | hex), inset: false, x: 0, y: 1, blur: 0, spread: 0}}
the glass|.topBar.glass = [{actor: "panel", radius: 96, saturation: 1.6}]
the weekday|.topBar.clockShowsWeekday = true
the clock gap|.topBar.clockTextGap = 8
the clock pill without the pad|.topBar.withDot.pillWidth -= ($t.apex_bar_clock_gap | px) + ($t.apex_bar_clock_dot_size | px)
the raw accent dot|.topBar.withDot.dot.background = .topBar.accent'

assert_run() {
    local assertions=$1 variant=$2 change=${3:-.} tokens
    tokens=$(tokens_for "$variant")
    jq -nc --argjson t "$tokens" "$JQ_DEFS $HEX_DEF $REPORT_OF_A_BAR_DRAWN_FROM_TOKENS | $change" | sed 's/^/APEXG2-SCENES /' >"$T/top-bar.log"
    # shellcheck disable=SC2016 # expanded by the inner bash
    bash -c '. "$1/assert.sh"; "$2" case "$3" "$4" >"$5" 2>&1; summary >>"$5"; echo "$npass $nfail $ngap"' \
        _ "$HERE" "$assertions" "$T/top-bar.log" "$variant" "$T/top-bar.out"
}

test_top_bar() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run top_bar "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes > 10)); then
            ok "top bar ($variant): a bar drawn from the tokens passes all $passes assertions"
        else
            not_ok "top bar ($variant): a bar drawn from the tokens passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run top_bar light "$change")"
        if ((failures == 1)); then
            ok "top bar: $what fails one assertion"
        else
            not_ok "top bar: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.topBar.panel.height += 1|a bar 1 px too high
.topBar.panel.background = "#fafafcff"|an opaque bar
.topBar.panel.font.size = 14.667|upstream's 11 pt text
.topBar.clock.label.font.features = "tnum"|tabular digits
.topBar.left.padding.left = 8|an inset on the left box, which the corner click would miss
.topBar.activities.x = 8|an Activities button that stops short of the screen's left edge
.topBar.status.width -= 8|a status button that stops short of the screen's right edge
.topBar.panel.foreground = "#222226ff"|upstream's colour on the bar itself
.topBar.diamond.inkPixels = 0|no diamond drawn
.topBar.right.spacing = 0|no gap between the right items
.topBar.status.height = 24|a button that does not fill the bar
.topBar.activities.foreground = "#ffffffff"|white text on the light bar
.topBar.clock.pill.radius = 99|a fully round pill
.topBar.status.pill.background = "#00000a14"|a pill filled while closed
.topBar.clock.pill.checked.background = "#00000000"|an open pill without its fill
.topBar.status.pill.padding.right = 6|upstream's hpadding on the status pill
.topBar.activities.pill.padding.left = 10|no room for the diamond
.topBar.clock.label.font.weight = 600|a clock at the bar's weight
.topBar.activities.pill.x = 0|a pill at the screen edge
.topBar.status.pill.width += 8|a status pill that reaches into the right inset
.topBar.clock.pill.x += 2|an off-centre clock
.topBar.panel.transition = 0|a bar that changes at once
.topBar.activities.pill.spacing = 0|workspace dots without their gap
.topBar.withDot.dot.width = 16|upstream's glyph in place of the notification dot
.topBar.status.pill.spacing = 2|upstream's gap between the status glyphs
.topBar.statusGlyphs[0].iconSize = 16.364|upstream's em-sized glyphs
.topBar.diamond.inkPixels = 60|a diamond that lost most of its stroke
.topBar.lockScreen.status.pill.width -= 8|a lock-screen status pill inset from its filled button
.topBar.largeText.clockText.naturalHeight = 30|Large Text that overflows the clock pill
.topBar.largeText.barHeight = 35.2|a bar that grows with Large Text
.topBar.largeText.clockText.size = 13.5|clock text that ignores Large Text
del(.topBar.statusGlyphs[1])|no Wi-Fi glyph
.topBar.statusGlyphs[2].name = "system-shutdown-symbolic"|the power glyph of a machine without a battery
.topBar.statusLabels[0].text = "88%"|another battery percentage
.topBar.statusLabels[0].font.size = 13.5|the percentage at the bar's text size
.topBar.statusLabels = []|no percentage label
CHANGES
    assert_run top_bar light '.monitorScale = 1 | .topBar.diamond.inkPixels = 16' >/dev/null
    expect_eq "top bar: at scale 1 a quarter of the diamond's stroke is 16 capture pixels" 0 "$(grep -c '^FAIL' "$T/top-bar.out")"
    assert_run top_bar light '.monitorScale = 1 | .topBar.diamond.inkPixels = 15' >/dev/null
    expect_eq "top bar: and fewer fail" 1 "$(grep -c '^FAIL' "$T/top-bar.out")"
    assert_run top_bar light 'del(.topBar)' >/dev/null
    expect_eq "top bar: a report without the top bar passes none" 0 "$(grep -c '^PASS' "$T/top-bar.out")"
}

test_today_pins() {
    local pin_count what change passes failures open_gaps
    read -r passes failures open_gaps <<<"$(assert_run top_bar_today light)"
    pin_count=$passes
    expect_eq "today's pins: what S1a draws passes each" "0/0" "$failures/$open_gaps"
    expect_eq "today's pins: one per known gap" "$(grep -c . <<<"$GAP_CLOSERS")" "$pin_count"
    while IFS='|' read -r what change; do
        read -r passes failures open_gaps <<<"$(assert_run top_bar_today light "$change")"
        if ((failures == 1 && passes == pin_count - 1)); then
            ok "today's pins: $what fails its pin"
        else
            not_ok "today's pins: $what fails its pin (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<<"$GAP_CLOSERS"
}

test_known_gaps() {
    local gap_count what change passes failures open_gaps
    gap_count=$(grep -c . <<<"$GAP_CLOSERS")
    read -r passes failures open_gaps <<<"$(assert_run top_bar_gaps light)"
    expect_eq "known gaps: what S1a draws leaves each open, and fails nothing" "0/0/$gap_count" "$passes/$failures/$open_gaps"
    expect_eq "known gaps: the summary lists each with its roadmap step" "$gap_count" \
        "$(grep -cE '^# gap (S[0-9][a-z] |no step yet )' "$T/top-bar.out")"
    # shellcheck disable=SC2016 # expanded by the inner bash
    if bash -c '. "$1/lib.sh"; known_gap S9 fail x >/dev/null; summary >/dev/null' _ "$HERE"; then
        ok "known gaps: gaps alone do not fail the run"
    else
        not_ok "known gaps: gaps alone do not fail the run"
    fi
    while IFS='|' read -r what change; do
        read -r passes failures open_gaps <<<"$(assert_run top_bar_gaps light "$change")"
        if ((failures == 1 && open_gaps == gap_count - 1)) && grep -q '^FAIL .*but it holds now' "$T/top-bar.out"; then
            ok "known gaps: $what, once built, fails until its gap becomes a plain assertion"
        else
            not_ok "known gaps: $what, once built, fails until its gap becomes a plain assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<<"$GAP_CLOSERS"
    read -r passes failures open_gaps <<<"$(assert_run top_bar_gaps light 'del(.topBar)')"
    expect_eq "known gaps: a report without the top bar leaves every gap open" "0/0/$gap_count" "$passes/$failures/$open_gaps"
}

test_incomplete_compare() {
    local one_pair='[{"name": "x", "expected": "e.png", "actual": "a.png", "masks": [], "diff": "d.png"}]'
    local stale='[{"name": "x", "width": 1, "height": 1, "masked": 0, "differing": 0, "masks": [], "box": null, "diff": null}]'
    printf '%s\n' "$one_pair" >"$T/one-pair.json"
    cat >"$T/gjs-writes-nothing" <<'EOF'
#!/bin/sh
printf '[]\n' >"$4"
EOF
    chmod +x "$T/gjs-writes-nothing"
    # shellcheck disable=SC2016 # expanded by the inner bash
    local run_it='. "$1/lib.sh"; compare_and_expect_equal "$2" "$3"; echo "$nfail"'
    expect_eq "captures: a gjs that cannot run fails the comparison" 1 \
        "$(G2_GJS=false bash -c "$run_it" _ "$HERE" "$T/one-pair.json" "$T/results.json" | tail -n 1)"
    printf '%s\n' "$stale" >"$T/results.json"
    expect_eq "captures: an old results file does not stand in for a run that wrote none" 1 \
        "$(G2_GJS=false bash -c "$run_it" _ "$HERE" "$T/one-pair.json" "$T/results.json" | tail -n 1)"
    expect_eq "captures: a run that compared fewer pairs than planned fails" 1 \
        "$(G2_GJS="$T/gjs-writes-nothing" bash -c "$run_it" _ "$HERE" "$T/one-pair.json" "$T/results.json" | tail -n 1)"
    mkdir -p "$T/run-a" "$T/run-b"
    # shellcheck disable=SC2016 # expanded by the inner bash
    G2_GJS=false bash -c '. "$1/assert.sh"; compare_with_fedora "$2"' _ "$HERE" "$T/run-a" >"$T/fedora-compare.out" 2>&1 || true
    if grep -q '^FAIL captures: compare.js compared none of 8 ' "$T/fedora-compare.out"; then
        ok "captures: assert.sh fails the Fedora comparisons when compare.js cannot run"
    else
        not_ok "captures: assert.sh fails the Fedora comparisons when compare.js cannot run"
    fi
    G2_GJS=false "$HERE/stable.sh" "$T/run-a" "$T/run-b" >"$T/stable.out" 2>&1 || true
    if grep -q '^FAIL captures: compare.js compared none of 14 ' "$T/stable.out"; then
        ok "captures: stable.sh fails the run-to-run comparisons when compare.js cannot run"
    else
        not_ok "captures: stable.sh fails the run-to-run comparisons when compare.js cannot run"
    fi
}

skip_or_fail() {
    if [[ $NO_SKIP == 1 ]]; then
        not_ok "$* (APEX_SHOTS_TESTS_NO_SKIP=1)"
    else
        tests=$((tests + 1))
        printf 'ok %d # SKIP %s\n' "$tests" "$*"
    fi
}

assertion_counts() {
    # shellcheck disable=SC2016 # expanded by the inner bash
    bash -c '. "$1/assert.sh"; "${@:3}" >"$2" 2>&1; echo "$npass $nfail"' _ "$HERE" "$T/assertions.out" "$@"
}

test_fixed_clock() {
    local clock passes failures
    # shellcheck disable=SC2016 # expanded by the inner bash
    clock=$(bash -c '. "$1/assert.sh"; echo "$FIXED_CLOCK"' _ "$HERE")
    expect_eq "clock: assert.sh expects the time direct.sh gives libfaketime" "$clock" \
        "$(sed -n "s/^readonly G2_CLOCK='\([0-9-]*\) \([0-9:]*\)'\$/\1T\2Z/p" "$HERE/direct.sh")"
    while IFS='|' read -r failures what clock; do
        printf 'APEXG2 %s\n' "$clock" >"$T/clock.log"
        read -r passes _ <<<"$(assertion_counts fixed_clock case "$T/clock.log")"
        expect_eq "clock: $what fails $failures of 2" "$failures" $((2 - passes))
    done <<'CLOCKS'
0|the fixed time, as G2's 24-hour clock shows it,|{"clock": {"now": "2026-09-28T09:41:00Z", "text": "Sep 28\u200209:41"}}
1|a plain space for the EN SPACE|{"clock": {"now": "2026-09-28T09:41:00Z", "text": "Sep 28 09:41"}}
1|a shell that missed libfaketime|{"clock": {"now": "2026-10-23T14:02:11Z", "text": "Sep 28\u200209:41"}}
2|a shell without FAKETIME|{"clock": null}
CLOCKS
}

# shellcheck disable=SC2016 # a jq program
CYCLES_REPORT='
{actors: {ClutterStage: 1, StWidget: 420, StLabel: 96, StIcon: 61}} as $census
| ({stylesheet: "resource:///org/gnome/shell/theme/gnome-shell-light.css", markers: ["light"], markerColor: "#16161aff",
   sessionColorScheme: "prefer-light", variant: "light", safe: false} + $census) as $on
| ({stylesheet: "resource:///org/gnome/shell/theme/stock/gnome-shell-dark.css", markers: [], markerColor: "#ffffffff",
   sessionColorScheme: "prefer-dark", variant: "dark", safe: true} + $census) as $off
| {cycles: 3, states: ([$on + {layerEnabled: true}]
    + [range(1; 4) as $c | ($off + {cycle: $c, layerEnabled: false}), ($on + {cycle: $c, layerEnabled: true})])}'
readonly APEX_LIGHT_REPORT='{"mode": "user", "stylesheet": "resource:///org/gnome/shell/theme/gnome-shell-light.css", "sheet": {"markers": ["light"], "apexRule": true}, "markerColor": "#16161a", "colorSchemeSetting": "default", "sessionColorScheme": "prefer-light", "variant": "light", "safe": false}'

write_cycles_run() {
    local change=$1 dir=$T/cycles
    rm -rf "$dir" && mkdir -p "$dir"
    {
        printf 'APEXG2 %s\n' "$APEX_LIGHT_REPORT"
        printf 'Apex: layer-enabled is %s\n' 'false: the stock shell' 'true: the Apex shell' 'false: the stock shell' \
            'true: the Apex shell' 'false: the stock shell' 'true: the Apex shell'
        printf 'APEXG2-CYCLES %s\n' "$(jq -nc "$CYCLES_REPORT | $change")"
    } >"$dir/layer-cycles.log"
    echo 'layer-cycles exit=0 secs=31 marker-after-exit=no' >"$dir/results-main.txt"
}

test_layer_cycles() {
    local change what passes failures all
    write_cycles_run .
    read -r all failures <<<"$(assertion_counts layer_cycles "$T/cycles")"
    if ((failures == 0 && all > 10)); then
        ok "layer cycles: three clean off-and-on cycles pass all $all assertions"
    else
        not_ok "layer cycles: three clean cycles pass (passed/failed $all/$failures): $(grep -m3 '^FAIL' "$T/assertions.out" | paste -sd'|' -)"
    fi
    while IFS='|' read -r change what; do
        write_cycles_run "$change"
        read -r passes failures <<<"$(assertion_counts layer_cycles "$T/cycles")"
        expect_eq "layer cycles: $what fails one assertion" "$((all - 1))/1" "$passes/$failures"
    done <<'CHANGES'
.states[3].stylesheet = "resource:///org/gnome/shell/theme/gnome-shell-light.css"|the Apex sheet while the layer is off
.states[3].safe = false|a hook that keeps its provider while the layer is off
.states[4].sessionColorScheme = "prefer-dark"|the stock colour scheme after the layer is back
.states[6].actors.StWidget += 1|an actor left behind by a cycle
.states[5].actors.StIcon -= 1|an actor the stock shell loses
CHANGES
    write_cycles_run '.states[5].layerEnabled = true'
    read -r passes failures <<<"$(assertion_counts layer_cycles "$T/cycles")"
    if ((failures >= 1)); then ok "layer cycles: a switch that did not reach the shell fails"; else not_ok "layer cycles: a switch that did not reach the shell fails"; fi
    write_cycles_run .
    sed -i '0,/true: the Apex shell/{/true: the Apex shell/d}' "$T/cycles/layer-cycles.log"
    read -r passes failures <<<"$(assertion_counts layer_cycles "$T/cycles")"
    expect_eq "layer cycles: a switch the layer did not log fails one assertion" "$((all - 1))/1" "$passes/$failures"
}

fixtures_report() {
    local part
    for part in main kernel fedora; do
        printf '%s\n' "$1" >"$T/fixtures/fixtures-$part.txt"
    done
}

# What the shell's indicators read: network.js through libnm, bluetooth.js through
# gnome-bluetooth, system.js the display device's properties.
write_fixture_reader() {
    cat >"$T/read-fixtures.js" <<'EOF'
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import NM from 'gi://NM';
import GnomeBluetooth from 'gi://GnomeBluetooth?version=3.0';

const nm = NM.Client.new(null);
const primary = nm.get_primary_connection();
const ap = primary?.get_devices()[0]?.get_active_access_point();
const upower = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SYSTEM, Gio.DBusProxyFlags.NONE, null,
    'org.freedesktop.UPower', '/org/freedesktop/UPower/devices/DisplayDevice', 'org.freedesktop.UPower.Device', null);
const bluetooth = new GnomeBluetooth.Client();
const loop = new GLib.MainLoop(null, false);
GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => {
    const devices = bluetooth.get_devices();
    const connected = [];
    for (let i = 0; i < devices.get_n_items(); i++) {
        if (devices.get_item(i).connected)
            connected.push(devices.get_item(i).alias);
    }
    print(JSON.stringify({
        wifi: {id: primary?.get_id() ?? null, strength: ap?.get_strength() ?? null,
            full: nm.connectivity === NM.ConnectivityState.FULL, wireless: nm.wireless_enabled},
        battery: {present: upower.get_cached_property('IsPresent')?.unpack() ?? null,
            percentage: upower.get_cached_property('Percentage')?.unpack() ?? null},
        connectedBluetooth: connected,
    }));
    loop.quit();
    return GLib.SOURCE_REMOVE;
});
loop.run();
EOF
}

start_private_system_bus() {
    cat >"$T/bus.conf" <<EOF
<busconfig>
  <type>system</type>
  <listen>unix:dir=$T</listen>
  <auth>EXTERNAL</auth>
  <policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy>
</busconfig>
EOF
    dbus-daemon --config-file="$T/bus.conf" --fork --print-address=3 --print-pid=4 3>"$T/bus.address" 4>"$T/bus.pid"
}

test_fixtures() {
    local passes failures address missing=()
    mkdir -p "$T/fixtures"
    fixtures_report 'G2-FIXTURES {"battery": {"percentage": 87.0, "present": true, "onBattery": true}, "wifi": {"primary": "Apex-5G", "ssid": "Apex-5G", "strength": 90, "state": 70, "connectivity": 4}, "keyboard": {"alias": "Keychron K3", "connected": true, "icon": "input-keyboard"}}'
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: what fixtures.py reports passes each part's three assertions" "9/0" "$passes/$failures"
    fixtures_report 'G2-FIXTURES {"battery": {"percentage": 0.0, "present": false, "onBattery": false}, "wifi": {"primary": "Apex-5G", "ssid": "Apex-5G", "strength": 30, "state": 70, "connectivity": 4}, "keyboard": {"alias": "Keychron K3", "connected": false, "icon": "phone"}}'
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: no battery, a weak signal and a keyboard left unconnected fail all three" "0/9" "$passes/$failures"
    fixtures_report 'fixtures.py: no owner for org.bluez after 20 s'
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: a fixtures.py that failed fails them" "0/9" "$passes/$failures"

    command -v dbus-daemon >/dev/null 2>&1 || missing+=(dbus-daemon)
    python3 -c 'import dbusmock' >/dev/null 2>&1 || missing+=(python3-dbusmock)
    gjs -c "imports.gi.versions.GnomeBluetooth = '3.0'; imports.gi.NM; imports.gi.GnomeBluetooth" >/dev/null 2>&1 ||
        missing+=('the NM and GnomeBluetooth 3.0 typelibs')
    if ((${#missing[@]})); then
        skip_or_fail "fixtures: fixtures.py on a private bus needs ${missing[*]}"
        return
    fi
    start_private_system_bus
    address=$(head -n 1 "$T/bus.address")
    rm -rf "$T/fixtures" && mkdir -p "$T/fixtures"
    DBUS_SYSTEM_BUS_ADDRESS=$address python3 "$HERE/fixtures.py" "$T/fixtures" >"$T/fixtures/fixtures-main.txt" 2>&1 || true
    cp "$T/fixtures/fixtures-main.txt" "$T/fixtures/fixtures-kernel.txt"
    cp "$T/fixtures/fixtures-main.txt" "$T/fixtures/fixtures-fedora.txt"
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: fixtures.py on a private bus passes the fixture assertions" "9/0" "$passes/$failures"
    write_fixture_reader
    expect_eq "fixtures: libnm, gnome-bluetooth and UPower's display device read them as the shell does" \
        '{"wifi":{"id":"Apex-5G","strength":90,"full":true,"wireless":true},"battery":{"present":true,"percentage":87},"connectedBluetooth":["Keychron K3"]}' \
        "$(DBUS_SYSTEM_BUS_ADDRESS=$address gjs -m "$T/read-fixtures.js" 2>"$T/read-fixtures.err")"
    local -a pids
    mapfile -t pids < <(cat "$T/bus.pid" "$T"/fixtures/fixture-*.pid 2>/dev/null)
    kill "${pids[@]}" 2>/dev/null || true
}

test_png_js
test_compare_js
test_incomplete_compare
test_token_file
test_top_bar
test_today_pins
test_known_gaps
test_fixed_clock
test_layer_cycles
test_fixtures

printf '1..%d\n' "$tests"
((failed == 0))
