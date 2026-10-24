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
libpng, for the fixtures dbus-daemon, python3-dbusmock and the NM and GnomeBluetooth
typelibs, and for frame.c gcc and glib2-devel. Output is TAP.
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
trap 'kill "$(head -n 1 "$T/bus.pid" 2>/dev/null)" 2>/dev/null || true; rm -rf "$T"' EXIT
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
| ["network-wireless-signal-excellent-symbolic", "battery-level-80-symbolic"] as $glyphs
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
    dots: [{active: true, x: 38, y: 12.5, width: ($t.apex_bar_dot_active_width | px), height: $dot, opacity: 1, radius: $dot_radius},
           {active: false, x: 64, y: 12.5, width: $dot, height: $dot, opacity: 0.447, radius: $dot_radius}],
    withDot: {dot: {visible: true, width: $clock_dot, height: $clock_dot, radius: ($t.apex_radius_clock_dot | px),
            background: $fg},
        labelWidth: 120, pillWidth: (120 + 2 * $pp + 2 * ($clock_gap + $clock_dot))},
    clockTextGap: 7.041,
    clockShowsWeekday: true,
    corner: {name: "hot-corner", type: "HotCorner", x: 0, y: 0, width: 4, height: 4},
    dnd: {off: $glyphs, on: $glyphs},
    leftItems: [{accessibleName: "Activities", label: null, pill: {x: $pad, y: 4, width: 76, height: 24, radius: 12}},
        {accessibleName: "Desktop", label: {text: "Desktop", weight: ($t.apex_font_bar_emphasis_weight | tonumber)}, pill: null}],
    rightItems: [{accessibleName: "Search (Super+Space)", label: null,
            pill: {x: 1303, y: 4, width: ($t.apex_bar_search_width | px), height: 24, radius: 12}},
        {accessibleName: "System", label: null, pill: {x: 1337, y: 4, width: 95, height: 24, radius: 12}}],
    opaque: {background: ($t.apex_bar_solid | hex), boxShadow: {color: ($t.apex_border | hex), inset: false, x: 0, y: 1, blur: 0, spread: 0}},
    glass: [{actor: "panel", radius: (2 * ($t.apex_bar_blur | px) * 2), saturation: 1.6}]},
  dock: {visible: true, bottomGap: ($t.apex_dock_bottom_gap | px), centreOffset: 0, radius: ($t.apex_radius_dock | px),
    background: {x: 470, y: 820, width: 500, height: 70},
    items: [{kind: "app", name: "Files", iconSize: ($t.apex_dock_icon_size | px)},
            {kind: "app", name: "Web", iconSize: ($t.apex_dock_icon_size | px)},
            {kind: "separator"},
            {kind: "show-apps", iconSize: ($t.apex_dock_icon_size | px), iconName: "view-app-grid"},
            {kind: "trash", iconSize: ($t.apex_dock_icon_size | px)}],
    overviewDashVisible: false},
  scenes: {overview: {dockVisible: true, dockClearance: 12}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_SURFACES_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b | {top: $b, right: $b, bottom: $b, left: $b} as $border | ($t.apex_panel_border | hex) as $ring
| {color: ($t.apex_shadow | hex), inset: false, x: 0, y: ($t.apex_shadow_y | px), blur: ($t.apex_shadow_blur | px), spread: 0} as $shadow
| ($t.apex_menu_padding | px) as $mp | ($t.apex_menu_row_height | px) as $row | ($t.apex_menu_row_gap | px) as $gap
| ($t.apex_menu_row_padding | px) as $rp | ($t.apex_menu_separator_margin | px) as $sm
| {height: $row, radius: ($t.apex_radius_menu_row | px), padding: {left: $rp, right: $rp}, spacing: ($t.apex_menu_row_spacing | px),
   background: "#00000000", hover: {background: ($t.apex_button_hover | hex)}} as $r
| ($t.apex_osd_padding | px) as $op | ($t.apex_banner_padding | px) as $bp | ($t.apex_banner_icon_size | px) as $icon
| ($t.apex_banner_close_size | px) as $close
| {topBar: {accent: "#3584e4ff"}, surfaces: {
    popupMenu: {
        content: {x: 290, y: 307, width: 220, border: $border, borderColor: $ring, padding: {top: ($mp - $b), right: ($mp - $b), bottom: ($mp - $b), left: ($mp - $b)},
            radius: ($t.apex_radius_menu | px), background: ($t.apex_panel_solid | hex), foreground: ($t.apex_fg | hex),
            boxShadow: $shadow, font: {size: ($t.apex_font_size | px)}},
        rows: [$r + {y: 313}, $r + {y: (313 + $row + $gap)},
            $r + {y: (313 + 2 * $row + 2 * $gap + 2 * $sm + 1 + $gap)}],
        separator: {x: (290 + $mp + ($t.apex_menu_separator_inset | px)), y: (313 + 2 * $row + 2 * $gap + $sm), height: 1,
            background: ($t.apex_border | hex)},
        icon: ($t.apex_menu_icon_size | px)},
    osd: {
        box: {height: ($t.apex_osd_height | px), radius: ($t.apex_radius_osd | px), background: ($t.apex_panel | hex), foreground: ($t.apex_fg | hex),
            border: $border, borderColor: $ring, boxShadow: $shadow, padding: {left: ($op - $b), right: ($op - $b)}, spacing: ($t.apex_osd_gap | px),
            font: {size: ($t.apex_font_size | px), weight: ($t.apex_font_label_weight | tonumber)}},
        bottomGap: ($t.apex_osd_bottom | px), icon: ($t.apex_osd_icon_size | px),
        level: {width: ($t.apex_osd_level_width | px), barHeight: ($t.apex_osd_level_height | px),
            background: ($t.apex_button_hover | hex), active: "#3584e4ff"}},
    banner: {
        box: {x: 490, width: ($t.apex_banner_width | px), radius: ($t.apex_radius_banner | px), background: ($t.apex_panel | hex),
            border: $border, borderColor: $ring, boxShadow: $shadow, padding: {top: ($bp - $b), right: ($bp - $b), bottom: ($bp - $b), left: ($bp - $b)}},
        topGap: ($t.apex_banner_top | px),
        header: {font: {size: ($t.apex_font_banner_header_size | px)}, foreground: ($t.apex_fg_dim | hex)},
        title: {x: (490 + $bp + $icon + ($t.apex_banner_gap | px)), font: {size: ($t.apex_font_size | px), weight: ($t.apex_font_heading_weight | tonumber)}},
        body: {font: {size: ($t.apex_font_banner_body_size | px)}, foreground: ($t.apex_fg_dim | hex)},
        icon: $icon,
        close: {width: $close, height: $close, radius: 999, background: ($t.apex_button | hex)},
        actions: {spacing: ($t.apex_banner_button_gap | px), padding: {left: ($icon + ($t.apex_banner_gap | px))}},
        button: {minHeight: ($t.apex_banner_button_height | px), radius: ($t.apex_radius_banner_button | px), background: ($t.apex_button | hex),
            font: {size: ($t.apex_font_banner_button_size | px), weight: ($t.apex_font_label_weight | tonumber)}}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_QUICK_SETTINGS_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b | ($t.apex_quick_settings_padding | px) as $qp | ($t.apex_quick_settings_grid_gap | px) as $gap
| ($t.apex_quick_toggle_height | px) as $th | ($t.apex_quick_settings_button_size | px) as $bs | ($t.apex_quick_settings_icon_size | px) as $icon
| ((($t.apex_quick_settings_width | px) - 2 * $qp - $gap) / 2) as $tw | ($t.apex_quick_toggle_padding | px) as $tp
| ($t.apex_quick_toggle_menu_button_shade | rtrimstr("%") | tonumber / 100) as $shade
| {size: ($t.apex_font_quick_toggle_title_size | px), weight: ($t.apex_font_heading_weight | tonumber)} as $title
| {topBar: {accent: "#3584e4ff"}, surfaces: {quickSettings: {
    box: {width: ($t.apex_quick_settings_width | px), radius: ($t.apex_radius_quick_settings | px), background: ($t.apex_panel | hex),
        padding: {top: ($qp - $b), right: ($qp - $b), bottom: ($qp - $b), left: ($qp - $b)}, border: {top: $b, right: $b, bottom: $b, left: $b},
        borderColor: ($t.apex_panel_border | hex),
        boxShadow: {color: ($t.apex_shadow | hex), inset: false, x: 0, y: ($t.apex_shadow_y | px), blur: ($t.apex_shadow_blur | px), spread: 0}},
    grid: {rows: $gap, columns: $gap},
    system: {y: 44, height: $bs, spacing: ($t.apex_quick_settings_button_gap | px),
        screenshot: {width: $bs, height: $bs, radius: 999, background: ($t.apex_button | hex), icon: $icon},
        battery: {height: $bs, radius: 999, background: ($t.apex_button | hex),
            box: {padding: {left: ($t.apex_quick_settings_battery_padding | px), right: ($t.apex_quick_settings_battery_padding | px)}, spacing: ($t.apex_quick_settings_battery_gap | px)},
            title: {font: {size: ($t.apex_font_quick_settings_battery_size | px), weight: ($t.apex_font_label_weight | tonumber)}}}},
    wifi: {y: (44 + $bs + ($t.apex_quick_settings_section_gap | px)), width: $tw, height: $th,
        toggle: {background: "#3584e4ff", foreground: "#ffffffff", icon: $icon, title: {font: $title},
            subtitle: {foreground: ("rgba(255, 255, 255, \($t.apex_quick_toggle_subtitle_opacity))" | hex), font: {size: ($t.apex_font_quick_toggle_subtitle_size | px)}},
            box: {padding: {left: $tp, right: ($t.apex_quick_toggle_menu_padding | px)}, spacing: ($t.apex_quick_toggle_gap | px)}},
        separator: {width: 0},
        menuButton: {width: ($t.apex_quick_toggle_menu_button_width | px), background: ([53, 132, 228] | map(. * (1 - $shade) | round) | "rgb(\(.[0]), \(.[1]), \(.[2]))" | hex)}},
    unchecked: {width: $tw, height: $th, radius: 999, background: ($t.apex_button | hex), foreground: ($t.apex_fg | hex),
        hover: {background: ($t.apex_button_hover | hex)}, icon: $icon, box: {padding: {left: $tp, right: $tp}, spacing: ($t.apex_quick_toggle_gap | px)}},
    slider: {spacing: ($t.apex_quick_slider_gap | px), trackHeight: ($t.apex_quick_slider_track_height | px), track: ($t.apex_button_hover | hex),
        fill: "#3584e4ff", handleRadius: (($t.apex_quick_slider_handle_size | px) / 2), handle: ($t.apex_slider_handle | hex)},
    wifiMenu: {
        box: {y: (44 + $bs + ($t.apex_quick_settings_section_gap | px) + $th + $gap), background: ($t.apex_card | hex), borderColor: ($t.apex_card_border | hex),
            border: {top: $b, left: $b}, radius: ($t.apex_radius_quick_menu | px), padding: {left: (($t.apex_quick_menu_padding | px) - $b)}, boxShadow: null},
        headerIcon: {width: ($t.apex_quick_menu_header_icon_size | px), height: ($t.apex_quick_menu_header_icon_size | px), background: "#3584e4ff", iconSize: $icon},
        title: {font: {size: ($t.apex_font_quick_menu_title_size | px), weight: ($t.apex_font_heading_weight | tonumber)}},
        rows: [{height: ($t.apex_quick_menu_row_height | px), padding: {left: ($t.apex_menu_row_padding | px)}, radius: ($t.apex_radius_menu_row | px)}]}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_A_SWITCHER_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b | ($t.apex_switcher_padding | px) as $p
| {radius: ($t.apex_radius_switcher_item | px), padding: {top: ($t.apex_switcher_item_vpadding | px), left: ($t.apex_switcher_item_hpadding | px)},
   background: "#00000000", foreground: ($t.apex_fg | hex), pseudoClass: null} as $item
| {surfaces: {switcher: {
    list: {background: ($t.apex_panel | hex), radius: ($t.apex_radius_switcher | px), border: {top: $b, right: $b, bottom: $b, left: $b},
        padding: {top: ($p - $b), right: ($p - $b), bottom: ($p - $b), left: ($p - $b)}, borderColor: ($t.apex_panel_border | hex),
        boxShadow: {color: ($t.apex_shadow | hex), y: ($t.apex_shadow_y | px), blur: ($t.apex_shadow_blur | px)}},
    spacing: ($t.apex_switcher_gap | px),
    items: [$item + {pseudoClass: "first-child"}, $item + {pseudoClass: "selected", background: ($t.apex_button_hover | hex)}, $item],
    app: {spacing: ($t.apex_switcher_item_spacing | px), label: {size: ($t.apex_font_size | px), weight: ($t.apex_font_label_weight | tonumber)}}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_A_DIALOG_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b | ($t.apex_dialog_padding | px) as $p | ($t.apex_dialog_button_height | px) as $bh
| {height: $bh, radius: 999, font: {size: ($t.apex_font_dialog_button_size | px), weight: ($t.apex_font_label_weight | tonumber)}} as $button
| {topBar: {accent: "#3584e4ff"}, surfaces: {dialog: {
    box: {background: ($t.apex_panel_solid | hex), radius: ($t.apex_radius_dialog | px), width: ($t.apex_dialog_width | px),
        border: {top: $b, right: $b, bottom: $b, left: $b}, borderColor: ($t.apex_panel_border | hex),
        boxShadow: {color: ($t.apex_shadow | hex), y: ($t.apex_shadow_y | px), blur: ($t.apex_shadow_blur | px)},
        padding: {top: ($p - $b), right: ($p - $b), bottom: (($t.apex_dialog_padding_bottom | px) - $b), left: ($p - $b)}, spacing: ($t.apex_dialog_gap | px)},
    endSessionWidth: (($t.apex_end_session_dialog_width | px) - 2 * $p),
    contentSpacing: ($t.apex_dialog_gap | px), textSpacing: ($t.apex_dialog_text_gap | px),
    title: {font: {size: ($t.apex_font_dialog_title_size | px), weight: ($t.apex_font_heading_weight | tonumber)}},
    description: {font: {size: ($t.apex_font_size | px)}, foreground: ($t.apex_fg_dim | hex)},
    entry: {height: ($t.apex_entry_height | px), radius: 999, background: ($t.apex_button | hex), boxShadow: null,
        padding: {left: ($t.apex_entry_padding | px), right: ($t.apex_entry_padding | px)},
        font: {size: ($t.apex_font_entry_size | px), weight: ($t.apex_font_entry_weight | tonumber)},
        focus: {boxShadow: {inset: true, spread: ($t.apex_entry_focus_ring | px), color: "#3584e4ff"}}},
    buttons: [$button + {default: false, background: ($t.apex_button | hex), foreground: ($t.apex_fg | hex), hover: {background: ($t.apex_button_hover | hex)}},
        $button + {default: true, background: "#3584e4ff", foreground: "#ffffffff"}]}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_A_DATE_MENU_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b | {top: $b, right: $b, bottom: $b, left: $b} as $border
| def inset($top; $right; $bottom; $left): {top: ($top - $b), right: ($right - $b), bottom: ($bottom - $b), left: ($left - $b)};
($t.apex_quick_settings_padding | px) as $qp | ($t.apex_calendar_padding | px) as $cp
| ($t.apex_message_padding | px) as $mp | ($t.apex_events_padding | px) as $ep
| {size: ($t.apex_font_size | px), weight: ($t.apex_font_heading_weight | tonumber)} as $heading
| {topBar: {accent: "#3584e4ff"}, surfaces: {dateMenu: {
    box: {background: ($t.apex_panel | hex), radius: ($t.apex_radius_quick_settings | px), border: $border, padding: inset($qp; $qp; $qp; $qp)},
    area: {spacing: ($t.apex_date_menu_gap | px)},
    list: {width: ($t.apex_date_menu_list_width | px), border: {right: 0}},
    column: {width: ($t.apex_date_menu_column_width | px), spacing: ($t.apex_date_menu_column_gap | px)},
    message: {background: ($t.apex_message_card | hex), borderColor: ($t.apex_glass_card_border | hex), border: $border, boxShadow: null,
        radius: ($t.apex_radius_message | px), marginBottom: ($t.apex_message_gap | px),
        padding: inset($mp; ($t.apex_message_padding_end | px); $mp; ($t.apex_message_padding_start | px)),
        header: {font: {size: ($t.apex_font_banner_header_size | px)}, foreground: ($t.apex_fg_dim | hex)},
        title: {font: $heading}, body: {font: {size: ($t.apex_font_message_body_size | px)}, foreground: ($t.apex_fg_dim | hex)},
        icon: ($t.apex_message_icon_size | px),
        close: {width: ($t.apex_banner_close_size | px), height: ($t.apex_banner_close_size | px), background: ($t.apex_button | hex)}},
    controls: {height: ($t.apex_date_menu_footer_height | px)},
    clear: {height: ($t.apex_clear_button_height | px), radius: 16, background: ($t.apex_button | hex), padding: {left: ($t.apex_clear_button_padding | px)}},
    dayLabel: {font: {size: ($t.apex_font_date_menu_weekday_size | px), weight: ($t.apex_font_heading_weight | tonumber)}, foreground: ($t.apex_fg_dim | hex)},
    dateLabel: {font: {size: ($t.apex_font_date_menu_date_size | px), weight: ($t.apex_font_date_menu_date_weight | tonumber)}},
    calendar: {background: ($t.apex_glass_card | hex), borderColor: ($t.apex_glass_card_border | hex), radius: ($t.apex_radius_calendar | px),
        border: $border, padding: inset($cp; $cp; $cp; $cp)},
    monthLabel: {background: "#00000000", font: {size: ($t.apex_font_calendar_month_size | px), weight: ($t.apex_font_heading_weight | tonumber)}},
    pager: {width: ($t.apex_calendar_pager_size | px)},
    heading: {height: ($t.apex_calendar_heading_height | px), background: "#00000000", foreground: ($t.apex_fg_dim | hex),
        font: {size: ($t.apex_font_calendar_heading_size | px), weight: ($t.apex_font_heading_weight | tonumber)}},
    day: {width: ((($t.apex_date_menu_column_width | px) - 2 * $cp - 7 * ($t.apex_calendar_day_gap | px)) / 7 | floor),
        height: ($t.apex_calendar_day_height | px), radius: 18, background: "#00000000", foreground: ($t.apex_fg | hex),
        font: {size: ($t.apex_font_calendar_day_size | px)}},
    weekend: {foreground: ($t.apex_fg | hex)},
    otherMonth: {foreground: ($t.apex_fg_faint | hex)},
    today: {background: "#3584e4ff", foreground: "#ffffffff", font: {weight: ($t.apex_font_heading_weight | tonumber)}},
    events: {background: ($t.apex_glass_card | hex), radius: ($t.apex_radius_calendar | px), border: $border,
        padding: inset(($t.apex_events_padding_top | px); $ep; ($t.apex_events_padding_bottom | px); $ep)},
    eventsTitle: {font: {size: ($t.apex_font_events_title_size | px), weight: ($t.apex_font_heading_weight | tonumber)}, foreground: ($t.apex_fg_dim | hex)}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_AN_OVERVIEW_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b | {top: $b, right: $b, bottom: $b, left: $b} as $border
| {topBar: {accent: "#3584e4ff", panel: {height: 32}}, surfaces: {overview: {
    group: {background: ($t.apex_scrim | hex), boxShadow: null},
    search: {y: (32 + ($t.apex_search_top | px)), width: ($t.apex_search_width | px), height: ($t.apex_search_height | px), radius: 20,
        background: ($t.apex_pill | hex), borderColor: ($t.apex_pill_border | hex), border: $border,
        padding: {left: (($t.apex_search_padding | px) - $b)}, font: {size: ($t.apex_font_search_size | px)}, foreground: ($t.apex_fg | hex),
        icon: ($t.apex_quick_settings_icon_size | px),
        focus: {boxShadow: {inset: true, spread: ($t.apex_entry_focus_ring | px), color: "#3584e4ff"}}},
    thumbnailsSpacing: ($t.apex_thumbnail_gap | px),
    thumbnail: {radius: ($t.apex_radius_thumbnail | px), borderColor: ($t.apex_pill_border | hex), border: $border},
    indicator: {radius: ($t.apex_radius_thumbnail | px), border: {top: ($t.apex_thumbnail_indicator | px)}, borderColor: "#3584e4ff"},
    caption: {minHeight: (($t.apex_caption_height | px) - 2 * $b), border: $border, radius: 14, background: ($t.apex_pill | hex),
        borderColor: ($t.apex_pill_border | hex), padding: {left: (($t.apex_caption_padding | px) - $b)}, foreground: ($t.apex_fg | hex),
        font: {size: ($t.apex_font_caption_size | px), weight: ($t.apex_font_heading_weight | tonumber)}},
    section: {background: ($t.apex_glass_card | hex), borderColor: ($t.apex_glass_card_border | hex),
        radius: ($t.apex_radius_message | px), foreground: ($t.apex_fg | hex)}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_A_LAUNCHER_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b | {top: $b, right: $b, bottom: $b, left: $b} as $border
| ($t.apex_folder_dialog_padding | px) as $dp
| {topBar: {accent: "#3584e4ff"}, surfaces: {appGrid: {
    app: {background: "#00000000", radius: ($t.apex_radius_app_tile | px), padding: {top: ($t.apex_app_tile_padding | px)},
        spacing: ($t.apex_app_tile_gap | px), foreground: ($t.apex_fg | hex),
        labelFont: {size: ($t.apex_font_app_label_size | px), weight: ($t.apex_font_label_weight | tonumber)},
        hover: {background: ($t.apex_button | hex)},
        focus: {background: ($t.apex_button | hex), boxShadow: {inset: true, spread: ($t.apex_entry_focus_ring | px), color: "#3584e4ff"}}},
    folder: {background: ($t.apex_folder | hex), borderColor: ($t.apex_pill_border | hex), border: $border},
    dialog: {width: ($t.apex_folder_dialog_width | px), background: ($t.apex_folder_panel | hex), borderColor: ($t.apex_panel_border | hex),
        radius: ($t.apex_radius_folder_dialog | px), border: $border,
        padding: {left: ($dp - $b), bottom: (($t.apex_folder_dialog_padding_bottom | px) - $b)},
        boxShadow: {color: ($t.apex_shadow | hex), y: ($t.apex_shadow_y | px), blur: ($t.apex_shadow_blur | px)},
        title: {font: {size: ($t.apex_font_folder_title_size | px), weight: ($t.apex_font_heading_weight | tonumber)}, foreground: ($t.apex_fg | hex)},
        button: {width: ($t.apex_folder_close_size | px), height: ($t.apex_folder_close_size | px), background: ($t.apex_button | hex)}},
    runningDot: {width: ($t.apex_running_dot_size | px), height: ($t.apex_running_dot_size | px), radius: (($t.apex_running_dot_size | px) / 2),
        background: (($t.apex_fg | rgba) as $c | "rgba(\($c[0]), \($c[1]), \($c[2]), \($t.apex_running_dot_opacity))" | hex)},
    pageIndicator: {background: ($t.apex_fg | hex)},
    pageHint: {gradient: 0}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_AN_OVERVIEW_LAYER_FROM_TOKENS='
{topBar: {panel: {width: 1440}}, scenes: {overview: {workArea: {y: 32, height: 868}}}, surfaces: {
    overviewLayer: {titleVisible: true, thumbnailsThreshold: 1, thumbnails: {maxScale: 0.081, first: {width: 117, height: 70}},
        workspace: {x: 250, y: 205, width: 939, height: 566, background: false,
            empty: {x: 644, y: 477, width: 150, height: 22, visible: true, text: "No open windows", foreground: ($t.apex_fg_dim | hex),
                font: {size: ($t.apex_font_workspace_empty_size | px), weight: ($t.apex_font_heading_weight | tonumber)}}}},
    appGrid: {grid: {columns: 7, rows: 4, iconSize: 88}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_SHADOW_LAYERS_FROM_TOKENS='
{shown: true, sameBox: true, radius: 0, boxShadow: {color: ($t.apex_shadow_2 | hex), inset: false, x: 0,
    y: ($t.apex_shadow_2_y | px), blur: ($t.apex_shadow_2_blur | px), spread: 0}} as $layer
| {surfaces: {idleRepaints: {withShadows: 3, withoutShadows: 3}, shadowLayers: {
    quickSettings: [$layer | .radius = ($t.apex_radius_quick_settings | px)], dateMenu: [$layer],
    dialog: [$layer | .besideBox = true]}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_DERIVED_SURFACES_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b
| {border: {top: $b}, borderColor: ($t.apex_panel_border | hex),
   boxShadow: {color: ($t.apex_shadow | hex), y: ($t.apex_shadow_y | px), blur: ($t.apex_shadow_blur | px)}} as $ring
| ($ring + {background: ($t.apex_panel | hex), radius: ($t.apex_radius_osd | px)}) as $osd
| {topBar: {accent: "#3584e4ff"}, surfaces: {derived: {
    workspaceSwitcher: $osd, resizePopup: $osd,
    wsIndicator: {background: ($t.apex_fg_faint | hex), active: {background: ($t.apex_fg | hex)}},
    candidatePopup: ($ring + {background: ($t.apex_panel_solid | hex), radius: ($t.apex_radius_menu | px)}),
    candidateBox: {radius: ($t.apex_radius_menu_row | px), hover: {background: ($t.apex_button_hover | hex)}},
    runEntry: {minHeight: ($t.apex_entry_height | px), background: ($t.apex_button | hex), boxShadow: null,
        focus: {boxShadow: {inset: true, spread: ($t.apex_entry_focus_ring | px), color: "#3584e4ff"}}},
    audioDevice: {radius: ($t.apex_radius_switcher_item | px), background: "#00000000", foreground: ($t.apex_fg | hex),
        hover: {background: ($t.apex_button_hover | hex)}},
    monitorLabel: {radius: ($t.apex_radius_osd | px)}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_A_SPOTLIGHT_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b | {top: $b, right: $b, bottom: $b, left: $b} as $border
| {border: $border, borderColor: ($t.apex_panel_border | hex),
   boxShadow: {inset: false, x: 0, y: ($t.apex_shadow_y | px), blur: ($t.apex_shadow_blur | px), color: ($t.apex_shadow | hex)}} as $surface
| ($t.apex_spotlight_row_padding | px) as $rp | ($t.apex_spotlight_icon_size | px) as $icon
| {height: ($t.apex_spotlight_row_height | px), radius: ($t.apex_radius_spotlight_row | px), padding: {left: $rp, right: $rp},
   spacing: ($t.apex_spotlight_row_gap | px), background: "#00000000", icon: {width: $icon, height: $icon},
   text: {spacing: ($t.apex_spotlight_text_gap | px)},
   title: {font: {size: ($t.apex_font_spotlight_title_size | px), weight: ($t.apex_font_label_weight | tonumber)}, foreground: ($t.apex_fg | hex)},
   subtitle: {font: {size: ($t.apex_font_spotlight_subtitle_size | px)}, foreground: ($t.apex_fg_dim | hex)}} as $row
| {height: ($t.apex_spotlight_header_height | px),
   padding: {bottom: ($t.apex_spotlight_header_padding_bottom | px), left: ($t.apex_spotlight_header_padding | px)},
   font: {size: ($t.apex_font_spotlight_header_size | px), weight: ($t.apex_font_heading_weight | tonumber)}, foreground: ($t.apex_fg_dim | hex),
   tracking: (($t.apex_spotlight_header_tracking | rtrimstr("em") | num) * ($t.apex_font_spotlight_header_size | px))} as $header
| ($t.apex_spotlight_results_padding | px) as $pad
| {topBar: {accent: "#3584e4ff"}, surfaces: {spotlight: {
    fieldOnly: true,
    panel: ({width: ($t.apex_spotlight_width | px), top: ($t.apex_spotlight_top | px), radius: ($t.apex_radius_spotlight | px),
        background: ($t.apex_panel | hex), foreground: ($t.apex_fg | hex)} + $surface),
    field: {height: ($t.apex_spotlight_field_height | px), padding: {left: ($t.apex_spotlight_field_padding | px), right: ($t.apex_spotlight_field_padding | px)},
        spacing: ($t.apex_spotlight_field_gap | px)},
    glyph: {size: ($t.apex_spotlight_glyph_size | px), foreground: ($t.apex_fg_dim | hex)},
    entry: {font: {size: ($t.apex_font_spotlight_field_size | px), weight: ($t.apex_font_spotlight_field_weight | tonumber)},
        foreground: ($t.apex_fg | hex), background: "#00000000", border: {top: 0}, hint: ($t.apex_fg_hint | hex)},
    results: {border: {top: $b}, borderColor: ($t.apex_border | hex),
        padding: {top: ($t.apex_spotlight_results_padding_top | px), right: $pad, bottom: $pad, left: $pad}},
    sections: ["APPLICATIONS", "SETTINGS", "FILES"],
    headers: [$header, $header, $header],
    rows: ([$row + {background: "#3584e429", action: {verb: {text: "Open"}, font: {size: ($t.apex_font_spotlight_action_size | px), weight: ($t.apex_font_label_weight | tonumber)},
            foreground: ($t.apex_fg_dim | hex), spacing: ($t.apex_spotlight_action_gap | px),
            chip: {height: ($t.apex_spotlight_chip_height | px), radius: ($t.apex_radius_spotlight_chip | px), background: ($t.apex_button | hex),
                label: {text: "Enter", font: {size: ($t.apex_font_spotlight_chip_size | px), weight: ($t.apex_font_heading_weight | tonumber)}}}}}]
        + [range(8) | $row]),
    selected: ([true] + [range(8) | false]),
    calculator: {sections: ["CALCULATOR", "APPLICATIONS"], row: {title: {text: "1920",
        font: {size: ($t.apex_font_spotlight_result_size | px), weight: ($t.apex_font_heading_weight | tonumber), features: "\"tnum\""}},
        subtitle: {text: "2880 / 1.5"}, action: {verb: {text: "Copy"}}}},
    empty: {label: {text: "No results for “zzz”"}, height: ($t.apex_spotlight_empty_height | px), border: {top: $b},
        borderColor: ($t.apex_border | hex), foreground: ($t.apex_fg_dim | hex)},
    closedOnCopy: true,
    toast: {box: ({height: ($t.apex_toast_height | px), radius: ($t.apex_radius_toast | px), background: ($t.apex_panel | hex),
            padding: {left: (($t.apex_toast_padding_start | px) - $b), right: (($t.apex_toast_padding_end | px) - $b)},
            spacing: ($t.apex_toast_gap | px), font: {size: ($t.apex_font_size | px), weight: ($t.apex_font_label_weight | tonumber)}} + $surface),
        bottomGap: ($t.apex_toast_bottom | px),
        check: {width: ($t.apex_toast_check_size | px), height: ($t.apex_toast_check_size | px), radius: 11, background: "#3584e4ff",
            icon: ($t.apex_toast_check_icon_size | px)},
        label: {text: "Copied 1920"}}}}}'
# shellcheck disable=SC2016 # a jq program
# shellcheck disable=SC2016 # a jq program
HEX_DEF='def hex: rgba | map([., 16] | "0123456789abcdef"[(.[0] / .[1] | floor):(.[0] / .[1] | floor) + 1]
                                    + "0123456789abcdef"[(.[0] % .[1]):(.[0] % .[1]) + 1]) | "#" + join("");'

# shellcheck disable=SC2016 # jq programs
GAP_CLOSERS='the clock gap|.topBar.clockTextGap = 8
the clock pill without the pad|.topBar.withDot.pillWidth -= ($t.apex_bar_clock_gap | px) + ($t.apex_bar_clock_dot_size | px)
the raw accent dot|.topBar.withDot.dot.background = .topBar.accent'

assert_run() {
    local assertions=$1 variant=$2 change=${3:-.} tokens report=$REPORT_OF_A_BAR_DRAWN_FROM_TOKENS
    [[ $assertions == shell_surfaces ]] && report=$REPORT_OF_SURFACES_DRAWN_FROM_TOKENS
    [[ $assertions == quick_settings ]] && report=$REPORT_OF_QUICK_SETTINGS_DRAWN_FROM_TOKENS
    [[ $assertions == window_switcher ]] && report=$REPORT_OF_A_SWITCHER_DRAWN_FROM_TOKENS
    [[ $assertions == modal_dialog ]] && report=$REPORT_OF_A_DIALOG_DRAWN_FROM_TOKENS
    [[ $assertions == date_menu ]] && report=$REPORT_OF_A_DATE_MENU_DRAWN_FROM_TOKENS
    [[ $assertions == overview_style ]] && report=$REPORT_OF_AN_OVERVIEW_DRAWN_FROM_TOKENS
    [[ $assertions == app_grid ]] && report=$REPORT_OF_A_LAUNCHER_DRAWN_FROM_TOKENS
    [[ $assertions == derived_surfaces ]] && report=$REPORT_OF_DERIVED_SURFACES_DRAWN_FROM_TOKENS
    [[ $assertions == overview_layer ]] && report=$REPORT_OF_AN_OVERVIEW_LAYER_FROM_TOKENS
    [[ $assertions == spotlight_style ]] && report=$REPORT_OF_A_SPOTLIGHT_DRAWN_FROM_TOKENS
    [[ $assertions == shadow_layers ]] && report=$REPORT_OF_SHADOW_LAYERS_FROM_TOKENS
    tokens=$(tokens_for "$variant")
    jq -nc --argjson t "$tokens" "$JQ_DEFS $HEX_DEF $report | $change" | sed 's/^/APEXG2-SCENES /' >"$T/top-bar.log"
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
.topBar.clockShowsWeekday = false|a clock without the weekday
.topBar.dots[0].width = 25|stock's widened active dot
.topBar.dots[1] += {width: 5.25, height: 5.25, opacity: 0.498}|stock's shrunk, half-faded inactive dot
.topBar.dots[1].opacity = 1|an inactive dot as strong as the active one
.topBar.corner = {name: "panelActivities", type: "ActivitiesButton", x: 0, y: 0, width: 84, height: 32}|no hot-corner zone at the top-left pixel
.topBar.corner.width = 1|a 1 px hot corner
.topBar.opaque.background = .topBar.panel.background|translucent-top-bar off that keeps the translucent fill
.topBar.opaque.boxShadow = null|a solid bar without its line
.topBar.opaque.boxShadow.y = 2|a 2 px line under the solid bar
.topBar.leftItems = .topBar.leftItems[:1]|no focused-app name
.topBar.leftItems[1].label.weight = 600|a focused-app name at the bar's weight
.topBar.leftItems[1].label.text = "Activities"|another name while nothing has focus
.topBar.rightItems = .topBar.rightItems[1:]|no search button
.topBar.rightItems = .topBar.rightItems[1:] + .topBar.rightItems[:1]|a search button after the status pill
.topBar.rightItems[0].pill.width = 36|a search pill padded like the others
.topBar.rightItems[0].accessibleName = "Search"|a search button that does not name its key
.topBar.dnd.on = ["notifications-disabled-symbolic"] + .topBar.dnd.off|a Do Not Disturb glyph in the status pill
.topBar.statusGlyphs += [{name: "bluetooth-active-symbolic", width: 16, height: 16, iconSize: 16}]|the connected keyboard's Bluetooth glyph
CHANGES
    assert_run top_bar light '.monitorScale = 1 | .topBar.glass[0].radius /= 2 | .topBar.diamond.inkPixels = 16' >/dev/null
    expect_eq "top bar: at scale 1 a quarter of the diamond's stroke is 16 capture pixels" 0 "$(grep -c '^FAIL' "$T/top-bar.out")"
    assert_run top_bar light '.monitorScale = 1 | .topBar.glass[0].radius /= 2 | .topBar.diamond.inkPixels = 15' >/dev/null
    expect_eq "top bar: and fewer fail" 1 "$(grep -c '^FAIL' "$T/top-bar.out")"
    assert_run top_bar light 'del(.topBar)' >/dev/null
    expect_eq "top bar: a report without the top bar passes none" 0 "$(grep -c '^PASS' "$T/top-bar.out")"
}

test_dock() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run dock_metrics "$variant")"
        if ((failures == 0 && passes == 7)); then
            ok "dock ($variant): a dock drawn from the tokens passes all $passes assertions"
        else
            not_ok "dock ($variant): a dock drawn from the tokens passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run dock_metrics light "$change")"
        if ((failures == 1)); then
            ok "dock: $what fails one assertion"
        else
            not_ok "dock: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.dock.bottomGap = 0|a dock on the screen's edge
.dock.centreOffset = 12|an off-centre dock
.dock.visible = false|a hidden dock
.dock.radius = 16|upstream's dash radius
.dock.items[0].iconSize = 64|upstream's fitted icon size
.dock.items[3].iconSize = 46|a Show Apps tile at another size
.dock.items = [.dock.items[0], {kind: "separator"}] + .dock.items[1:]|upstream's separator between favourites and running apps
.dock.items = .dock.items[:-1]|no Trash
.dock.items = .dock.items[:2] + [.dock.items[3], .dock.items[2], .dock.items[4]]|Show Apps before the separator
.dock.items[3].iconName = "view-app-grid-symbolic"|a symbolic Show Apps tile
.dock.overviewDashVisible = true|the overview's own dash beside the dock
.scenes.overview.dockVisible = false|no dock in the overview
.scenes.overview.dockClearance = -15|workspaces under the dock in the overview
CHANGES
    assert_run dock_metrics light 'del(.dock)' >/dev/null
    expect_eq "dock: a report without the dock passes none" 0 "$(grep -c '^PASS' "$T/top-bar.out")"
}

test_shell_surfaces() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run shell_surfaces "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes > 10)); then
            ok "shell surfaces ($variant): a menu, an OSD and a banner drawn from the tokens pass all $passes assertions"
        else
            not_ok "shell surfaces ($variant): drawn from the tokens they pass (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run shell_surfaces light "$change")"
        if ((failures == 1)); then
            ok "shell surfaces: $what fails one assertion"
        else
            not_ok "shell surfaces: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.popupMenu.content.background = "#fafafbff"|upstream's menu fill
.surfaces.popupMenu.content.radius = 20|upstream's menu radius
.surfaces.popupMenu.content.boxShadow.blur = 4|upstream's menu shadow
.surfaces.popupMenu.content.padding.top = 6|a menu inset by its border too
.surfaces.popupMenu.content.width = 200|a menu narrower than the board's
.surfaces.popupMenu.rows[2].height = 39|upstream's row height
.surfaces.popupMenu.rows[0].hover.background = "#d8d8e0ff"|upstream's hover fill
.surfaces.popupMenu.rows[0].y -= 1|rows 2 px apart
.surfaces.popupMenu.separator.x -= 8|a separator across the whole menu
.surfaces.popupMenu.icon = 16.364|upstream's em-sized row glyph
.surfaces.osd.box.radius = 999|upstream's round OSD
.surfaces.osd.box.border.top = 0|an OSD without its ring
.surfaces.banner.box.borderColor = "#e6e6ebff"|upstream's grey border on the banner
.surfaces.osd.box.spacing = 8|parts too close in the OSD
.surfaces.osd.level.active = "#ffffffff"|upstream's white level
.surfaces.osd.bottomGap = 59|upstream's OSD position
.surfaces.banner.box.width = 513|upstream's banner width
.surfaces.banner.box.boxShadow = null|a banner without its shadow
.surfaces.banner.box.padding.top = 6|upstream's banner padding
.surfaces.banner.title.font.weight = 400|a title at body weight
.surfaces.banner.title.x += 6|upstream's margin beside the icon
.surfaces.banner.close.background = "#22222626"|upstream's close button
.surfaces.banner.button.radius = 8|upstream's square-ish action button
CHANGES
    assert_run shell_surfaces light 'del(.surfaces)' >/dev/null
    expect_eq "shell surfaces: a report without them passes none" 0 "$(grep -c '^PASS' "$T/top-bar.out")"
}

test_quick_settings() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run quick_settings "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes > 10)); then
            ok "Quick Settings ($variant): drawn from the tokens it passes all $passes assertions"
        else
            not_ok "Quick Settings ($variant): drawn from the tokens it passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run quick_settings light "$change")"
        if ((failures == 1)); then
            ok "Quick Settings: $what fails one assertion"
        else
            not_ok "Quick Settings: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.quickSettings.box.radius = 36|upstream's panel radius
.surfaces.quickSettings.box.width = 348|a panel narrower than the board's
.surfaces.quickSettings.box.borderColor = "#e6e6ebff"|upstream's grey border
.surfaces.quickSettings.grid.rows = 12|upstream's grid gap
.surfaces.quickSettings.system.screenshot.radius = 8|square round buttons
.surfaces.quickSettings.system.battery.title.font.weight = 700|a bold battery percentage
.surfaces.quickSettings.unchecked.height = 44|upstream's toggle height
.surfaces.quickSettings.unchecked.background = "#ebebedff"|upstream's toggle fill
.surfaces.quickSettings.wifi.toggle.subtitle.foreground = "#ffffffff"|a subtitle at full opacity
.surfaces.quickSettings.wifi.toggle.box.padding.right = 8|upstream's padding before the arrow
.surfaces.quickSettings.wifi.toggle.title.font.size = 14.667|upstream's 11 pt title
.surfaces.quickSettings.wifi.separator.width = 1|upstream's separator
.surfaces.quickSettings.slider.trackHeight = 4|upstream's slider track
.surfaces.quickSettings.wifiMenu.box.boxShadow = {color: "#00000010", inset: false, x: 0, y: 1, blur: 2, spread: 0}|upstream's card shadow
.surfaces.quickSettings.wifiMenu.headerIcon.width = 36|upstream's header glyph circle
.surfaces.quickSettings.wifiMenu.rows[0].height = 37|upstream's menu row
CHANGES
    assert_run quick_settings light 'del(.surfaces)' >/dev/null
    expect_eq "Quick Settings: a report without it passes none" 0 "$(grep -c '^PASS' "$T/top-bar.out")"
}

test_window_switcher() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run window_switcher "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 5)); then
            ok "window switcher ($variant): drawn from the tokens it passes all $passes assertions"
        else
            not_ok "window switcher ($variant): drawn from the tokens it passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run window_switcher light "$change")"
        if ((failures == 1)); then
            ok "window switcher: $what fails one assertion"
        else
            not_ok "window switcher: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.switcher.list.background = "#2e2e33ff"|upstream's dark OSD fill
.surfaces.switcher.list.boxShadow.blur = 8|upstream's switcher shadow
.surfaces.switcher.spacing = 12|upstream's gap between tiles
.surfaces.switcher.items[1].foreground = "#ffffffff"|upstream's white selected name
.surfaces.switcher.items[0].background = "#00000a1e"|a second tile filled as selected
.surfaces.switcher.app.label.weight = 400|names at body weight
CHANGES
}

test_modal_dialog() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run modal_dialog "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 8)); then
            ok "modal dialog ($variant): drawn from the tokens it passes all $passes assertions"
        else
            not_ok "modal dialog ($variant): drawn from the tokens it passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run modal_dialog light "$change")"
        if ((failures == 1)); then
            ok "modal dialog: $what fails one assertion"
        else
            not_ok "modal dialog: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.dialog.box.radius = 18|upstream's dialog radius
.surfaces.dialog.box.boxShadow.blur = 8|upstream's dialog shadow
.surfaces.dialog.box.padding.bottom = 23|upstream's even padding
.surfaces.dialog.title.font.weight = 800|upstream's title weight
.surfaces.dialog.entry.height = 41|upstream's entry padding
.surfaces.dialog.entry.focus.boxShadow.color = "#3584e4cc"|upstream's 80 % focus ring
.surfaces.dialog.buttons[0].radius = 12|upstream's square-ish buttons
.surfaces.dialog.buttons[1].background = "#00000a10"|a default button without the accent
CHANGES
}

test_date_menu() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run date_menu "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 12)); then
            ok "calendar ($variant): drawn from the tokens it passes all $passes assertions"
        else
            not_ok "calendar ($variant): drawn from the tokens it passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run date_menu light "$change")"
        if ((failures == 1)); then
            ok "calendar: $what fails one assertion"
        else
            not_ok "calendar: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.dateMenu.list.border.right = 1|upstream's line between the columns
.surfaces.dateMenu.message.background = "#ffffffb8"|a translucent card under a stacked one
.surfaces.dateMenu.message.marginBottom = 12|upstream's gap between cards
.surfaces.dateMenu.message.padding.left = 5|upstream's card padding
.surfaces.dateMenu.message.icon = 48|upstream's 48 px icon
.surfaces.dateMenu.message.close.width = 32|upstream's close button
.surfaces.dateMenu.clear.height = 40|a Clear button stretched to the footer
.surfaces.dateMenu.dateLabel.font.weight = 700|a lighter date
.surfaces.dateMenu.calendar.borderColor = "#00000000"|upstream's transparent card border
.surfaces.dateMenu.heading.background = "#fafafbff"|upstream's filled headings
.surfaces.dateMenu.day.height = 33|upstream's 3 em days
.surfaces.dateMenu.otherMonth.foreground = "#1d1d2180"|upstream's half-opacity other months
.surfaces.dateMenu.eventsTitle.foreground = "#1d1d21ff"|an events title at full strength
CHANGES
}

test_overview_style() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run overview_style "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 6)); then
            ok "overview ($variant): drawn from the tokens it passes all $passes assertions"
        else
            not_ok "overview ($variant): drawn from the tokens it passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run overview_style light "$change")"
        if ((failures == 1)); then
            ok "overview: $what fails one assertion"
        else
            not_ok "overview: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.overview.group.background = "#222226ff"|upstream's dark overview
.surfaces.overview.search.width = 320|upstream's 24 em search field
.surfaces.overview.search.y = 44|upstream's 12 px gap under the bar
.surfaces.overview.search.focus.boxShadow.color = "#3584e4cc"|upstream's 80 % focus ring
.surfaces.overview.indicator.border.top = 3|upstream's 3 px indicator
.surfaces.overview.caption.background = "#000000e6"|upstream's dark tooltip caption
.surfaces.overview.section.background = "#2e2e33ff"|upstream's dark search section
CHANGES
}

# shellcheck disable=SC2016 # a jq program
readonly NOTIFICATIONS_REPORT='{surfaces: {notificationsLayer: {header: false, cardHeader: {sourceIcon: false, line: "G2 Chat · now"}, icon: "mail-unread-symbolic",
  messages: [{x: 0, y: 0, width: 400, height: 80}, {x: 0, y: 88, width: 400, height: 80}, {x: 0, y: 176, width: 400, height: 80}],
  footer: {x: 0, y: 600, width: 400, height: 40}, clear: {x: 310, y: 604, width: 86, height: 32, visible: true},
  dnd: {x: 4, y: 604, width: 180, height: 32, label: "Do Not Disturb"}, dndClick: {showBanners: false, checked: true},
  empty: {placeholder: true, clearVisible: true, clearReactive: false}}}}'

test_notifications_layer() {
    local change what passes failures
    jq -nc "$NOTIFICATIONS_REPORT" | sed 's/^/APEXG2-SCENES /' >"$T/notifications.log"
    read -r passes failures <<<"$(assertion_counts notifications_layer case "$T/notifications.log" apex)"
    expect_eq "notifications: the feature's list, cards and footer pass all five assertions" "5/0" "$passes/$failures"
    while IFS='|' read -r change what; do
        jq -nc "$NOTIFICATIONS_REPORT | .surfaces.notificationsLayer |= ($change)" | sed 's/^/APEXG2-SCENES /' >"$T/notifications.log"
        read -r passes failures <<<"$(assertion_counts notifications_layer case "$T/notifications.log" apex)"
        expect_eq "notifications: $what fails one assertion" "4/1" "$passes/$failures"
    done <<'CHANGES'
.messages[1].y = 10|a stacked group
.header = true|a group header
.cardHeader.sourceIcon = true|a card header with the source glyph
.icon = null|a card without the app's icon
.dnd = null|a footer without Do Not Disturb
.clear.x = 200|Clear off the right edge
.dndClick.showBanners = true|a click that left banners on
.empty.clearVisible = false|Clear hidden with nothing to clear
CHANGES
    jq -nc "$NOTIFICATIONS_REPORT | .surfaces.notificationsLayer |= (.messages[1].y = 10 | .dnd = null | .empty.clearVisible = false
        | .cardHeader.sourceIcon = true | .icon = null)" |
        sed 's/^/APEXG2-SCENES /' >"$T/notifications.log"
    read -r passes failures <<<"$(assertion_counts notifications_layer case "$T/notifications.log" stock)"
    expect_eq "notifications: stock's stacked list and lone Clear pass both stock assertions" "2/0" "$passes/$failures"
}

test_shadow_layers() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run shadow_layers "$variant")"
        if ((failures == 0 && passes == 4)); then
            ok "shadows ($variant): layers drawn from the tokens pass all $passes assertions"
        else
            not_ok "shadows ($variant): layers drawn from the tokens pass (passed/failed $passes/$failures): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run shadow_layers light "$change")"
        expect_eq "shadows: $what fails one assertion" "3/1" "$passes/$failures"
    done <<'CHANGES'
.surfaces.shadowLayers.quickSettings[0].radius = 0|a Quick Settings layer with square corners
.surfaces.shadowLayers.dateMenu = []|a calendar without its second layer
.surfaces.shadowLayers.dialog[0].besideBox = false|a dialog layer under the lightbox
.surfaces.shadowLayers.dateMenu[0].sameBox = false|a layer off its surface's box
.surfaces.shadowLayers.dialog[0].boxShadow.blur = 50|the first layer's blur on the second
.surfaces.idleRepaints.withShadows = 9|an idle desktop that repaints more with shadows
CHANGES
}

test_overview_layer() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run overview_layer "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 6)); then
            ok "overview feature ($variant): the layer's overview passes all $passes assertions"
        else
            not_ok "overview feature ($variant): the layer's overview passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run overview_layer light "$change")"
        if ((failures == 1)); then
            ok "overview feature: $what fails one assertion"
        else
            not_ok "overview feature: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.overviewLayer.titleVisible = false|titles only on hover
.surfaces.overviewLayer.thumbnails.maxScale = 0.05|upstream's thumbnail scale
.surfaces.overviewLayer.thumbnailsThreshold = 2|thumbnails only from three workspaces
.surfaces.overviewLayer.thumbnails.first.height = 58|thumbnails cut down by the box's padding
.surfaces.overviewLayer.workspace.background = true|the workspace background card
.surfaces.overviewLayer.workspace.empty.y = 300|the empty label off centre
.surfaces.overviewLayer.workspace.empty.foreground = "#1d1d21ff"|the empty label in full $apex_fg
.surfaces.appGrid.grid.iconSize = 96|upstream's 96 px launcher icons
CHANGES
}

test_app_grid() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run app_grid "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 6)); then
            ok "launcher ($variant): drawn from the tokens it passes all $passes assertions"
        else
            not_ok "launcher ($variant): drawn from the tokens it passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run app_grid light "$change")"
        if ((failures == 1)); then
            ok "launcher: $what fails one assertion"
        else
            not_ok "launcher: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.appGrid.app.radius = 24|upstream's tile radius
.surfaces.appGrid.app.foreground = "#fafafbff"|upstream's white labels on the light scrim
.surfaces.appGrid.app.focus.boxShadow.color = "#3584e4cc"|upstream's 80 % focus ring
.surfaces.appGrid.folder.background = "#3a3a3eff"|upstream's raised dark folder
.surfaces.appGrid.dialog.width = 720|upstream's 720 px folder
.surfaces.appGrid.dialog.title.font.size = 26.667|upstream's title 1 folder name
.surfaces.appGrid.pageHint.gradient = 1|upstream's gradient page hint
CHANGES
}

test_derived_surfaces() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run derived_surfaces "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 6)); then
            ok "derived surfaces ($variant): drawn from the tokens they pass all $passes assertions"
        else
            not_ok "derived surfaces ($variant): drawn from the tokens they pass (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run derived_surfaces light "$change")"
        if ((failures == 1)); then
            ok "derived surfaces: $what fails one assertion"
        else
            not_ok "derived surfaces: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.derived.resizePopup.radius = 999|upstream's round OSD panel
.surfaces.derived.wsIndicator.active.background = "#ffffffff"|upstream's white current workspace
.surfaces.derived.candidatePopup.background = "#fafafbff"|upstream's menu fill on the candidates
.surfaces.derived.runEntry.minHeight = null|upstream's padded run entry
.surfaces.derived.audioDevice.foreground = "#22222666"|a dimmed device name
.surfaces.derived.monitorLabel.radius = 16|upstream's monitor label radius
CHANGES
}

test_spotlight_style() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run spotlight_style "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 15)); then
            ok "Spotlight ($variant): drawn from the tokens it passes all $passes assertions"
        else
            not_ok "Spotlight ($variant): drawn from the tokens it passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run spotlight_style light "$change")"
        if ((failures == 1)); then
            ok "Spotlight: $what fails one assertion"
        else
            not_ok "Spotlight: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.spotlight.panel.width = 640|a 640 px panel
.surfaces.spotlight.panel.top = 72|a panel 72 px down
.surfaces.spotlight.panel.boxShadow = null|a panel without its shadow
.surfaces.spotlight.field.height = 48|a 48 px field
.surfaces.spotlight.entry.font.size = 14|upstream's 14 px entry text
.surfaces.spotlight.entry.hint = "#1d1d2166"|the fainter hint of the calendar's other months
.surfaces.spotlight.results.border.top = 0|no line above the results
.surfaces.spotlight.headers[1].height = 24|a header without its gap above
.surfaces.spotlight.sections = ["SETTINGS", "APPLICATIONS", "FILES"]|the sections out of order
.surfaces.spotlight.rows[3].height = 44|a 44 px row
.surfaces.spotlight.rows[0].background = "#3584e44d"|a 30 % selection
.surfaces.spotlight.selected = [false, true, false, false, false, false, false, false, false]|the selection on the second row
.surfaces.spotlight.rows[2].subtitle.foreground = "#1d1d21ff"|a subtitle at full strength
.surfaces.spotlight.rows[0].action.chip.radius = 10|a rounder Enter chip
.surfaces.spotlight.calculator.row.title.font.features = ""|a result in proportional figures
.surfaces.spotlight.empty.height = 60|a 60 px empty row
.surfaces.spotlight.fieldOnly = false|results under an empty query
.surfaces.spotlight.toast.bottomGap = 104|a toast at the OSD's height
.surfaces.spotlight.closedOnCopy = false|Spotlight left open after the copy
.surfaces.spotlight.toast.box.borderColor = "#00000000"|a toast without its ring
.surfaces.spotlight.toast.check.background = "#1d1d21ff"|a check circle without the accent
CHANGES
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
    if grep -q '^FAIL captures: compare.js compared none of 6 ' "$T/fedora-compare.out"; then
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
    expect_eq "clock: assert.sh expects the time direct.sh gives clock.c" "$clock" \
        "$(sed -n "s/^readonly G2_CLOCK='\([0-9-]*\) \([0-9:]*\)'\$/\1T\2Z/p" "$HERE/direct.sh")"
    while IFS='|' read -r failures what clock; do
        printf 'APEXG2 %s\n' "$clock" >"$T/clock.log"
        read -r passes _ <<<"$(assertion_counts fixed_clock case "$T/clock.log")"
        expect_eq "clock: $what fails $failures of 2" "$failures" $((2 - passes))
    done <<'CLOCKS'
0|the fixed time, as G2's 24-hour clock shows it,|{"clock": {"now": "2026-09-28T09:41:00Z", "text": "Mon Sep 28\u200209:41"}}
1|a plain space for the EN SPACE|{"clock": {"now": "2026-09-28T09:41:00Z", "text": "Mon Sep 28 09:41"}}
1|a clock without the weekday|{"clock": {"now": "2026-09-28T09:41:00Z", "text": "Sep 28\u200209:41"}}
1|a shell that missed clock.c|{"clock": {"now": "2026-10-23T14:02:11Z", "text": "Mon Sep 28\u200209:41"}}
2|a shell without G2_CLOCK_EPOCH|{"clock": null}
CLOCKS
}

# shellcheck disable=SC2016 # a jq program
CYCLES_REPORT='
{actors: {ClutterStage: 1, StWidget: 420, StLabel: 96, StIcon: 61}} as $census
| ({stylesheet: "resource:///org/gnome/shell/theme/gnome-shell-light.css", markers: ["light"], markerColor: "#16161aff",
   sessionColorScheme: "prefer-light", variant: "light", safe: false,
   spotlightKey: {modes: ["NORMAL", "OVERVIEW"], accelerators: ["<Super>space"]}} + $census) as $on
| ({stylesheet: "resource:///org/gnome/shell/theme/stock/gnome-shell-dark.css", markers: [], markerColor: "#ffffffff",
   sessionColorScheme: "prefer-dark", variant: "dark", safe: true,
   spotlightKey: {modes: [], accelerators: ["<Super>space"]}} + $census) as $off
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
.states[3].spotlightKey.modes = ["NORMAL", "OVERVIEW"]|Super+Space left registered while the layer is off
.states[6].spotlightKey.modes = []|Super+Space not back after the layer is
CHANGES
    write_cycles_run '.states[5].layerEnabled = true'
    read -r passes failures <<<"$(assertion_counts layer_cycles "$T/cycles")"
    if ((failures >= 1)); then ok "layer cycles: a switch that did not reach the shell fails"; else not_ok "layer cycles: a switch that did not reach the shell fails"; fi
    write_cycles_run .
    sed -i '0,/true: the Apex shell/{/true: the Apex shell/d}' "$T/cycles/layer-cycles.log"
    read -r passes failures <<<"$(assertion_counts layer_cycles "$T/cycles")"
    expect_eq "layer cycles: a switch the layer did not log fails one assertion" "$((all - 1))/1" "$passes/$failures"
}

# shellcheck disable=SC2016 # a jq program
readonly MOTION_REPORT='{enableAnimations: false,
  animated: {maximise: {maximised: true, transition: {mode: "CUBIC_BEZIER", duration: 300, curve: [0.2, 0.8, 0.2, 1]}},
             overview: {visible: true, transition: {mode: "CUBIC_BEZIER", duration: 200, curve: [0.2, 0.8, 0.2, 1]}}},
  still: {maximise: {maximised: true, transition: null}, overview: {visible: true, transition: null},
         locatePointer: {mode: "CUBIC_BEZIER", duration: 830, curve: [0.2, 0.8, 0.2, 1]}},
  previews: [{styled: true, layers: [
    {shown: true, radius: 14, boxShadow: {color: "#141e3c33", inset: false, x: 0, y: 12, blur: 32, spread: 0}},
    {shown: true, radius: 14, boxShadow: {color: "#141e3c1a", inset: false, x: 0, y: 1, blur: 4, spread: 0}}]}]}'

write_motion_run() {
    local change=$1 dir=$T/motion
    rm -rf "$dir" && mkdir -p "$dir"
    {
        printf 'APEXG2 %s\n' "$APEX_LIGHT_REPORT"
        printf 'APEXG2-MOTION %s\n' "$(jq -nc "$MOTION_REPORT | $change")"
    } >"$dir/motion.log"
    echo 'motion exit=0 secs=24 marker-after-exit=no' >"$dir/results-main.txt"
}

test_motion() {
    local change what passes failures all
    write_motion_run .
    read -r all failures <<<"$(assertion_counts motion_curve "$T/motion")"
    if ((failures == 0 && all > 5)); then
        ok "motion: the Apex curve and durations, and 0 ms without animations, pass all $all assertions"
    else
        not_ok "motion: a clean run passes (passed/failed $all/$failures): $(grep -m3 '^FAIL' "$T/assertions.out" | paste -sd'|' -)"
    fi
    while IFS='|' read -r change what; do
        write_motion_run "$change"
        read -r passes failures <<<"$(assertion_counts motion_curve "$T/motion")"
        expect_eq "motion: $what fails one assertion" "$((all - 1))/1" "$passes/$failures"
    done <<'CHANGES'
.animated.maximise.transition.mode = "EASE_OUT_QUAD"|stock's maximise mode
.animated.maximise.transition.curve = [0, 0, 0, 0]|the curve's mode without its control points
.animated.overview.transition.duration = 250|stock's overview duration
.animated.overview.transition = null|an overview that did not animate
.still.maximise.transition = {mode: "CUBIC_BEZIER", duration: 1}|a transition left with animations off
.animated.maximise.maximised = false|a window that did not maximise
.still.locatePointer = null|a Locate Pointer ripple that no longer animates with animations off
.previews[0].layers = [.previews[0].layers[0]]|a window preview with one shadow layer
CHANGES
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
const device = primary?.get_devices()[0];
const ap = device?.get_active_access_point();
// network.js lists an access point only when one security type is valid for it.
const securityTypes = Object.values(NM.UtilsSecurityType).filter(t => t !== NM.UtilsSecurityType.INVALID);
const listed = (device?.get_access_points() ?? []).filter(a => securityTypes.some(t =>
    NM.utils_security_valid(t, device.wireless_capabilities, true, false, a.flags, a.wpa_flags, a.rsn_flags)))
    .map(a => NM.utils_ssid_to_utf8(a.get_ssid().get_data()));
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
        wifi: {id: primary?.get_id() ?? null, strength: ap?.get_strength() ?? null, listed,
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
    fixtures_report "G2-FIXTURES $(jq -c . <<<'{"battery": {"percentage": 87.0, "present": true, "onBattery": true},
        "wifi": {"primary": "Apex-5G", "ssid": "Apex-5G", "strength": 90, "inRange": ["Apex-5G", "Apex-2.4G", "Library Guest"],
            "state": 70, "connectivity": 4},
        "keyboard": {"alias": "Keychron K3", "connected": true, "icon": "input-keyboard"},
        "powerProfiles": {"active": "balanced", "profiles": ["power-saver", "balanced", "performance"]}}')"
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: what fixtures.py reports passes each part's five assertions" "15/0" "$passes/$failures"
    fixtures_report 'G2-FIXTURES {"battery": {"percentage": 0.0, "present": false, "onBattery": false}, "wifi": {"primary": "Apex-5G", "ssid": "Apex-5G", "strength": 30, "inRange": ["Apex-5G"], "state": 70, "connectivity": 4}, "keyboard": {"alias": "Keychron K3", "connected": false, "icon": "phone"}, "powerProfiles": null}'
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: no battery, a weak signal, one network in range and a keyboard left unconnected, and no power-profiles-daemon fail all five" "0/15" "$passes/$failures"
    fixtures_report 'fixtures.py: no owner for org.bluez after 20 s'
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: a fixtures.py that failed fails them" "0/15" "$passes/$failures"

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
    DBUS_SYSTEM_BUS_ADDRESS=$address G2_POWER_PROFILES=1 python3 "$HERE/fixtures.py" "$T/fixtures" >"$T/fixtures/fixtures-main.txt" 2>&1 || true
    cp "$T/fixtures/fixtures-main.txt" "$T/fixtures/fixtures-kernel.txt"
    cp "$T/fixtures/fixtures-main.txt" "$T/fixtures/fixtures-fedora.txt"
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: fixtures.py on a private bus passes the fixture assertions" "15/0" "$passes/$failures"
    write_fixture_reader
    expect_eq "fixtures: libnm, gnome-bluetooth and UPower's display device read them as the shell does" \
        '{"wifi":{"id":"Apex-5G","strength":90,"listed":["Apex-5G","Apex-2.4G","Library Guest"],"full":true,"wireless":true},"battery":{"present":true,"percentage":87},"connectedBluetooth":["Keychron K3"]}' \
        "$(DBUS_SYSTEM_BUS_ADDRESS=$address gjs -m "$T/read-fixtures.js" 2>"$T/read-fixtures.err")"
    local -a pids
    mapfile -t pids < <(cat "$T/bus.pid" "$T"/fixtures/fixture-*.pid 2>/dev/null)
    kill "${pids[@]}" 2>/dev/null || true
}

# clock.c must hold the wall clock and leave an absolute monotonic timer alone: libfaketime
# moved mutter's frame timer, and no headless shell ever finished starting.
test_clock_c() {
    local epoch=1790588460 held timer
    if ! command -v gcc >/dev/null 2>&1; then
        skip_or_fail "clock.c: needs gcc"
        return
    fi
    if ! gcc -O2 -Wall -Werror -shared -fPIC -o "$T/clock.so" "$HERE/clock.c" 2>"$T/clock.err"; then
        not_ok "clock.c: builds with -Wall -Werror ($(head -n 3 "$T/clock.err" | paste -sd'|' -))"
        return
    fi
    ok "clock.c: builds with -Wall -Werror"
    held=$(LD_PRELOAD=$T/clock.so G2_CLOCK_EPOCH=$epoch date -u +%FT%T.%NZ)
    expect_eq "clock.c: date reads the fixed time" 2026-09-28T09:41:00.000000000Z "$held"
    held=$(LD_PRELOAD=$T/clock.so G2_CLOCK_EPOCH=$epoch gjs -c 'const GLib = imports.gi.GLib; print(GLib.DateTime.new_now_utc().format_iso8601())')
    expect_eq "clock.c: GLib reads the fixed time" 2026-09-28T09:41:00Z "$held"
    held=$(LD_PRELOAD=$T/clock.so date -u +%Y)
    expect_eq "clock.c: without G2_CLOCK_EPOCH the clock is the real one" "$(date -u +%Y)" "$held"
    # shellcheck disable=SC2016 # a gjs program
    timer=$(LD_PRELOAD=$T/clock.so G2_CLOCK_EPOCH=$epoch timeout 10 gjs -c '
        const GLib = imports.gi.GLib;
        const loop = new GLib.MainLoop(null, false);
        const start = GLib.get_monotonic_time();
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, () => {
            print(GLib.get_monotonic_time() - start >= 200000 ? "fired" : "early");
            loop.quit();
            return GLib.SOURCE_REMOVE;
        });
        loop.run();' 2>&1)
    expect_eq "clock.c: a GLib timeout on the monotonic clock still fires after 200 ms" fired "$timer"
    timer=$(LD_PRELOAD=$T/clock.so G2_CLOCK_EPOCH=$epoch timeout 10 python3 -c '
import os, time
fd = os.timerfd_create(time.CLOCK_MONOTONIC)
os.timerfd_settime_ns(fd, flags=os.TFD_TIMER_ABSTIME, initial=time.clock_gettime_ns(time.CLOCK_MONOTONIC) + 200_000_000)
os.read(fd, 8)
print("fired")' 2>&1)
    expect_eq "clock.c: an absolute timerfd on the monotonic clock, as mutter's frame clock sets, fires" fired "$timer"
    timer=$(LD_PRELOAD=$T/clock.so G2_CLOCK_EPOCH=$epoch timeout 10 python3 -c '
import os, time
fd = os.timerfd_create(time.CLOCK_REALTIME)
start = time.monotonic()
os.timerfd_settime_ns(fd, flags=os.TFD_TIMER_ABSTIME, initial=time.time_ns() + 300_000_000)
os.read(fd, 8)
print("on time" if time.monotonic() - start >= 0.25 else "at once")' 2>&1)
    expect_eq "clock.c: a wall-clock timerfd 300 ms after the fixed time, as GnomeWallClock sets, fires on time" "on time" "$timer"
    cat >"$T/time-change.c" <<'EOF'
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/timerfd.h>

int main(void)
{
    int fd = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK);
    struct itimerspec its = {.it_value.tv_sec = (time_t)UINT64_MAX};
    int refused = timerfd_settime(fd, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET, &its, NULL) < 0;
    struct pollfd ready = {.fd = fd, .events = POLLIN};

    its.it_value.tv_sec = UINT32_MAX;
    timerfd_settime(fd, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET, &its, NULL);
    printf("%s %s\n", refused ? "refused" : "accepted", poll(&ready, 1, 300) == 0 ? "quiet" : "fired");
    return 0;
}
EOF
    if gcc -O2 -Wall -Werror -o "$T/time-change" "$T/time-change.c" 2>"$T/time-change.err"; then
        expect_eq "clock.c: gnome-shell's time-change timer is refused at -1 and stays quiet at 2106" "refused quiet" \
            "$(LD_PRELOAD=$T/clock.so G2_CLOCK_EPOCH=$epoch timeout 10 "$T/time-change" 2>&1)"
    else
        not_ok "clock.c: the time-change test builds ($(head -n 3 "$T/time-change.err" | paste -sd'|' -))"
    fi
}

test_overview_below_bar() {
    local passes failures what report
    while IFS='|' read -r failures what report; do
        printf 'APEXG2-SCENES %s\n' "$report" >"$T/overview.log"
        read -r passes _ <<<"$(assertion_counts overview_below_bar case "$T/overview.log")"
        expect_eq "overview: $what fails $failures of 1" "$failures" $((1 - passes))
    done <<'REPORTS'
0|a work area that starts at the bar's height|{"topBar": {"panel": {"height": 32}}, "scenes": {"overview": {"workArea": {"y": 32, "height": 868}}}}
1|a work area 2 px lower|{"topBar": {"panel": {"height": 32}}, "scenes": {"overview": {"workArea": {"y": 34, "height": 866}}}}
1|a probe without the work area|{"topBar": {"panel": {"height": 32}}, "scenes": {"overview": {}}}
REPORTS
}

test_spotlight_key() {
    local passes failures what report
    while IFS='|' read -r failures what report; do
        printf 'APEXG2 %s\n' "$report" >"$T/spotlight.log"
        read -r passes _ <<<"$(assertion_counts spotlight_key case "$T/spotlight.log")"
        expect_eq "spotlight: $what fails $failures of 2" "$failures" $((2 - passes))
    done <<'REPORTS'
0|Super+Space in the normal and overview modes|{"spotlightKey": {"modes": ["NORMAL", "OVERVIEW"], "accelerators": ["<Super>space"]}}
1|an override that moved it|{"spotlightKey": {"modes": ["NORMAL", "OVERVIEW"], "accelerators": ["<Super><Alt>space"]}}
1|also on the lock screen|{"spotlightKey": {"modes": ["NORMAL", "OVERVIEW", "UNLOCK_SCREEN"], "accelerators": ["<Super>space"]}}
1|not registered|{"spotlightKey": {"modes": [], "accelerators": ["<Super>space"]}}
2|no Keybindings schema|{"spotlightKey": {"modes": [], "accelerators": "no-schema"}}
2|a probe without the field|{"mode": "user"}
REPORTS
    while IFS='|' read -r failures what report; do
        printf 'APEXG2 %s\n' "$report" >"$T/spotlight.log"
        read -r passes _ <<<"$(assertion_counts no_spotlight_key case "$T/spotlight.log")"
        expect_eq "spotlight: $what fails $failures of 1 in a stock shell" "$failures" $((1 - passes))
    done <<'REPORTS'
0|no binding|{"spotlightKey": {"modes": [], "accelerators": ["<Super>space"]}}
1|a binding the layer left behind|{"spotlightKey": {"modes": ["NORMAL", "OVERVIEW"], "accelerators": ["<Super>space"]}}
REPORTS
}

# glass.js's reference and frame reader, and glass_frames over reports built for it.
test_glass() {
    local line rc=0 passes failures what change
    gjs -m "$HERE/blur-ref-test.js" >"$T/blur-ref.tap" 2>&1 || rc=$?
    while IFS= read -r line; do
        case $line in
            'ok '*) ok "blur-ref.js: ${line#* - }" ;;
            'not ok '*) not_ok "blur-ref.js: ${line#* - }" ;;
        esac
    done <"$T/blur-ref.tap"
    ((rc == 0)) || grep -q '^not ok' "$T/blur-ref.tap" || not_ok "blur-ref-test.js exited $rc: $(tail -n 3 "$T/blur-ref.tap" | paste -sd'|' -)"

    if command -v gcc >/dev/null 2>&1 && command -v gi-compile-repository >/dev/null 2>&1 &&
        pkg-config --exists glib-2.0 2>/dev/null; then
        # shellcheck disable=SC2046 # pkg-config prints several flags
        if gcc -O2 -Wall -Werror -shared -fPIC $(pkg-config --cflags glib-2.0) -o "$T/libg2frame.so" "$HERE/frame.c" 2>"$T/frame.err" &&
            gi-compile-repository --includedir=/usr/share/gir-1.0 -o "$T/G2Frame-1.typelib" "$HERE/G2Frame-1.gir" 2>>"$T/frame.err"; then
            ok "frame.c builds with -Wall -Werror, and G2Frame-1.gir compiles"
        else
            not_ok "frame.c builds with -Wall -Werror, and G2Frame-1.gir compiles ($(head -n 3 "$T/frame.err" | paste -sd'|' -))"
        fi
    else
        skip_or_fail "frame.c: needs gcc, pkg-config and glib2-devel's gi-compile-repository"
    fi

    local good='{"patched": true, "pixels": {"reference": {"clippedFirst": true, "reblurCovered": true, "downscale": 16,
            "box": {"max": [11.03, 6.23, 11.67], "mean": [0.744, 0.555, 0.749]}, "interior": {"max": [2.9, 2.32, 3.2], "mean": [0.612, 0.488, 0.636]},
            "edge": {"max": [11.03, 6.23, 11.67], "mean": [1.4, 0.9, 1.3]}},
        "sameFrame": {"covered": true, "changed": 44893, "differingFromFull": 0},
        "clippedRedraw": {"covered": false, "differingFromLast": 0, "nextCovered": true, "nextDifferingFromFull": 0},
        "stock": {"covered": false, "differingFromLast": 2304, "differingFromFull": 43927,
            "box": {"max": [180, 150, 170], "mean": [9, 7, 8]}, "interior": {"max": [180, 150, 170], "mean": [9, 7, 8]}, "edge": {"max": [60, 50, 40], "mean": [5, 4, 4]}}}}'
    while IFS='|' read -r failures what change; do
        jq -c "$change" <<<"$good" | sed 's/^/APEXG2-GLASS /' >"$T/glass.log"
        read -r passes _ <<<"$(assertion_counts glass_frames glass "$T/glass.log")"
        expect_eq "glass: $what fails $failures of 6" "$failures" $((6 - passes))
    done <<'CHANGES'
0|a run within the tolerance, the frames as drawn|.
0|the 4/255 the lead accepted inside|.pixels.reference.interior.max[2] = 4
1|a channel 4.2/255 off inside|.pixels.reference.interior.max[2] = 4.2
1|a channel 12.5/255 off in the edge band|.pixels.reference.edge.max[0] = 12.5
1|a mean 1.1/255 off|.pixels.reference.box.mean[0] = 1.1
1|a run without a downscale to size the band|.pixels.reference.downscale = 1
1|a damaged frame that already covered the box|.pixels.reference.clippedFirst = false
1|a forwarded damage that waits a frame|.pixels.sameFrame.differingFromFull = 120
1|a forwarded damage that changed nothing|.pixels.sameFrame.changed = 0
1|a clipped frame that re-blurred from stale pixels|.pixels.clippedRedraw.differingFromLast = 2304
1|a clipped frame never followed by its redraw|.pixels.clippedRedraw.nextCovered = false
1|a stock control that sees nothing|.pixels.stock.differingFromFull = 0
1|a stock control within the tolerances|.pixels.stock += (.pixels.reference | {box, interior, edge})
6|Fedora's effect|{patched: false, pixels: null}
6|a probe that failed|{error: "no frame within 2000 ms"}
CHANGES

    local on='{"radius": 96, "saturation": 1.6, "enabled": true, "fine": true, "followOpacity": true, "background": true}'
    local popover='{"radius": 120, "saturation": 1.8, "enabled": true, "fine": true, "followOpacity": true, "background": true}'
    local manager
    manager=$(jq -nc --argjson on "$on" --argjson p "$popover" '{panel: $on, quickSettings: $p, calendar: $p, banner: $p, blurEffects: ["panel"], solidClass: false} as $g
        | {panel: null, quickSettings: null, calendar: null, banner: null, blurEffects: []} as $none
        | {manager: {monitorScale: 2, glass: $g, reduceTransparency: ($none + {solidClass: true}), highContrast: ($none + {solidClass: true}),
            disabled: ($none + {solidClass: false}), restored: $g}}')
    while IFS='|' read -r failures what change; do
        jq -c "$change" <<<"$manager" | sed 's/^/APEXG2-GLASS /' >"$T/glass.log"
        read -r passes _ <<<"$(assertion_counts glass_manager glass "$T/glass.log" light)"
        expect_eq "glass manager: $what fails $failures of 5" "$failures" $((5 - passes))
    done <<'CHANGES'
0|the bar and the popovers at their tokens, every switch honoured|.
1|the bar at the popovers' sigma|.manager.glass.panel.radius = 120
1|a banner at the bar's saturation|.manager.glass.banner.saturation = 1.6
1|a popover without fine|.manager.glass.calendar.fine = false
1|a blur left behind by Reduce Transparency|.manager.reduceTransparency.blurEffects = ["St_BoxLayout"]
1|Reduce Transparency without apex-solid|.manager.reduceTransparency.solidClass = false
1|high contrast that keeps the bar's glass|.manager.highContrast.panel = .manager.glass.panel
1|the kill switch that turns the tints solid|.manager.disabled.solidClass = true
1|glass that does not come back|.manager.restored.panel = null
5|no manager|.manager = null
CHANGES
}

test_png_js
test_compare_js
test_incomplete_compare
test_token_file
test_top_bar
test_dock
test_shell_surfaces
test_quick_settings
test_window_switcher
test_modal_dialog
test_date_menu
test_overview_style
test_app_grid
test_overview_layer
test_shadow_layers
test_notifications_layer
test_derived_surfaces
test_spotlight_style
test_today_pins
test_known_gaps
test_fixed_clock
test_clock_c
test_overview_below_bar
test_layer_cycles
test_motion
test_spotlight_key
test_fixtures
test_glass

printf '1..%d\n' "$tests"
((failed == 0))
