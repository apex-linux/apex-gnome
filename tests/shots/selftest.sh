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
typelibs, for frame.c gcc and glib2-devel, and for goldens.sh git. Output is TAP.
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

# glass.js's frame reads: a rect with no area or past the framebuffer fails by the step's name.
test_frame_rect() {
    cat >"$T/frame-rect-test.js" <<JS
import {deviceRect} from 'file://$HERE/frame-rect.js';
const fb = {width: 2880, height: 1800};
const attempt = (rect, scale) => {
    try {
        return JSON.stringify(deviceRect(rect, scale, fb, 'step'));
    } catch (e) {
        return e.message;
    }
};
print(attempt({x: 10, y: 20, width: 320, height: 80}, 2));
print(attempt({x: 0, y: 0, width: 0, height: 80}, 2));
print(attempt({x: 1400, y: 0, width: 80, height: 80}, 2));
print(attempt({x: NaN, y: 0, width: 80, height: 80}, 2));
JS
    local out
    out=$(gjs -m "$T/frame-rect-test.js" 2>&1 | paste -sd'|' -)
    expect_eq "frame reads: a stage rect becomes device pixels; no area, past the framebuffer or NaN fails by the step's name" \
        '{"x":20,"y":40,"width":640,"height":160}|step: no frame read for 0,0 0x160 in a 2880x1800 framebuffer|step: no frame read for 2800,0 160x160 in a 2880x1800 framebuffer|step: no frame read for NaN,0 160x160 in a 2880x1800 framebuffer' \
        "$out"
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
    appMenu: {app: "Files", hasDualGpu: true,
      items: ["Open Windows", "New Window", "Launch Using Discrete Graphics Card", "Unpin", "App Details"]},
    overviewDashVisible: false},
  scenes: {overview: {dockVisible: true, dockClearance: 12}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_SURFACES_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b | {top: $b, right: $b, bottom: $b, left: $b} as $border | ($t.apex_panel_border | hex) as $ring
| {color: ($t.apex_shadow | hex), inset: false, x: 0, y: ($t.apex_shadow_y | px), blur: ($t.apex_shadow_blur | px), spread: 0} as $shadow
| ($t.apex_menu_padding | px) as $mp | ($t.apex_menu_row_height | px) as $row | ($t.apex_menu_row_gap | px) as $gap
| ($t.apex_menu_row_padding | px) as $rp | ($t.apex_menu_separator_margin | px) as $sm
| {height: $row, radius: ($t.apex_radius_menu_row | px), padding: {left: $rp, right: $rp}, spacing: ($t.apex_menu_row_spacing | px),
   background: "#00000000", hover: {background: ($t.apex_button_hover | hex)}, checked: {background: ($t.apex_button_hover | hex)}} as $r
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
| ($t.apex_quick_toggle_checked_shade | rtrimstr("%") | tonumber / 100) as $checked
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
        toggle: {background: ([53, 132, 228] | map(. * (1 - $checked) | round) | "rgb(\(.[0]), \(.[1]), \(.[2]))" | hex), foreground: "#ffffffff", icon: $icon, title: {font: $title},
            subtitle: {foreground: ("rgba(255, 255, 255, \($t.apex_quick_toggle_subtitle_opacity))" | hex), font: {size: ($t.apex_font_quick_toggle_subtitle_size | px)}},
            box: {padding: {left: $tp, right: ($t.apex_quick_toggle_menu_padding | px)}, spacing: ($t.apex_quick_toggle_gap | px)}},
        separator: {width: 0},
        menuButton: {width: ($t.apex_quick_toggle_menu_button_width | px), background: ([53, 132, 228] | map(. * (1 - $checked) * (1 - $shade) | round) | "rgb(\(.[0]), \(.[1]), \(.[2]))" | hex)}},
    unchecked: {width: $tw, height: $th, radius: 999, background: ($t.apex_button | hex), foreground: ($t.apex_fg | hex),
        hover: {background: ($t.apex_button_hover | hex)}, icon: $icon, box: {padding: {left: $tp, right: $tp}, spacing: ($t.apex_quick_toggle_gap | px)}},
    slider: {spacing: ($t.apex_quick_slider_gap | px), trackHeight: ($t.apex_quick_slider_track_height | px), track: ($t.apex_button_hover | hex),
        fill: "#3584e4ff", handleRadius: (($t.apex_quick_slider_handle_size | px) / 2), handle: ($t.apex_slider_handle | hex)},
    wifiMenu: {
        box: {y: (44 + $bs + ($t.apex_quick_settings_section_gap | px) + $th + $gap), background: ($t.apex_card | hex), borderColor: ($t.apex_card_border | hex),
            border: {top: $b, left: $b}, radius: ($t.apex_radius_quick_menu | px), padding: {left: (($t.apex_quick_menu_padding | px) - $b)}, boxShadow: null},
        headerIcon: {width: ($t.apex_quick_menu_header_icon_size | px), height: ($t.apex_quick_menu_header_icon_size | px), background: "#3584e4ff", iconSize: $icon},
        title: {font: {size: ($t.apex_font_quick_menu_title_size | px), weight: ($t.apex_font_heading_weight | tonumber)}},
        rows: [{height: ($t.apex_quick_menu_row_height | px), padding: {left: ($t.apex_menu_row_padding | px)}, radius: ($t.apex_radius_menu_row | px)}],
        rowHover: {background: ($t.apex_quick_menu_row_hover | hex)},
        connected: {background: ($t.apex_button | hex), label: {font: {weight: ($t.apex_font_label_weight | tonumber)}}, hover: {background: ($t.apex_button_hover | hex)}},
        other: {background: "#00000000", label: {font: {weight: 400}}}}}}}'
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
    endSession: (($t.apex_end_session_button_gap | px) as $g | ((($t.apex_end_session_dialog_width | px) - 2 * $p - 2 * $g) / 3.6) as $u
        | {box: {width: ($t.apex_end_session_dialog_width | px), spacing: ($t.apex_end_session_gap | px)},
        contentSpacing: ($t.apex_end_session_gap | px), title: {tracking: ($t.apex_dialog_title_tracking | px)},
        description: {font: {features: "\"tnum\""}}, rowSpacing: $g,
        icon: {iconName: "system-shutdown-symbolic", above: true, glyph: ($t.apex_end_session_icon_glyph_size | px),
            width: ($t.apex_end_session_icon_size | px), height: ($t.apex_end_session_icon_size | px),
            radius: (($t.apex_end_session_icon_size | px) / 2), background: ($t.apex_button | hex)},
        buttons: [{text: "Cancel", width: $u, background: ($t.apex_button | hex), hover: {background: ($t.apex_button_hover | hex)}},
            {text: "Restart", width: ($u * 1.4), background: ($t.apex_button | hex), hover: {background: ($t.apex_button_hover | hex)}},
            {text: "Power Off", width: ($u * 1.2), background: ($t.apex_destructive | hex), foreground: ($t.apex_destructive_fg | hex),
                hover: {background: ($t.apex_destructive_hover | hex)}}]}),
    updateCard: ({below: true, padding: {top: ($t.apex_update_card_padding_y | px), left: ($t.apex_update_card_padding_x | px)},
        border: {top: 1}, radius: ($t.apex_radius_update_card | px), spacing: ($t.apex_update_card_gap | px),
        background: ($t.apex_card | hex), borderColor: ($t.apex_card_border | hex),
        icon: {iconName: "system-software-update", size: ($t.apex_update_card_icon_size | px)}, textSpacing: ($t.apex_update_card_text_gap | px),
        title: {text: "Start the new version next time", foreground: ($t.apex_fg | hex),
            font: {size: ($t.apex_font_update_card_title_size | px), weight: ($t.apex_font_update_card_title_weight | tonumber)}},
        subtitle: {text: "45.20261010.133 · GNOME 51.1, Linux 7.2.9, Mesa 26.1.2", foreground: ($t.apex_fg_dim | hex),
            font: {size: ($t.apex_font_update_card_subtitle_size | px)}},
        toggle: {on: true, sensitive: true, width: ($t.apex_update_switch_width | px), height: ($t.apex_update_switch_height | px),
            background: "#3584e4ff", knob: {width: ($t.apex_update_switch_knob | px)}, opacity: 1, focusable: true, a11ySensitive: true},
        buttons: ["Cancel", "Restart & Update"]}
        | {staged: ., ready: (.toggle += {sensitive: false, opacity: ($t.apex_update_switch_insensitive_opacity | tonumber), focusable: false, a11ySensitive: false})}),
    contentSpacing: ($t.apex_dialog_gap | px), textSpacing: ($t.apex_dialog_text_gap | px),
    title: {font: {size: ($t.apex_font_dialog_title_size | px), weight: ($t.apex_font_heading_weight | tonumber)}},
    description: {font: {size: ($t.apex_font_size | px)}, foreground: ($t.apex_fg_dim | hex)},
    entry: {height: ($t.apex_entry_height | px), radius: 999, background: ($t.apex_button | hex), boxShadow: null,
        padding: {left: ($t.apex_entry_padding | px), right: ($t.apex_entry_padding | px)},
        font: {size: ($t.apex_font_entry_size | px), weight: ($t.apex_font_entry_weight | tonumber)},
        focus: {boxShadow: {inset: true, spread: ($t.apex_entry_focus_ring | px), color: "#3584e4ff"}}},
    buttons: [$button + {default: false, background: ($t.apex_button | hex), foreground: ($t.apex_fg | hex), hover: {background: ($t.apex_button_hover | hex)}},
        $button + {default: true, background: "#2863abff", foreground: "#ffffffff"}]}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_A_DATE_MENU_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b | {top: $b, right: $b, bottom: $b, left: $b} as $border
| def inset($top; $right; $bottom; $left): {top: ($top - $b), right: ($right - $b), bottom: ($bottom - $b), left: ($left - $b)};
($t.apex_quick_settings_padding | px) as $qp | ($t.apex_calendar_padding | px) as $cp
| ($t.apex_message_padding | px) as $mp | ($t.apex_events_padding | px) as $ep
| {size: ($t.apex_font_size | px), weight: ($t.apex_font_heading_weight | tonumber)} as $heading
| {x: 0, y: 0, height: ($t.apex_date_menu_button_height | px), background: ($t.apex_glass_card | hex), borderColor: ($t.apex_glass_card_border | hex),
    border: $border, radius: ($t.apex_radius_date_menu_button | px)} as $row
| {x: ($t.apex_date_menu_button_padding | px), y: 12, foreground: ($t.apex_fg_dim | hex),
    font: {size: ($t.apex_font_events_title_size | px), weight: ($t.apex_font_label_weight | tonumber)}} as $rowHeader
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
        ink: ($t.apex_fg | hex), font: {size: ($t.apex_font_calendar_day_size | px)}},
    weekend: {foreground: ($t.apex_fg | hex), ink: ($t.apex_fg | hex)},
    otherMonth: {foreground: ($t.apex_calendar_other_month | hex), ink: ($t.apex_calendar_other_month | hex)},
    today: {background: "#2863abff", foreground: "#ffffffff", ink: "#ffffffff", font: {weight: ($t.apex_font_heading_weight | tonumber)}},
    events: {y: 0, height: 62, background: ($t.apex_glass_card | hex), radius: ($t.apex_radius_calendar | px), border: $border,
        padding: inset(($t.apex_events_padding_top | px); $ep; ($t.apex_events_padding_bottom | px); $ep)},
    eventsTitle: {font: {size: ($t.apex_font_events_title_size | px), weight: ($t.apex_font_heading_weight | tonumber)}, foreground: ($t.apex_fg_dim | hex)},
    clocks: ($row + {y: (62 + ($t.apex_date_menu_column_gap | px))}),
    weather: ($row + {y: (62 + ($t.apex_date_menu_column_gap | px) + ($t.apex_date_menu_button_height | px) + ($t.apex_date_menu_button_gap | px))}),
    clocksHeader: $rowHeader, weatherHeader: $rowHeader}}}'
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
{shown: true, box: [0, 0, 290, 250], surfaceBox: [0, 0, 290, 250], natural: [290, 250], radius: ($t.apex_radius_window_preview | px),
    boxShadow: {color: ($t.apex_preview_shadow | hex), inset: false, x: 0,
    y: ($t.apex_preview_shadow_y | px), blur: ($t.apex_preview_shadow_blur | px), spread: 0}} as $layer
| {styled: true, radius: ($t.apex_radius_window_preview | px), layers: [$layer, ($layer | .boxShadow |= (.color = ($t.apex_preview_shadow_2 | hex)
    | .y = ($t.apex_preview_shadow_2_y | px) | .blur = ($t.apex_preview_shadow_2_blur | px)))]} as $preview
| {topBar: {panel: {width: 1440}}, scenes: {overview: {workArea: {y: 32, height: 868}}}, surfaces: {
    overviewLayer: {titleVisible: true, thumbnailsThreshold: 1, thumbnails: {maxScale: 0.081, first: {width: 117, height: 70}},
        workspace: {x: 250, y: 205, width: 939, height: 566, background: false,
            empty: {x: 644, y: 477, width: 150, height: 22, visible: true, text: "No open windows", foreground: ($t.apex_overview_fg_dim | hex),
                font: {size: ($t.apex_font_workspace_empty_size | px), weight: ($t.apex_font_heading_weight | tonumber)}}}},
    overviewWindows: {dock: {x: 540, y: (804 + ($t.apex_dock_bottom_gap | px)), width: 361, height: 70},
        dockBox: {x: 540, y: 820, width: 361, height: 80}, bottom: {stock: 900, hook: (900 - 80 - ($t.apex_dock_bottom_gap | px))},
        previews: [
            $preview + {window: {x: 561, y: 198, width: 317, height: 236}, caption: {x: 602, y: 459, width: 235, height: 29, visible: true}},
            $preview + {window: {x: 414, y: 500, width: 290, height: 250}, caption: {x: 520, y: 775, width: 78, height: 29, visible: true}},
            $preview + {window: {x: 736, y: 500, width: 290, height: 250}, caption: {x: 842, y: 775, width: 78, height: 29, visible: true}}],
        thumbnails: [{x: 597, y: 108, width: 117, height: 70, spread: 0.42}, {x: 724, y: 108, width: 117, height: 70, spread: 0.31}]},
    appGrid: {grid: {columns: 7, rows: 4, iconSize: 88}, strip: 0, box: {y: 132}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_SURFACE_METRICS_FROM_TOKENS='
($t.apex_message_padding | px) as $pad | ($t.apex_message_icon_size | px) as $icon | ($t.apex_banner_close_size | px) as $close
| ($t.apex_date_menu_footer_padding | px) as $fpad | ($t.apex_clear_button_height | px) as $clear | ($t.apex_thumbnail_indicator | px) as $r
| {x: 354, y: 52, width: 400, height: 87} as $card | (354 + ($t.apex_message_padding_start | px)) as $ix
| {x: 354, y: 537, width: 400, height: ($t.apex_date_menu_footer_height | px)} as $footer
| {x: 599, y: 108, width: 116, height: 70, boxShadow: null} as $thumb
| {topBar: {panel: {width: 1440, height: 32}}, surfaces: {
    notificationsLayer: {layout: {collapsed: {card: $card, icon: {x: $ix, y: (52 + $pad), width: $icon, height: $icon},
            header: {x: ($ix + $icon + ($t.apex_banner_gap | px)), y: 67, width: 271, height: 19},
            close: {x: (754 - ($t.apex_message_padding_end | px) - $close), y: (52 + $pad), width: $close, height: $close}}},
        footer: $footer, dnd: {x: (354 + $fpad), y: 537, width: 149, height: 40, labelBox: {x: (354 + $fpad), y: 548, width: 91, height: 18},
            switch: {x: (354 + $fpad + 91 + ($t.apex_dnd_switch_gap | px)), y: 544, width: 46, height: 26}},
        clear: {x: (754 - $fpad - 65), y: ($footer.y + ($footer.height - $clear) / 2), width: 65, height: $clear}},
    overview: {thumbnail: $thumb, indicator: {x: (599 - $r), y: (108 - $r), width: (116 + 2 * $r), height: (70 + 2 * $r), boxShadow: null}},
    overviewWindows: {thumbnails: [$thumb, ($thumb | .x += 116 + ($t.apex_thumbnail_gap | px))],
        previews: [{window: {x: 520, y: 185, width: 399, height: 250}, caption: {x: 698, y: 460, width: 43, height: (($t.apex_caption_height | px) + 1)}},
            {window: {x: 304, y: 500, width: 399, height: 250}, caption: {x: 482, y: 775, width: 43, height: (($t.apex_caption_height | px) + 1)}}]},
    launcher: {pill: {x: (720 - ($t.apex_launcher_search_width | px) / 2), y: (32 + ($t.apex_search_top | px)),
        width: ($t.apex_launcher_search_width | px), height: ($t.apex_search_height | px)}},
    appGrid: {scrim: {background: ($t.apex_scrim | hex), boxShadow: null}, spacing: {tile: 139, h: 24, v: 22},
        tiles: [range(12) | {x: (162 + (. % 7) * 163), y: (156 + (. / 7 | floor) * 161), width: 139, height: 139}]}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_SHADOW_LAYERS_FROM_TOKENS='
{shown: true, box: [10, 20, 230, 146], surfaceBox: [10, 20, 230, 146], natural: [105, 126], radius: 0,
    boxShadow: {color: ($t.apex_shadow_2 | hex), inset: false, x: 0,
    y: ($t.apex_shadow_2_y | px), blur: ($t.apex_shadow_2_blur | px), spread: 0}} as $layer
| {surfaces: {idleRepaints: {withShadows: 3, withoutShadows: 3}, shadowLayers: {
    quickSettings: [$layer | .radius = ($t.apex_radius_quick_settings | px)], dateMenu: [$layer], popupMenu: [$layer],
    dialog: [$layer | .besideBox = true]}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_A_TILE_PREVIEW_DRAWN_FROM_TOKENS='
($t.apex_tile_preview_inset | px) as $i
| def tint($o): "rgba(53, 132, 228, \($o))" | hex;
{topBar: {accent: "#3584e4ff"}, surfaces: {tilePreview: {
    tile: {x: 0, y: 32, width: 720, height: 868},
    preview: {styleClass: "tile-preview on-primary tile-preview-left apex-tile-preview-glassed", x: 0, y: 32, width: 720, height: 868,
        border: {top: $i, right: $i, bottom: $i, left: $i}, borderColor: "#00000000",
        radius: (($t.apex_radius_tile_preview | px) + $i), background: "#00000000", boxShadow: null},
    glass: {radius: ($t.apex_radius_tile_preview | px), background: tint($t.apex_tile_preview_fill_opacity),
        border: ($t.apex_tile_preview_ring | px | {top: ., right: ., bottom: ., left: .}), borderColor: tint($t.apex_tile_preview_ring_opacity)}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_A_SCREENSHOT_UI_DRAWN_FROM_TOKENS='
($t.apex_surface_border | px) as $b | ($t.apex_screenshot_padding | px) as $pad | ($t.apex_screenshot_close_size | px) as $close
| ($t.apex_screenshot_capture_size | px) as $cap | ($cap - 2 * (($t.apex_screenshot_capture_ring | px) + ($t.apex_screenshot_capture_gap | px))) as $dot
| (900 - ($t.apex_screenshot_bottom | px) - 210) as $py | (720 - ($t.apex_screenshot_width | px) / 2) as $px
| ($t.apex_screenshot_type_height | px) as $th | ($t.apex_radius_screenshot_type | px) as $tr
| {topBar: {accent: "#3584e4ff"}, surfaces: {screenshot: {
    monitorHeight: 900,
    panel: {x: $px, y: $py, width: ($t.apex_screenshot_width | px), height: 210, background: ($t.apex_panel | hex),
        borderColor: ($t.apex_panel_border | hex), border: {top: $b, left: $b}, radius: ($t.apex_radius_screenshot | px),
        boxShadow: {color: ($t.apex_shadow | hex), y: ($t.apex_shadow_y | px), blur: ($t.apex_shadow_blur | px)},
        padding: {top: ($pad + $close + ($t.apex_screenshot_gap | px) - $b), left: ($pad - $b)}, spacing: ($t.apex_screenshot_gap | px)},
    close: {x: ($px + ($t.apex_screenshot_width | px) - $pad - ($t.apex_screenshot_close_inset | px) - $close), y: ($py + $pad),
        width: $close, height: $close, radius: 999, background: ($t.apex_button | hex), foreground: ($t.apex_fg | hex), boxShadow: null},
    types: [
        {height: $th, radius: $tr, checked: true, background: ($t.apex_button_hover | hex)},
        {height: $th, radius: $tr, checked: false, background: ($t.apex_button | hex)},
        {height: $th, radius: $tr, checked: false, background: ($t.apex_button | hex), foreground: ($t.apex_fg_faint | hex)}],
    checkedType: {background: ($t.apex_button_hover | hex)},
    typeContent: {icon: {height: ($t.apex_screenshot_type_icon_size | px)}, spacing: ($t.apex_screenshot_type_label_gap | px),
        labelFont: {size: ($t.apex_font_screenshot_type_size | px), weight: ($t.apex_font_label_weight | tonumber)}},
    pointer: {width: ($t.apex_screenshot_pointer_size | px), height: ($t.apex_screenshot_pointer_size | px), radius: 999,
        background: ($t.apex_button | hex), checked: {background: "#3584e4ff"}},
    capture: {width: $cap, height: $cap, border: {top: ($t.apex_screenshot_capture_ring | px)}, borderColor: ($t.apex_fg | hex),
        padding: {top: ($t.apex_screenshot_capture_gap | px)},
        circle: {width: $dot, radius: 999, background: ($t.apex_fg | hex)},
        cast: {margin: (($dot - ($t.apex_screenshot_record_dot | px)) / 2), radius: ($t.apex_radius_screenshot_record_dot | px),
            background: ($t.apex_screenshot_record | hex)}},
    switcher: {padding: {top: ($t.apex_screenshot_switch_padding | px)}, background: ($t.apex_button | hex),
        radius: (($t.apex_screenshot_switch_button_height | px) / 2 + ($t.apex_screenshot_switch_padding | px))},
    shot: {checked: true, width: ($t.apex_screenshot_switch_button_width | px), height: ($t.apex_screenshot_switch_button_height | px),
        background: ($t.apex_panel_solid | hex), foreground: ($t.apex_fg | hex),
        boxShadow: {y: ($t.apex_screenshot_switch_shadow_y | px), blur: ($t.apex_screenshot_switch_shadow_blur | px), color: ($t.apex_screenshot_switch_shadow | hex)}},
    shade: {background: ($t.apex_screenshot_shade | hex)},
    selection: {border: {top: ($t.apex_screenshot_selection_border | px)}, borderColor: ($t.apex_screenshot_selection | hex)},
    handle: {width: ($t.apex_screenshot_handle_size | px), height: ($t.apex_screenshot_handle_size | px), radius: 999, background: "#ffffffff",
        boxShadow: {y: ($t.apex_screenshot_handle_shadow_y | px), blur: ($t.apex_screenshot_handle_shadow_blur | px), color: ($t.apex_screenshot_handle_shadow | hex)}},
    screen: {checked: true, border: {top: ($t.apex_screenshot_frame | px)}, borderColor: "#3584e4ff", background: ($t.apex_screenshot_screen_tint | hex)},
    windowSelector: {background: ($t.apex_screenshot_shade | hex)},
    windowFrame: {border: {top: ($t.apex_screenshot_frame | px)}, borderColor: "#3584e4ff", radius: ($t.apex_radius_screenshot_window | px)}}}}'
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
        + [range(8) | $row]
        | (.[2].tile, .[3].tile, .[4].tile) = {width: $icon, radius: ($t.apex_radius_spotlight_tile | px), glyph: ($t.apex_spotlight_tile_glyph_size | px)}
        | .[2].tile += {background: "#6f8396ff", foreground: "#ffffffff"}
        | .[3].tile += {background: "#3584e4ff", foreground: "#ffffffff"}
        | .[4].tile += {background: ($t.apex_button | hex), foreground: ($t.apex_fg | hex)}),
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
        label: {text: "Copied 1920"}}},
    overviewSearch: {opened: true, text: "disk", overviewText: ""}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_A_LAUNCHER_SEARCH_FROM_TOKENS='
{surfaces: {launcher: {
    pill: {width: ($t.apex_launcher_search_width | px), hint: "Search apps"},
    found: {gridHidden: true, names: ["Files"], firstSelected: true, spotlightOpen: false,
        appDisplay: {x: 0, y: 262, width: 1440, height: 541}, results: {x: 0, y: 262, width: 1440, height: 541}},
    empty: {top: 0, padding: {top: ($t.apex_launcher_empty_top | px)}, spacing: ($t.apex_launcher_empty_gap | px),
        title: {text: "No Results", font: {size: ($t.apex_font_launcher_empty_title_size | px), weight: ($t.apex_font_heading_weight | tonumber)}, foreground: ($t.apex_fg | hex)},
        hint: {text: "The launcher searches apps only. Super+Space searches everything.", font: {size: ($t.apex_font_launcher_empty_hint_size | px)},
            foreground: ($t.apex_fg_dim | hex)}}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_LIVE_KEYS_FROM_TOKENS='
($t.apex_dock_icon_size | px) as $m | ($t.apex_dock_dot | hex) as $dot
| def shown($size; $dots; $trash): {focusedApp: {visible: true, name: "G2 maximised window"}, iconSizes: [$size, $size, $size, $size],
    kinds: (["app", "app", "separator", "show-apps"] + (if $trash then ["trash"] else [] end)), dots: [{app: "G2 maximised window", colour: $dots}]};
shown($m; $dot; true) as $stock
| {steps: {liveKeys: {
    focusedAppOff: {set: ($stock | .focusedApp.visible = false), reset: $stock},
    small: {set: shown(46; $dot; true), reset: $stock},
    large: {set: shown(62; $dot; true), reset: $stock},
    dotsOff: {set: shown($m; "#00000000"; true), reset: $stock},
    trashOff: {set: shown($m; $dot; false), reset: $stock}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_INDICATORS_DRAWN_FROM_TOKENS='
($t.apex_indicator_width | px) as $w | ($t.apex_bar_pill_height | px) as $h | ($t.apex_bar_gap | px) as $g
| ($t.apex_bar_icon_size | px) as $i | ($t.apex_radius_bar_pill | px) as $r | ($t.apex_indicator_dot_size | px) as $ds
| ($t.apex_menu_row_height | px) as $row | ($t.apex_fg_dim | hex) as $dim | ($t.apex_bar_fg | rgba) as $fg
| ["File sync", "Chat", "Game launcher", "Password manager"] as $names
| [range(4) as $k | {x: (1000 + $k * ($w + $g)), y: 4, width: $w, height: $h, radius: $r}] as $pills
| [range(4) as $k | {name: $names[$k], pill: $pills[$k],
    glyph: {x: ($pills[$k].x + ($w - $i) / 2), y: (4 + ($h - $i) / 2), width: $i, height: $i, colour: ($t.apex_bar_fg | hex),
      iconName: (if $k == 3 then null else "folder-remote-symbolic" end), mask: ($k == 3)},
    dot: null}] as $items
| ($items | .[1].dot = {x: (.[1].pill.x + $w - ($t.apex_indicator_dot_right | px) - $ds), y: (4 + ($t.apex_indicator_dot_top | px)),
    width: $ds, height: $ds, radius: ($ds / 2), colour: "#3584e4ff"}) as $items
| (($t.apex_indicators_divider_margin | px) + $g) as $around
| ($pills[3].x + $w + $around) as $dx
| {x: $dx, y: 9, width: ($t.apex_indicators_divider_width | px), height: ($t.apex_indicators_divider_height | px),
   colour: ("rgba(\($fg[0]), \($fg[1]), \($fg[2]), \($t.apex_indicators_divider_opacity))" | hex)} as $divider
| {width: ($t.apex_indicator_switch_width | px), height: ($t.apex_indicator_switch_height | px), radius: 9} as $switch
| ($t.apex_privacy_height | px) as $ph | ($t.apex_privacy_icon_size | px) as $pi | ($t.apex_privacy_padding | px) as $pp
| ($t.apex_privacy_gap | px) as $pg | ($t.apex_screen_stop_size | px) as $ss
| {x: 1240, y: 4, width: 160, height: $h, paddingLeft: ($t.apex_bar_pill_padding_privacy | px)} as $pill
| ($pill.x + $pill.paddingLeft) as $gx
| {x: $gx, y: (4 + ($h - $ph) / 2), width: (2 * $pp + 2 * $pi + $pg), height: $ph, radius: ($t.apex_radius_privacy | px),
   colour: ($t.apex_privacy | hex)} as $group
| ($group + {next: {x: ($gx + $group.width + ($t.apex_privacy_margin | px) + ($t.apex_bar_status_gap | px)), y: 8, width: $i, height: $i},
   glyphs: [range(2) as $k | {x: ($gx + $pp + $k * ($pi + $pg)), y: (4 + ($h - $pi) / 2), width: $pi, height: $pi,
     iconName: "camera-web-symbolic", colour: ($t.apex_privacy_fg | hex)}]}) as $privacy
| (1100 + ($t.apex_recording_padding_start | px)) as $sx | ($sx + $ss + ($t.apex_recording_gap | px)) as $tx
| {x: 1100, y: 4, width: ($tx + 26 + ($t.apex_recording_padding_end | px) - 1100), height: $h, radius: $r, colour: ($t.apex_recording | hex),
   stop: {x: $sx, y: (4 + ($h - $ss) / 2), width: $ss, height: $ss, radius: ($t.apex_radius_screen_stop | px), colour: ($t.apex_recording_fg | hex)},
   timer: {x: $tx, y: 8, width: 26, height: 16, text: "0:42", size: ($t.apex_font_recording_size | px),
     weight: ($t.apex_font_recording_weight | tonumber), tracking: 0, features: "tnum", colour: ($t.apex_recording_fg | hex)}} as $recording
| {pill: {x: 1190, y: 4, width: ($t.apex_input_chip_min_width | px), height: $h, radius: $r}, text: "EN",
   size: ($t.apex_font_input_chip_size | px), weight: ($t.apex_font_input_chip_weight | tonumber),
   tracking: (($t.apex_font_input_chip_tracking | rtrimstr("em") | num) * ($t.apex_font_input_chip_size | px)), features: "",
   colour: ($t.apex_bar_fg | hex), sources: [{type: "xkb", id: "us", stock: "en", language: null, text: "EN"},
     {type: "ibus", id: "m17n:vi:telex", stock: "Ắ₂", language: "vi_VN", text: "VI₂"}]} as $input
| ($t.apex_sharing_icon_size | px) as $si | (1240 - ($t.apex_sharing_margin | px) - $g) as $se
| ($se - ($t.apex_sharing_padding_end | px) - $ss) as $qx | ($qx - ($t.apex_sharing_gap | px) - $si) as $gx2
| ($gx2 - ($t.apex_sharing_padding_start | px)) as $sx2
| {x: $sx2, y: 4, width: ($se - $sx2), height: $h, radius: $r, colour: ($t.apex_privacy | hex), name: "Stop screen sharing",
   next: $pill, glyph: {x: $gx2, y: (4 + ($h - $si) / 2), width: $si, height: $si, iconName: "screen-shared-symbolic", colour: ($t.apex_privacy_fg | hex)},
   stop: {x: $qx, y: (4 + ($h - $ss) / 2), width: $ss, height: $ss, radius: ($t.apex_radius_screen_stop | px), colour: ($t.apex_privacy_fg | hex)}} as $sharing
| {empty: {visible: false, divider: null}, accent: "#3584e4ff",
   everything: {order: ["indicators", "divider", "apex-search", "screenRecording", "keyboard", "screenSharing", "quickSettings"], pill: $pill,
     privacy: $privacy, recording: $recording, input: $input, sharing: $sharing, search: {x: 1060, y: 4, width: 32, height: $h},
     after: {privacy: false, paddingLeft: ($t.apex_bar_pill_padding | px)}},
   four: {visible: true, order: ["indicators", "divider", "apex-search", "quickSettings"], items: $items, divider: $divider,
     search: {x: ($dx + $divider.width + $around), y: 4, width: 32, height: $h},
     mask: {colour: ($t.apex_bar_fg | hex), inkPixels: 64, redPixels: 0}},
   menu: {open: true, closed: true, content: {x: 900, y: 32, width: ($t.apex_indicator_menu_width | px), height: 260, radius: ($t.apex_radius_menu | px)},
     rows: [{kind: "PopupMenuItem", label: "Chat", header: true, height: ($t.apex_indicator_menu_header_height | px), colour: $dim},
       {kind: "PopupMenuItem", label: "Show Chat", height: $row, shortcut: {text: "Ctrl+Shift+C", colour: $dim}},
       {kind: "PopupSwitchMenuItem", label: "Do Not Disturb", height: $row, switch: ($switch + {checked: false})},
       {kind: "PopupSwitchMenuItem", label: "Start at Login", height: $row, switch: ($switch + {checked: true})},
       {kind: "PopupSeparatorMenuItem", label: "", height: 1},
       {kind: "PopupMenuItem", label: "Mute for 1 Hour", height: $row},
       {kind: "PopupSeparatorMenuItem", label: "", height: 1},
       {kind: "PopupMenuItem", label: "Quit Chat", height: $row}]},
   five: {items: $items[:3], overflow: {text: "+2", pill: {x: 1096, y: 4, width: 40, height: $h, radius: $r}}},
   overflowMenu: {open: true, content: {x: 900, y: 32, width: ($t.apex_indicators_overflow_menu_width | px), height: 80, radius: ($t.apex_radius_menu | px)},
     rows: [{label: "Password manager", height: $row, glyph: $i, chevron: "go-next-symbolic"},
       {label: "Media player", height: $row, glyph: $i, chevron: "go-next-symbolic"}]},
   gone: {visible: false, divider: null},
   log: ["File sync registered", "Chat registered", "Chat Event 0 opened", "Chat Event 5 clicked", "Chat Event 0 closed",
     "File sync Activate 1215 32"]}'

# shellcheck disable=SC2016 # a jq program
REPORT_OF_SPOTLIGHT_GLASS_FROM_TOKENS='
def glass($b; $s): {blur: ($b | px), saturation: ($s | rtrimstr("%") | tonumber / 100),
    effect: {radius: (2 * ($b | px) * 2 | round), saturation: ($s | rtrimstr("%") | tonumber / 100), enabled: true}};
{monitorScale: 2, surfaces: {spotlight: {glass: {
    panelBeforeCopy: glass($t.apex_spotlight_blur; $t.apex_spotlight_saturation),
    toast: glass($t.apex_toast_blur; $t.apex_toast_saturation)}}}}'
# shellcheck disable=SC2016 # a jq program
REPORT_OF_SPOTLIGHT_KEYS='
{surfaces: {spotlightKeys: {budgetMs: 1000, slowMs: 1600, modalBefore: 0, modalOpen: 1,
    early: {ms: 301, sections: ["APPLICATIONS", "FILES"], rows: 6, selected: "Applications/org.gnome.DiskUtility.desktop"},
    late: {ms: 1201, sections: ["APPLICATIONS", "FILES"], rows: 6, selected: "Applications/org.gnome.DiskUtility.desktop"},
    settings: {askedMs: 52, cancelledMs: 1053},
    down4: "Files/images", up1: "Files/png", down20: "Files/md",
    enter: {open: false, modal: 0, activated: [{provider: "org.gnome.Nautilus.desktop", id: "md", terms: ["disk"]}]},
    escape: {open: false, modal: 0}}}}'
# shellcheck disable=SC2016 # a jq program
HEX_DEF='def hex: rgba | map([., 16] | "0123456789abcdef"[(.[0] / .[1] | floor):(.[0] / .[1] | floor) + 1]
                                    + "0123456789abcdef"[(.[0] % .[1]):(.[0] % .[1]) + 1]) | "#" + join("");'

# shellcheck disable=SC2016 # jq programs
GAP_CLOSERS='the clock gap|.topBar.clockTextGap = 8
the clock pill without the pad|.topBar.withDot.pillWidth -= ($t.apex_bar_clock_gap | px) + ($t.apex_bar_clock_dot_size | px)
the raw accent dot|.topBar.withDot.dot.background = .topBar.accent'

assert_run() {
    local assertions=$1 variant=$2 change=${3:-.} tokens report=$REPORT_OF_A_BAR_DRAWN_FROM_TOKENS prefix=APEXG2-SCENES
    [[ $assertions == shell_surfaces ]] && report=$REPORT_OF_SURFACES_DRAWN_FROM_TOKENS
    [[ $assertions == quick_settings ]] && report=$REPORT_OF_QUICK_SETTINGS_DRAWN_FROM_TOKENS
    [[ $assertions == window_switcher ]] && report=$REPORT_OF_A_SWITCHER_DRAWN_FROM_TOKENS
    [[ $assertions == modal_dialog ]] && report=$REPORT_OF_A_DIALOG_DRAWN_FROM_TOKENS
    [[ $assertions == date_menu ]] && report=$REPORT_OF_A_DATE_MENU_DRAWN_FROM_TOKENS
    [[ $assertions == overview_style ]] && report=$REPORT_OF_AN_OVERVIEW_DRAWN_FROM_TOKENS
    [[ $assertions == app_grid ]] && report=$REPORT_OF_A_LAUNCHER_DRAWN_FROM_TOKENS
    [[ $assertions == derived_surfaces ]] && report=$REPORT_OF_DERIVED_SURFACES_DRAWN_FROM_TOKENS
    [[ $assertions == tile_preview ]] && report=$REPORT_OF_A_TILE_PREVIEW_DRAWN_FROM_TOKENS
    [[ $assertions == screenshot_ui ]] && report=$REPORT_OF_A_SCREENSHOT_UI_DRAWN_FROM_TOKENS
    [[ $assertions == overview_layer ]] && report=$REPORT_OF_AN_OVERVIEW_LAYER_FROM_TOKENS
    [[ $assertions == spotlight_style ]] && report=$REPORT_OF_A_SPOTLIGHT_DRAWN_FROM_TOKENS
    [[ $assertions == launcher_search ]] && report=$REPORT_OF_A_LAUNCHER_SEARCH_FROM_TOKENS
    [[ $assertions == surface_metrics ]] && report=$REPORT_OF_SURFACE_METRICS_FROM_TOKENS
    [[ $assertions == spotlight_glass ]] && report=$REPORT_OF_SPOTLIGHT_GLASS_FROM_TOKENS
    [[ $assertions == spotlight_keys ]] && report=$REPORT_OF_SPOTLIGHT_KEYS
    [[ $assertions == shadow_layers ]] && report=$REPORT_OF_SHADOW_LAYERS_FROM_TOKENS
    [[ $assertions == indicator_metrics ]] && report=$REPORT_OF_INDICATORS_DRAWN_FROM_TOKENS prefix=APEXG2-INDICATORS
    [[ $assertions == dock_live_keys ]] && report=$REPORT_OF_LIVE_KEYS_FROM_TOKENS prefix=APEXG2-DOCK
    tokens=$(tokens_for "$variant")
    jq -nc --argjson t "$tokens" "$JQ_DEFS $HEX_DEF $report | $change" | sed "s/^/$prefix /" >"$T/top-bar.log"
    # shellcheck disable=SC2016 # expanded by the inner bash
    bash -c '. "$1/assert.sh"; "$2" case "$3" "$4" >"$5" 2>&1; summary >>"$5"; echo "$npass $nfail $ngap"' \
        _ "$HERE" "$assertions" "$T/top-bar.log" "$variant" "$T/top-bar.out"
}

# shellcheck disable=SC2016 # a jq program
REPORT_OF_LEGIBLE_SURFACES='
{kind: "text", name: "Label", alpha: 1, inactive: false, offscreen: false, ratio: 7, ellipsized: false, expandable: false, card: 0,
    box: {x: 10, y: 10, width: 60, height: 20}} as $text
| ($text + {kind: "icon", name: "glyph-symbolic", ratio: 4, box: {x: 80, y: 10, width: 16, height: 16}}) as $icon
| ($text + {kind: "dot", name: "workspace-dot", ratio: 16, box: {x: 100, y: 10, width: 6, height: 6}}) as $dot
| ($dot + {alpha: 0.447, ratio: $inactive}) as $inactiveDot
| {box: {x: 0, y: 0, width: 200, height: 100}, targets: [$text, $icon]} as $s
| {fill: "#c01c28", bar: "#f3f3f5", ratio: 5.2} as $edge
| {textScalingFactor: 1.25, monitor: {x: 0, y: 0, width: 1440, height: 900},
    quickSettingsAccents: (["blue", "teal", "green", "yellow", "orange", "red", "pink", "purple", "slate"] | map({key: ., value: $s}) | from_entries),
    dateMenuAccents: (["blue", "teal", "green", "yellow", "orange", "red", "pink", "purple", "slate"] | map({key: ., value: $s}) | from_entries),
    dialogAccents: (["blue", "teal", "green", "yellow", "orange", "red", "pink", "purple", "slate"] | map({key: ., value: $s}) | from_entries),
    screenshot: $s,

    bar: ($s | .targets += [$dot, $inactiveDot]), barUnread: ($s | .targets += [$dot + {name: "messages-indicator"}, $inactiveDot]), dock: $s, popupMenu: $s, osd: $s, banner: $s, quickSettings: $s, wifiMenu: $s, wifiMenuConnected: $s, dateMenu: $s, switcher: $s,
    dialog: $s, endSession: $s, spotlight: {popup: $s, toast: $s}, overview: $s, appGrid: $s,
    barPills: {box: $s.box, pills: {input: {targets: [$text + {name: "EN"}], edge: null},
        recording: {targets: [$text + {name: "0:42", ink: "#ffffff", backdrop: "#c01c28", ratio: 5.6}], edge: $edge},
        sharing: {targets: [$icon + {name: "screen-shared-symbolic"}], edge: $edge}, privacy: {targets: [$icon, $icon], edge: $edge},
        overflow: {targets: [$text + {name: "+1"}], edge: null}}
        + ([range(4)] | map({key: "indicator\(.)", value: {targets: [$icon + {name: "Chat"}], edge: null}}) | from_entries),
        crowded: $s, indicatorMenu: $s}}'

# The label picks the backdrop: dark-style's inactive dot passes 3:1 today, default's is the gap.
a11y_run() {
    local assertions=$1 change=${2:-.} label=${3:-dark-style} inactive=${4:-4.24}
    jq -nc --argjson inactive "$inactive" "$REPORT_OF_LEGIBLE_SURFACES | $change" | sed 's/^/APEXG2-A11Y /' >"$T/a11y.log"
    # shellcheck disable=SC2016 # expanded by the inner bash
    bash -c '. "$1/assert.sh"; "$2" "$3" "$4" >"$5" 2>&1; summary >>"$5"; echo "$npass $nfail $ngap"' \
        _ "$HERE" "$assertions" "$label" "$T/a11y.log" "$T/a11y.out"
}

# default's inactive dot is Apex's known gap: pinned at 2.86:1, and failing once it reaches 3:1.
test_inactive_dot_gap() {
    local want_failures want_gaps inactive what passes failures open_gaps
    while IFS='|' read -r want_failures want_gaps inactive what; do
        read -r passes failures open_gaps <<<"$(a11y_run a11y_contrast . default "$inactive")"
        if ((failures == want_failures && open_gaps == want_gaps)); then
            ok "inactive dot gap: $what fails $want_failures, $want_gaps gap(s)"
        else
            not_ok "inactive dot gap: $what fails $want_failures, $want_gaps gap(s) (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/a11y.out" | paste -sd'|' -)"
        fi
    done <<'CHANGES'
0|2|2.86|default's dot at today's 2.86:1, in the bar and with the unread dot
2|2|2.85|a dot below today's 2.86:1
2|0|3|the dot at 3:1: the gap must go
CHANGES
}

# default-solid's pill fills are Apex's known gaps: pinned at today's ratios, and failing once one reaches 3:1.
test_pill_gaps() {
    local want_failures want_gaps sharing what passes failures open_gaps edges
    while IFS='|' read -r want_failures want_gaps sharing what; do
        edges=".barPills.pills.recording.edge.ratio = 2.02 | .barPills.pills.sharing.edge.ratio = $sharing | .barPills.pills.privacy.edge.ratio = 1.62"
        read -r passes failures open_gaps <<<"$(a11y_run a11y_contrast "$edges" default-solid 2.22)"
        if ((failures == want_failures && open_gaps == want_gaps)); then
            ok "pill gaps: $what fails $want_failures, $want_gaps gap(s)"
        else
            not_ok "pill gaps: $what fails $want_failures, $want_gaps gap(s) (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/a11y.out" | paste -sd'|' -)"
        fi
    done <<'CHANGES'
0|5|1.62|default-solid's three pill fills at today's ratios, beside its two inactive-dot gaps
1|5|1.61|the sharing pill's fill below today's 1.62:1
1|4|3|the sharing pill's fill at 3:1: its gap must go
CHANGES
}

test_a11y() {
    local assertions expected change what passes failures open_gaps want
    for assertions in a11y_contrast:59 a11y_layout:48; do
        expected=${assertions#*:}
        read -r passes failures open_gaps <<<"$(a11y_run "${assertions%:*}")"
        if ((failures == 0 && open_gaps == 0 && passes == expected)); then
            ok "accessibility (${assertions%:*}): legible surfaces pass all $passes assertions"
        else
            not_ok "accessibility (${assertions%:*}): legible surfaces pass (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/a11y.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r assertions want change what; do
        read -r passes failures open_gaps <<<"$(a11y_run "$assertions" "$change")"
        if ((failures == want)); then
            ok "accessibility: $what fails $want assertion(s)"
        else
            not_ok "accessibility: $what fails $want assertion(s) (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
a11y_contrast|1|.bar.targets[0].ratio = 4.4|text at 4.4:1
a11y_contrast|1|.dock.targets[1].ratio = 2.9|a glyph at 2.9:1
a11y_contrast|2|.bar.targets[3].ratio = 2.9|an inactive workspace dot at 2.9:1, under 3:1 and dark-style's 4.24:1
a11y_contrast|1|.bar.targets[3].ratio = 4.2|an inactive workspace dot at 4.2:1, under dark-style's 4.24:1
a11y_contrast|1|.barUnread.targets[2].ratio = 2.9|the clock's unread dot at 2.9:1
a11y_contrast|2|.bar.targets = .bar.targets[:3]|no inactive workspace dot measured
a11y_contrast|1|.barUnread.targets = .barUnread.targets[:2] + .barUnread.targets[3:]|no unread dot measured
a11y_contrast|0|.barUnread.targets[2] += {kind: "icon", name: "message-indicator-symbolic"}|high contrast's unread glyph in place of the dot
a11y_contrast|1|.barPills.pills.recording.targets[0] += {ink: "#c01c28", ratio: 1}|the timer's text in the recording pill's own fill colour
a11y_contrast|1|.barPills.pills.input.targets[0].ratio = 4.4|the input chip's text at 4.4:1
a11y_contrast|1|.barPills.pills.privacy.targets[1].ratio = 2.9|a privacy glyph at 2.9:1 over its fill
a11y_contrast|1|.barPills.pills.sharing.edge.ratio = 2.9|the sharing pill's fill at 2.9:1 against the bar
a11y_contrast|2|.barPills.pills.privacy = {error: "not shown"}|a pill that never showed
a11y_contrast|10|del(.barPills)|no pills, app indicators or app menu measured
a11y_contrast|0|.barPills.pills.recording.targets[0].ratio = 4.5|the timer's text at 4.5:1
a11y_contrast|1|.barPills.pills.indicator2.targets[0] += {ink: "#16161a", ratio: 1}|an app indicator's glyph drawn in the bar's own colour
a11y_contrast|1|.barPills.pills.overflow.targets[0].ratio = 4.4|the overflow's +1 at 4.4:1
a11y_contrast|1|.barPills.indicatorMenu.targets[0].ratio = 3|the Chat app's menu text at 3:1
a11y_contrast|2|del(.barPills.pills.overflow, .barPills.pills.indicator0, .barPills.pills.indicator1, .barPills.pills.indicator2, .barPills.pills.indicator3)|no app indicators shown
a11y_contrast|1|.wifiMenu.targets[0].ratio = 3|a menu row's text at 3:1
a11y_contrast|1|.wifiMenuConnected.targets[0].ratio = 4.4|the connected network's name at 4.4:1 over its fill
a11y_contrast|1|.wifiMenuConnected.targets |= map(. + {kind: "icon"})|a connected row with only its glyphs measured
a11y_contrast|1|.spotlight.toast.targets[0].ratio = 3|the toast's text at 3:1
a11y_contrast|1|.quickSettingsAccents.yellow.targets[0].ratio = 4.49|a checked toggle on the yellow accent at 4.49:1
a11y_contrast|1|del(.quickSettingsAccents.slate)|an accent left unmeasured
a11y_contrast|1|.dateMenuAccents.orange.targets[0].ratio = 4.3|today on the orange accent at 4.3:1
a11y_contrast|1|.dialogAccents.yellow.targets[0].ratio = 3.01|a default button on the raw yellow accent at 3.01:1
a11y_contrast|1|.screenshot.targets[0].ratio = 2.5|a screenshot type label at 2.5:1
a11y_contrast|1|.dateMenu.targets[0] += {bare: true, ratio: 1.2}|a bare Clutter.Text, a day number St never styled, at 1.2:1
a11y_contrast|1|.endSession.targets[1].ratio = 2|the end-session glyph at 2:1
a11y_contrast|1|.banner = {error: "not shown"}|a surface that never showed
a11y_contrast|1|.popupMenu.targets = []|a surface with nothing measured
a11y_contrast|0|.osd.targets[0] += {inactive: true, ratio: 1}|a disabled control's text
a11y_contrast|0|.dateMenu.targets[0] += {offscreen: true, ratio: null}|another workspace's label
a11y_layout|1|.bar.targets[0].ellipsized = true|text cut short
a11y_layout|1|.dock.targets[0].box.x = 1430|text over the screen's edge
a11y_layout|1|.osd.targets[0].box.y = 95|text leaving its surface
a11y_layout|1|.quickSettings.targets += [.quickSettings.targets[0] + {name: "Other"} + {box: {x: 20, y: 10, width: 60, height: 20}}]|overlapping text
a11y_layout|1|.barPills.crowded.targets += [.barPills.crowded.targets[0] + {name: "EN"} + {box: {x: 30, y: 12, width: 40, height: 18}}]|the input chip over the timer on the crowded bar
a11y_layout|1|.barPills.crowded.targets[0].ellipsized = true|a crowded bar's text cut short
a11y_layout|1|.barPills.indicatorMenu.targets[0].box.x = 1430|the app menu's text over the screen's edge
a11y_layout|1|.textScalingFactor = 1|text at its default size
a11y_layout|0|.dateMenu.targets += [.dateMenu.targets[0] + {card: 1} + {box: {x: 20, y: 14, width: 60, height: 20}}]|a stacked card's text
a11y_layout|0|.banner.targets[0] += {ellipsized: true, expandable: true}|a collapsed notification's body
CHANGES
}

# signoff.sh's last step on stand-in captures: each board's two scenes, then one gone.
write_golden_fixtures() {
    local dir=$1
    mkdir -p "$dir"
    cat >"$T/golden-make.js" <<EOF
import GLib from 'gi://GLib';
import * as Png from 'file://$HERE/png.js';

function image(shade, moved = false) {
    const rgba = new Uint8Array(40 * 30 * 4).fill(shade);
    if (moved) {
        for (let y = 10; y < 14; y++)
            rgba.fill(7, (y * 40 + 20) * 4, (y * 40 + 26) * 4);
    }
    return {width: 40, height: 30, rgba};
}
const write = (name, img) => GLib.file_set_contents('$dir/' + name, Png.encode(img));
write('board-14-end-session-light.png', image(230));
write('board-14-end-session-dark.png', image(30));
write('board-36-launcher-light.png', image(220));
write('board-36-launcher-dark.png', image(40));
write('moved-dark.png', image(40, true));
EOF
    gjs -m "$T/golden-make.js"
    jq -n '{commit: "c0ffee", pins: {apexGnome: "c0ffee", apexDesktop: "acde"}, scale: 2, monitor: "2880x1800",
            boards: [{board: 14, title: "End session", slug: "end-session", source: "s", fixture: "f",
                      scene: {light: "l14", dark: "d14"}, files: {light: "board-14-end-session-light.png", dark: "board-14-end-session-dark.png"}},
                     {board: 36, title: "Launcher", slug: "launcher", source: "s", fixture: "f",
                      scene: {light: "l36", dark: "d36"}, files: {light: "board-36-launcher-light.png", dark: "board-36-launcher-dark.png"}}]}' \
        >"$dir/signoff.json"
}

goldens() {
    GOLDENS_LOCK=$T/goldens.lock GOLDENS_WORK=$T/goldens-work GOLDENS_URL=$T/goldens-remote GOLDENS_MASKS=${masks:-$T/no-masks.json} \
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t "$HERE/goldens.sh" "$@" >"$T/goldens.out" 2>&1
}

test_goldens() {
    local dir=$T/goldens-signoff hash first masks='' rc
    write_golden_fixtures "$dir"
    printf '# test\nGOLDENS_REV=\n' >"$T/goldens.lock"
    echo '{"boards": {}}' >"$T/no-masks.json"
    hash=$(cat "$dir/board-36-launcher-light.png" "$dir/board-36-launcher-dark.png" | sha256sum | cut -c 1-12)
    jq -n --arg h "$hash" '{boards: {"36": {status: "approved", shots: $h, approvedAt: "2026-10-25T09:41:00Z", note: "ok"},
                                     "14": {status: "changes-requested", shots: "0123456789ab"}}}' >"$T/decisions.json"

    jq '.boards["36"].shots = "0123456789ab"' "$T/decisions.json" >"$T/stale.json"
    if ! goldens import "$dir" "$T/stale.json" && grep -q "board 36 (Launcher): approved shots 0123456789ab, but its captures hash to $hash: a stale approval" "$T/goldens.out" &&
        grep -qx 'GOLDENS_REV=' "$T/goldens.lock" && [[ ! -e $T/goldens-work ]]; then
        ok "goldens import: an approval of other captures refuses the import, named, and pins nothing"
    else
        not_ok "goldens import: an approval of other captures refuses the import, named, and pins nothing: $(tail -n 3 "$T/goldens.out")"
    fi
    jq '.boards["36"].reviewer = "x"' "$T/decisions.json" >"$T/shape.json"
    if ! goldens import "$dir" "$T/shape.json" && grep -q 'board 36: unknown field(s) reviewer' "$T/goldens.out"; then
        ok "goldens import: a decision of another shape is refused"
    else
        not_ok "goldens import: a decision of another shape is refused: $(tail -n 3 "$T/goldens.out")"
    fi

    if goldens import "$dir" "$T/decisions.json"; then
        first=$(git -C "$T/goldens-work" rev-parse HEAD)
        if grep -qx "GOLDENS_REV=$first" "$T/goldens.lock" && [[ -z $(git -C "$T/goldens-work" rev-list --parents -n 1 HEAD | cut -s -d' ' -f2) ]] &&
            [[ $(git -C "$T/goldens-work" ls-files | paste -sd' ') == 'boards/board-36-dark.png boards/board-36-light.png manifest.json' ]] &&
            jq -e --arg h "$hash" '.boards | keys == ["36"] and .["36"].shots == $h and .["36"].pins.apexDesktop == "acde"
                and .["36"].scene.dark == "d36" and .["36"].approval == {status: "approved", approvedAt: "2026-10-25T09:41:00Z", shots: $h, note: "ok"}' \
                "$T/goldens-work/manifest.json" >/dev/null; then
            ok "goldens import: the approved board with its captures' hash becomes the branch's first commit, pinned"
            git init -q --bare "$T/goldens-remote" && git -C "$T/goldens-work" push -q "$T/goldens-remote" HEAD:refs/heads/goldens
        else
            not_ok "goldens import: the approved board with its captures' hash becomes the branch's first commit, pinned: $(cat "$T/goldens.lock")"
        fi
    else
        not_ok "goldens import: the approved board with its captures' hash becomes the branch's first commit, pinned: $(tail -n 3 "$T/goldens.out")"
    fi

    if goldens check "$dir" && grep -q '^PASS captures board 36 (Launcher), light: equal' "$T/goldens.out" &&
        grep -q '^PASS captures board 36 (Launcher), dark: equal' "$T/goldens.out" &&
        grep -q '^AWAIT board 14 (End session): no approved golden, awaiting sign-off' "$T/goldens.out"; then
        ok "goldens check: the pinned golden, fetched, equals its board; a board without one awaits sign-off"
    else
        not_ok "goldens check: the pinned golden, fetched, equals its board; a board without one awaits sign-off: $(tail -n 3 "$T/goldens.out")"
    fi
    cp "$dir/board-36-launcher-dark.png" "$T/dark.png"
    cp "$dir/moved-dark.png" "$dir/board-36-launcher-dark.png"
    rc=0
    goldens check "$dir" || rc=$?
    if ((rc == 1)) && grep -q '^FAIL captures board 36 (Launcher), dark: 24 pixel(s) differ outside the masks \[\], within {"x":20,"y":10,"width":6,"height":4}' "$T/goldens.out" &&
        [[ -s $dir/goldens-diff/board-36-dark.png ]]; then
        ok "goldens check: a region that changed fails, naming the board and the region"
    else
        not_ok "goldens check: a region that changed fails, naming the board and the region (exit $rc): $(grep -m 2 FAIL "$T/goldens.out")"
    fi
    echo '{"boards": {"36": [{"name": "live", "x": 20, "y": 10, "width": 6, "height": 4, "why": "test"}]}}' >"$T/masks.json"
    if masks=$T/masks.json goldens check "$dir" && grep -q '^PASS captures board 36 (Launcher), dark: equal outside the masks \["live"\]' "$T/goldens.out"; then
        ok "goldens check: a change inside a mask passes"
    else
        not_ok "goldens check: a change inside a mask passes: $(grep -m 2 FAIL "$T/goldens.out")"
    fi
    echo '{"boards": {"36": [{"name": "most", "x": 0, "y": 0, "width": 40, "height": 20}]}}' >"$T/masks.json"
    if ! masks=$T/masks.json goldens check "$dir" && grep -q 'the masks \["most"\] cover 800 of 1200 pixels, more than 5 %' "$T/goldens.out"; then
        ok "goldens check: a mask over 5 % of a capture fails"
    else
        not_ok "goldens check: a mask over 5 % of a capture fails: $(tail -n 3 "$T/goldens.out")"
    fi
    cp "$T/dark.png" "$dir/board-36-launcher-dark.png"

    hash=$(cat "$dir/board-14-end-session-light.png" "$dir/board-14-end-session-dark.png" | sha256sum | cut -c 1-12)
    jq -n --arg h "$hash" '{boards: {"14": {status: "approved", shots: $h, approvedAt: "2026-10-26T10:00:00Z"}}}' >"$T/decisions2.json"
    if goldens import "$dir" "$T/decisions2.json" && [[ $(git -C "$T/goldens-work" rev-parse HEAD~1) == "$first" ]] &&
        jq -e '.boards | keys == ["14", "36"]' "$T/goldens-work/manifest.json" >/dev/null &&
        git -C "$T/goldens-work" push -q "$T/goldens-remote" HEAD:refs/heads/goldens && goldens check "$dir" &&
        ! grep -q AWAIT "$T/goldens.out"; then
        ok "goldens import: a later approval adds to the pinned commit, and both boards pass"
    else
        not_ok "goldens import: a later approval adds to the pinned commit, and both boards pass: $(tail -n 3 "$T/goldens.out")"
    fi
}

rows_goldens() {
    GOLDENS_LOCK=$T/rows.lock GOLDENS_WORK=$T/rows-work GOLDENS_URL=$T/no-remote GOLDENS_MASKS=$T/no-masks.json \
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t "$HERE/goldens.sh" "$@" >"$T/goldens.out" 2>&1
}

# The app boards' rows: a board of two rows, a light-only row and a shell board of one, keyed NN-SLUG.
test_goldens_rows() {
    local dir=$T/rows-signoff top fallback rc
    mkdir -p "$dir"
    cat >"$T/rows-make.js" <<EOF
import GLib from 'gi://GLib';
import * as Png from 'file://$HERE/png.js';

const image = shade => ({width: 40, height: 30, rgba: new Uint8Array(40 * 30 * 4).fill(shade)});
for (const [name, shade] of [['11-settings-apex-top-light', 210], ['11-settings-apex-top-dark', 50], ['11-settings-apex-scrolled-light', 200],
    ['11-settings-apex-scrolled-dark', 60], ['26-update-health-fallback-light', 190], ['14-end-session-light', 230], ['14-end-session-dark', 30]])
    GLib.file_set_contents('$dir/board-' + name + '.png', Png.encode(image(shade)));
EOF
    gjs -m "$T/rows-make.js"
    jq -n --arg cc tests/control-center/run.sh '
        def row($n; $slug; $title; $source; $dark): {board: $n, key: "\($n)-\($slug)", title: $title, slug: $slug, source: $source, fixture: "f",
            scene: {light: "l", dark: (if $dark then "d" else null end)},
            files: {light: "board-\($n)-\($slug)-light.png", dark: (if $dark then "board-\($n)-\($slug)-dark.png" else null end)}};
        {commit: "c0ffee", pins: {apexGnome: "c0ffee", apexDesktop: "acde"}, scale: 2, monitor: "2880x1800", sources: [$cc, "s"],
         boards: [row(14; "end-session"; "End session"; "s"; true), row(11; "settings-apex-top"; "Settings: Apex Desktop"; $cc; true),
                  row(11; "settings-apex-scrolled"; "Settings: Apex Desktop, scrolled"; $cc; true), row(26; "update-health-fallback"; "Update health failure"; $cc; false)]}' \
        >"$dir/signoff.json"
    printf '# test\nGOLDENS_REV=\n' >"$T/rows.lock"
    echo '{"boards": {}}' >"$T/no-masks.json"
    top=$(cat "$dir/board-11-settings-apex-top-light.png" "$dir/board-11-settings-apex-top-dark.png" | sha256sum | cut -c 1-12)
    fallback=$(sha256sum <"$dir/board-26-update-health-fallback-light.png" | cut -c 1-12)

    jq -n --arg h "$top" '{boards: {"11": {status: "approved", shots: $h, approvedAt: "2026-10-30T09:41:00Z"}}}' >"$T/rows-legacy.json"
    if ! rows_goldens import "$dir" "$T/rows-legacy.json" &&
        grep -q 'board 11: a number alone keys a board of one row; its rows are 11-settings-apex-top, 11-settings-apex-scrolled' "$T/goldens.out" &&
        grep -qx 'GOLDENS_REV=' "$T/rows.lock"; then
        ok "goldens import: a legacy number for a board of two rows is refused, naming its rows"
    else
        not_ok "goldens import: a legacy number for a board of two rows is refused, naming its rows: $(tail -n 3 "$T/goldens.out")"
    fi
    jq -n --arg t "$top" --arg f "$fallback" '{boards: {"11-settings-apex-top": {status: "approved", shots: $t, approvedAt: "2026-10-30T09:41:00Z"},
        "26-update-health-fallback": {status: "approved", shots: $f, approvedAt: "2026-10-30T09:42:00Z"},
        "11-settings-apex-scrolled": {status: "changes-requested", shots: "0123456789ab"}}}' >"$T/rows-decisions.json"
    if rows_goldens import "$dir" "$T/rows-decisions.json" &&
        [[ $(git -C "$T/rows-work" ls-files | paste -sd' ') == 'boards/board-11-settings-apex-top-dark.png boards/board-11-settings-apex-top-light.png boards/board-26-update-health-fallback-light.png manifest.json' ]] &&
        jq -e --arg t "$top" --arg f "$fallback" '.boards | keys == ["11-settings-apex-top", "26-update-health-fallback"]
            and .["11-settings-apex-top"].board == 11 and .["11-settings-apex-top"].shots == $t
            and (.["26-update-health-fallback"] | .shots == $f and .files == {light: "boards/board-26-update-health-fallback-light.png", dark: null})' \
            "$T/rows-work/manifest.json" >/dev/null; then
        ok "goldens import: each approved row by its key, a light-only row hashed on its light capture alone"
    else
        not_ok "goldens import: each approved row by its key, a light-only row hashed on its light capture alone: $(tail -n 3 "$T/goldens.out")"
    fi
    if rows_goldens check "$dir" "$T/rows-work" &&
        grep -q '^PASS captures board 11-settings-apex-top (Settings: Apex Desktop), dark: equal' "$T/goldens.out" &&
        grep -q '^PASS captures board 26 (Update health failure), light: equal' "$T/goldens.out" &&
        ! grep -q 'board 26 (Update health failure), dark' "$T/goldens.out" &&
        grep -q '^AWAIT board 11-settings-apex-scrolled (Settings: Apex Desktop, scrolled): no approved golden' "$T/goldens.out" &&
        grep -q '^AWAIT board 14 (End session): no approved golden' "$T/goldens.out" &&
        grep -q '^# 2 row(s) awaiting sign-off: 11-settings-apex-scrolled 14-end-session' "$T/goldens.out"; then
        ok "goldens check: the approved rows pass, a light-only one on light alone; the other rows await sign-off"
    else
        not_ok "goldens check: the approved rows pass, a light-only one on light alone; the other rows await sign-off: $(tail -n 4 "$T/goldens.out")"
    fi
    jq '.sources = ["s"] | .boards |= map(select(.source == "s"))' "$dir/signoff.json" >"$T/rows-shell.json"
    cp "$dir/signoff.json" "$T/rows-all.json" && cp "$T/rows-shell.json" "$dir/signoff.json"
    if rows_goldens check "$dir" "$T/rows-work" && ! grep -q 'no such board' "$T/goldens.out"; then
        ok "goldens check: an app's goldens are out of scope when the sign-off did not collect that app"
    else
        not_ok "goldens check: an app's goldens are out of scope when the sign-off did not collect that app: $(tail -n 3 "$T/goldens.out")"
    fi
    jq '.boards |= map(select(.board != 26))' "$T/rows-all.json" >"$dir/signoff.json"
    rc=0
    rows_goldens check "$dir" "$T/rows-work" || rc=$?
    if ((rc == 1)) && grep -q 'board 26-update-health-fallback (Update health failure): a golden, but no such board' "$T/goldens.out"; then
        ok "goldens check: a golden of a collected app with no row fails"
    else
        not_ok "goldens check: a golden of a collected app with no row fails (exit $rc): $(tail -n 3 "$T/goldens.out")"
    fi
}

test_signoff_banners() {
    local dir=$T/signoff-banners
    rm -rf "$dir" && cp -r "$1" "$dir"
    sed -i 's/"file":"default-signoff-overview.png","banner":null/"file":"default-signoff-overview.png","banner":{"source":"Calendar","title":"Calendar is ready"}/' \
        "$dir/g2/default.log"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/out" >"$T/signoff.out" 2>&1 &&
        grep -q 'board 35 (Overview), light: a banner over default-signoff-overview: {"source":"Calendar","title":"Calendar is ready"}' "$T/signoff.out" &&
        ! grep -q 'board 16' "$T/signoff.out"; then
        ok "signoff: a banner a scene did not open fails its board, named; board 16's own banner does not"
    else
        not_ok "signoff: a banner a scene did not open fails its board, named; board 16's own banner does not: $(tail -n 3 "$T/signoff.out")"
    fi
    rm -rf "$dir" && cp -r "$1" "$dir"
    sed -i 's/"file":"dark-style-quick-settings.png","banner":null/&,"live":["wifi-scan-spinner"]/' "$dir/g2/dark-style.log"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/out" >"$T/signoff.out" 2>&1 &&
        grep -q 'board 17 (Quick Settings: Wi-Fi submenu), dark: still live in dark-style-quick-settings: wifi-scan-spinner' "$T/signoff.out"; then
        ok "signoff: a capture with live content left fails its board, named"
    else
        not_ok "signoff: a capture with live content left fails its board, named: $(tail -n 3 "$T/signoff.out")"
    fi
    rm -rf "$dir" && cp -r "$1" "$dir"
    echo 'APEXLOCK {"bluetooth.list":true}' >>"$dir/shots/greeter-light.log"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/out" >"$T/signoff.out" 2>&1 &&
        grep -q 'board 12 (GDM greeter), light: the Bluetooth indicator shows in greeter-light-list' "$T/signoff.out" &&
        ! grep -q 'board 12 (GDM greeter), dark' "$T/signoff.out"; then
        ok "signoff: a shell capture whose Bluetooth indicator shows fails its board, named"
    else
        not_ok "signoff: a shell capture whose Bluetooth indicator shows fails its board, named: $(tail -n 3 "$T/signoff.out")"
    fi
    rm -rf "$dir" && cp -r "$1" "$dir"
    : >"$dir/shots/lock-dark.log"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/out" >"$T/signoff.out" 2>&1 &&
        grep -q 'board 20 (Lock screen), dark: no banner record for lock-dark-open' "$T/signoff.out"; then
        ok "signoff: a capture without a banner record fails its board"
    else
        not_ok "signoff: a capture without a banner record fails its board: $(tail -n 3 "$T/signoff.out")"
    fi
    rm -rf "$dir" && cp -r "$1" "$dir"
    sed -i '/default-signoff-alt-tab/s/"org.gnome.TextEditor.desktop","org.gnome.Calendar.desktop"/"org.gnome.Calendar.desktop","org.gnome.TextEditor.desktop"/' "$dir/g2/default.log"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/out" >"$T/signoff.out" 2>&1 &&
        grep -q 'board 15 (Window switcher), light: the switcher in default-signoff-alt-tab lists \["org.gnome.Ptyxis.desktop","org.gnome.Calendar.desktop","org.gnome.TextEditor.desktop"\], not' "$T/signoff.out" &&
        ! grep -q 'board 15 (Window switcher), dark' "$T/signoff.out"; then
        ok "signoff: a switcher in another order fails board 15, named"
    else
        not_ok "signoff: a switcher in another order fails board 15, named: $(tail -n 3 "$T/signoff.out")"
    fi
    rm -rf "$dir" && cp -r "$1" "$dir"
    sed -i '/default-signoff-alt-tab/s/,"switcher":[^]]*]//' "$dir/g2/default.log"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/out" >"$T/signoff.out" 2>&1 &&
        grep -q 'board 15 (Window switcher), light: the switcher in default-signoff-alt-tab lists null' "$T/signoff.out"; then
        ok "signoff: a switcher capture without its list fails board 15"
    else
        not_ok "signoff: a switcher capture without its list fails board 15: $(tail -n 3 "$T/signoff.out")"
    fi
    rm -rf "$dir" && cp -r "$1" "$dir"
    echo 'APEXG2-SIGNOFF {"error":"the sign-off windows brought notifications from Calendar"}' >>"$dir/g2/dark-style.log"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/out" >"$T/signoff.out" 2>&1 &&
        grep -q 'boards 15 and 35, dark-style: the sign-off windows brought notifications from Calendar' "$T/signoff.out"; then
        ok "signoff: the sign-off scene's own error fails boards 15 and 35, named"
    else
        not_ok "signoff: the sign-off scene's own error fails boards 15 and 35, named: $(tail -n 3 "$T/signoff.out")"
    fi
    rm -rf "$dir" && cp -r "$1" "$dir"
    sed -i '/^APEXG2-SESSION /s/"icon-theme":"Apex"}/"icon-theme":"Adwaita"}/' "$dir/g2/dark-style.log"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/out" >"$T/signoff.out" 2>&1 &&
        grep -q '^signoff.sh: session defaults: 13 passed, 1 failed$' "$T/signoff.out" &&
        grep -q 'dark-style: the session reads .*(icon-theme is "Adwaita", not "Apex")' "$T/signoff.out" &&
        grep -q '1 session default check(s) failed' "$T/signoff.out"; then
        ok "signoff: a session default that is not apex-desktop's fails its own check line, naming the key"
    else
        not_ok "signoff: a session default that is not apex-desktop's fails its own check line, naming the key: $(tail -n 3 "$T/signoff.out")"
    fi
}

test_signoff() {
    local dir=$T/signoff scene log variant
    rm -rf "$dir"
    mkdir -p "$dir/g2/captures" "$dir/shots"
    for scene in signoff-alt-tab surfaces quick-settings screenshot tile-preview datemenu signoff-overview launcher desktop spotlight-search; do
        printf '\x89PNG\r\n\x1a\n' >"$dir/g2/captures/default-$scene.png"
        printf '\x89PNG\r\n\x1a\n' >"$dir/g2/captures/dark-style-$scene.png"
    done
    for scene in indicators-indicators-everything indicators-dark-indicators-everything; do
        printf '\x89PNG\r\n\x1a\n' >"$dir/g2/captures/$scene.png"
    done
    for scene in greeter-%s-list polkit-%s-open end-session-%s-power-off lock-%s-open; do
        # shellcheck disable=SC2059 # the scene names carry the variant's %s
        printf '\x89PNG\r\n\x1a\n' | tee "$dir/shots/$(printf "$scene" light).png" >"$dir/shots/$(printf "$scene" dark).png"
    done
    printf 'Apex: feature panel enabled\nApex: feature dock enabled\nAPEXG2-SIGNOFF {"previews":true}\n%s\n' \
        'APEXG2 {"dock":{"items":[{"kind":"app","name":"Files"},{"kind":"separator"},{"kind":"app","name":"Bazaar"}]}}' >"$dir/g2/default.log"
    echo 'APEXG2-SIGNOFF {"previews":true}' >"$dir/g2/dark-style.late.log"
    printf 'APEXG2-SESSION %s\n' "$(jq -c . <<<"$SESSION_REPORT")" | tee -a "$dir/g2/default.log" >>"$dir/g2/dark-style.log"
    for scene in "$dir"/g2/captures/*.png; do
        scene=$(basename "$scene")
        case $scene in
            indicators-dark-*) log=indicators-dark ;;
            indicators-*) log=indicators ;;
            dark-style-*) log=dark-style ;;
            *) log=default ;;
        esac
        jq -nc --arg f "$scene" '{file: $f, banner: (if $f | test("surfaces") then {source: "Apex", title: "A banner"} else null end)}
            + if $f | test("alt-tab") then {switcher: ["org.gnome.Ptyxis.desktop", "org.gnome.TextEditor.desktop", "org.gnome.Calendar.desktop"]} else {} end' |
            sed 's/^/APEXG2-CAPTURE /' >>"$dir/g2/$log.log"
    done
    for scene in greeter-%s:list polkit-%s:open end-session-%s:power-off lock-%s:open; do
        for variant in light dark; do
            # shellcheck disable=SC2059 # the scene names carry the variant's %s
            printf 'APEXLOCK {"banner.%s":null}\n' "${scene#*:}" >>"$dir/shots/$(printf "${scene%%:*}" "$variant").log"
        done
    done
    if "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/out" >"$T/signoff.out" 2>&1 &&
        [[ $(find "$dir/out" -name 'board-*.png' | wc -l) == 30 ]] &&
        jq -e '(.boards | length) == 15 and .scale == 2 and .features == ["dock", "panel"] and (.pins.apexDesktop | length) == 40
            and .boards[0].files.dark == "board-12-greeter-dark.png" and (.apps.grid | index("gnome-maps") != null) and (.apps.grid | index("firefox") == null) and .apps.dock == ["Files", "Bazaar"]
            and .apps.notYetInImage == []
            and .apps.flatpakStandIns == [{flatpak: "org.gnome.Music", rpm: "gnome-music"},
                {flatpak: "io.github.kolunmi.Bazaar", rpm: null, standIn: "desktop entry"}]' \
            "$dir/out/signoff.json" >/dev/null; then
        ok "signoff: fifteen boards, light and dark, and signoff.json from their captures"
    else
        not_ok "signoff: fifteen boards, light and dark, and signoff.json from their captures: $(tail -n 3 "$T/signoff.out")"
    fi
    test_signoff_banners "$dir"
    test_signoff_apps "$dir"
    rm "$dir/g2/captures/dark-style-tile-preview.png"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/out2" >"$T/signoff.out" 2>&1 &&
        grep -q 'board 22 (Edge tiling), dark: no capture of dark-style-tile-preview' "$T/signoff.out"; then
        ok "signoff: a scene that did not open fails the run with its board's name"
    else
        not_ok "signoff: a scene that did not open fails the run with its board's name: $(tail -n 3 "$T/signoff.out")"
    fi
    echo 'APEXG2-SIGNOFF {"previews":false}' >"$dir/g2/dark-style.late.log"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/out3" >"$T/signoff.out" 2>&1 &&
        grep -q 'boards 15 and 35, dark-style: the sign-off windows never all showed' "$T/signoff.out"; then
        ok "signoff: sign-off windows missing from the overview fail the run"
    else
        not_ok "signoff: sign-off windows missing from the overview fail the run: $(tail -n 3 "$T/signoff.out")"
    fi
}

# The app boards' rows from their shooters' captures, collected with the shell's.
test_signoff_apps() {
    local dir=$1 app scene
    declare -A scenes=([cc]='light dark light-scrolled dark-scrolled updates-light updates-dark appearance-light appearance-dark
        power-light power-dark updates-health-failure updates-health-failure-dark updates-fallback updates-fallback-dark updates-fallback-changes'
        [files]='home-light home-dark documents-light documents-dark search-light search-dark'
        [terminal]='light dark split-light split-dark')
    for app in cc files terminal; do
        mkdir -p "$dir/$app"
        for scene in ${scenes[$app]}; do
            printf '\x89PNG\r\n\x1a\n' >"$dir/$app/$scene.png"
        done
    done
    if "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/apps" control-center="$dir/cc" nautilus="$dir/files" ptyxis="$dir/terminal" \
        >"$T/signoff.out" 2>&1 &&
        [[ $(find "$dir/apps" -name 'board-*.png' | wc -l) == 55 ]] &&
        jq -e '(.boards | length) == 28 and (.boards | map(.key) | unique | length) == 28
            and .sources == ["tests/control-center/run.sh", "tests/nautilus/shoot.sh", "tests/ptyxis/shoot.sh", "tests/shell/shoot.sh", "tests/shots/direct.sh signoff"]
            and ([.boards[] | select(.board == 11) | .key] == ["11-settings-apex-top", "11-settings-apex-scrolled"])
            and (.boards[] | select(.key == "11-settings-apex-scrolled") | .scene == {light: "light-scrolled", dark: "dark-scrolled"}
                and .files.dark == "board-11-settings-apex-scrolled-dark.png")
            and ([.boards[] | select(.board == 26) | .files.dark] == ["board-26-update-health-health-failure-dark.png", "board-26-update-health-fallback-dark.png", null])
            and (.boards[] | select(.key == "12-greeter") | .files.light == "board-12-greeter-light.png")' \
            "$dir/apps/signoff.json" >/dev/null; then
        ok "signoff: the app boards add a row per scene, keyed NN-SLUG, light and dark, beside the fifteen shell boards"
    else
        not_ok "signoff: the app boards add a row per scene, keyed NN-SLUG, light and dark, beside the fifteen shell boards: $(tail -n 3 "$T/signoff.out")"
    fi
    # A copy of signoff.sh whose fallback row has no dark capture: a row made light-only, its dark file gone too.
    mkdir -p "$T/light-only/tests/shots" "$T/light-only/tests/lib"
    cp "$HERE/../lib/pins.sh" "$T/light-only/tests/lib/"
    sed 's/|updates-fallback|updates-fallback-dark|/|updates-fallback||/' "$HERE/signoff.sh" >"$T/light-only/tests/shots/signoff.sh"
    rm "$dir/cc/updates-fallback-dark.png"
    if bash "$T/light-only/tests/shots/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/light-only" control-center="$dir/cc" >"$T/signoff.out" 2>&1 &&
        [[ -e $dir/light-only/board-26-update-health-fallback-light.png && ! -e $dir/light-only/board-26-update-health-fallback-dark.png ]] &&
        jq -e '.boards[] | select(.key == "26-update-health-fallback") | .scene.dark == null and .files.dark == null'             "$dir/light-only/signoff.json" >/dev/null; then
        ok "signoff: a row its shooter captures light only has no dark file, and null for its dark scene and file"
    else
        not_ok "signoff: a row its shooter captures light only has no dark file, and null for its dark scene and file: $(tail -n 3 "$T/signoff.out")"
    fi
    printf '\x89PNG\r\n\x1a\n' >"$dir/cc/updates-fallback-dark.png"
    rm "$dir/cc/dark-scrolled.png"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/apps2" control-center="$dir/cc" >"$T/signoff.out" 2>&1 &&
        grep -q 'board 11-settings-apex-scrolled (Settings: Apex Desktop, scrolled), dark: no capture of dark-scrolled (tests/control-center/run.sh)' "$T/signoff.out" &&
        [[ $(grep -c 'no capture' "$T/signoff.out") == 1 ]]; then
        ok "signoff: an app scene that did not open fails the run with its row's key, and app rows need no banner record"
    else
        not_ok "signoff: an app scene that did not open fails the run with its row's key, and app rows need no banner record: $(tail -n 3 "$T/signoff.out")"
    fi
    mkdir -p "$dir/symbolic"
    for scene in core status actions everywhere aliases; do
        printf '\x89PNG\r\n\x1a\n' | tee "$dir/symbolic/board-31-symbolic-$scene-light.png" >"$dir/symbolic/board-31-symbolic-$scene-dark.png"
    done
    if "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/symbolic-out" symbolic="$dir/symbolic" >"$T/signoff.out" 2>&1 &&
        [[ $(find "$dir/symbolic-out" -name 'board-31-*.png' | wc -l) == 10 ]] &&
        jq -e '(.boards | length) == 20
            and ([.boards[] | select(.board == 31) | .key] == ["31-symbolic-core", "31-symbolic-status", "31-symbolic-actions",
                "31-symbolic-everywhere", "31-symbolic-aliases"])
            and (.boards[] | select(.key == "31-symbolic-aliases") | .files == {light: "board-31-symbolic-aliases-light.png",
                dark: "board-31-symbolic-aliases-dark.png"} and .title == "Apex Symbolic: contact sheet")
            and (.sources | index("apex-desktop tools/icons/contact-sheet.sh") != null)' "$dir/symbolic-out/signoff.json" >/dev/null; then
        ok "signoff: board 31's five scenes from contact-sheet.sh's sheets, a row each, keyed 31-symbolic-SCENE"
    else
        not_ok "signoff: board 31's five scenes from contact-sheet.sh's sheets, a row each, keyed 31-symbolic-SCENE: $(tail -n 3 "$T/signoff.out")"
    fi
    rm "$dir/symbolic/board-31-symbolic-status-dark.png"
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/symbolic-out2" symbolic="$dir/symbolic" >"$T/signoff.out" 2>&1 &&
        grep -q 'board 31-symbolic-status (Apex Symbolic: contact sheet), dark: no capture of board-31-symbolic-status-dark (apex-desktop tools/icons/contact-sheet.sh)' "$T/signoff.out" &&
        [[ $(grep -c 'no capture' "$T/signoff.out") == 1 ]]; then
        ok "signoff: a scene contact-sheet.sh did not draw, a glyph of it missing, fails the run with its row's key"
    else
        not_ok "signoff: a scene contact-sheet.sh did not draw, a glyph of it missing, fails the run with its row's key: $(tail -n 3 "$T/signoff.out")"
    fi
    if ! "$HERE/signoff.sh" --collect "$dir/g2" "$dir/shots" "$dir/apps3" files="$dir/files" >"$T/signoff.out" 2>&1 &&
        grep -q 'no app source files: one of' "$T/signoff.out"; then
        ok "signoff: an unknown app source is refused"
    else
        not_ok "signoff: an unknown app source is refused: $(tail -n 3 "$T/signoff.out")"
    fi
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
        if ((failures == 0 && passes == 8)); then
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
.dock.appMenu.items -= ["Launch Using Discrete Graphics Card"]|an app menu without the discrete GPU
CHANGES
    assert_run dock_metrics light 'del(.dock)' >/dev/null
    expect_eq "dock: a report without the dock passes none" 0 "$(grep -c '^PASS' "$T/top-bar.out")"
}

test_live_keys() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run dock_live_keys "$variant")"
        if ((failures == 0 && passes == 5)); then
            ok "live keys ($variant): a dock and bar that follow the keys pass all $passes assertions"
        else
            not_ok "live keys ($variant): they pass (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run dock_live_keys light "$change")"
        if ((failures == 1)); then
            ok "live keys: $what fails one assertion"
        else
            not_ok "live keys: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.steps.liveKeys.focusedAppOff.set.focusedApp.visible = true|a focused-app name that ignores its key
.steps.liveKeys.focusedAppOff.reset.focusedApp.visible = false|a focused-app name its reset leaves hidden
.steps.liveKeys.small.set.iconSizes[0] = 54|an icon left at medium
.steps.liveKeys.large.reset.iconSizes = [62, 62, 62, 62]|large icons after the reset
.steps.liveKeys.dotsOff.set.dots[0].colour = "#1d1d21b3"|a running dot left drawn
.steps.liveKeys.dotsOff.reset.dots = []|no running dot after the reset
.steps.liveKeys.trashOff.set.kinds += ["trash"]|Trash left in
.steps.liveKeys.trashOff.reset.kinds = ["app", "app", "separator", "show-apps"]|no Trash after the reset
CHANGES
}

test_indicators() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run indicator_metrics "$variant")"
        if ((failures == 0 && passes == 31)); then
            ok "indicators ($variant): indicators drawn from the tokens pass all $passes assertions"
        else
            not_ok "indicators ($variant): indicators drawn from the tokens pass (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run indicator_metrics light "$change")"
        if ((failures == 1)); then
            ok "indicators: $what fails one assertion"
        else
            not_ok "indicators: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.empty.visible = true|indicators before any item registers
.four.order = ["divider", "indicators", "apex-search", "quickSettings"]|the divider before the indicators
.four.items[2].pill.radius = 4|a pill with a square's corners
(.four.items[2].pill.x, .four.items[2].glyph.x) += 1|a wider gap
.four.items[0].glyph.colour = "#ffffffff"|a glyph not in the bar's colour
.four.items[0].glyph.mask = true|a named icon drawn as a mask
.four.mask.redPixels = 40|a pixmap drawn in its own colours
.four.items[1].dot = null|no attention dot
.four.items[1].dot.colour = "#ff0000ff"|a dot not in the accent
.four.divider.height = 24|a divider the pill's height
.four.search.x += 4|the search button further from the divider
.menu.content.radius = 8|a menu with a row's radius
.menu.rows[0].header = false|no title header
.menu.rows[1].height = 30|a row at the header's height
.menu.rows[2].switch.width = 46|upstream's switch
.menu.rows[3].switch.checked = false|a toggle not in the app's state
.menu.rows[1].shortcut.colour = "#ffffffff"|a shortcut not dimmed
.log -= ["Chat Event 5 clicked"]|no clicked event
.log = .log[:5]|no Activate
.everything.input.sources[1].text = "Ắ₂"|an IBus chip showing its engine's symbol
.everything.input.sources[0].text = "en"|an xkb chip in lower case
.five.overflow.text = "+1"|the wrong overflow count
.overflowMenu.rows[1].chevron = null|a row without its chevron
.gone.visible = true|indicators left after the apps quit
.everything.order = ["indicators", "divider", "screenRecording", "keyboard", "screenSharing", "apex-search", "quickSettings"]|the search button after the stock items
.everything.order = ["indicators", "divider", "apex-search", "screenRecording", "screenSharing", "keyboard", "quickSettings"]|the sharing pill before the input chip
.everything.sharing.name = "Stop Screen Sharing"|the sharing pill under stock's name
.everything.sharing.stop.radius = 4|a sharing stop dot instead of a square
.everything.privacy.colour = "#c01c28ff"|a privacy group in the recording's red
.everything.pill.paddingLeft = 10|the pill's stock start beside the group
.everything.privacy.glyphs[0].colour = "#c64600ff"|a privacy glyph in the group's orange
.everything.privacy.next.x += 4|the next status glyph further from the group
.everything.after.privacy = true|a privacy group left once nothing is in use
.everything.recording.radius = 4|a recording pill with a square's corners
.everything.recording.stop.radius = 4|a stop dot instead of a square
.everything.recording.timer.features = ""|a timer in proportional figures
.everything.input.text = "en"|the source's short name in lower case
.everything.input.tracking = 0|an untracked input chip
.everything.input.pill.width = 24|an input chip under the board's minimum width
CHANGES
    assert_run indicator_metrics light 'del(.four, .menu, .five, .overflowMenu, .gone, .empty, .log, .everything)' >/dev/null
    expect_eq "indicators: a report without them passes none" 0 "$(grep -c '^PASS' "$T/top-bar.out")"
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
.surfaces.popupMenu.rows[1].checked.background = "#00000a11"|the connected network's fill leaking into other menus
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
.surfaces.quickSettings.wifiMenu.rowHover.background = "#00000a1f"|board 16's stronger popup-menu hover
.surfaces.quickSettings.wifiMenu.connected.background = "#00000000"|upstream's unfilled connected row
.surfaces.quickSettings.wifiMenu.connected.label.font.weight = 400|a connected row at the others' weight
.surfaces.quickSettings.wifiMenu.connected.hover.background = "#00000a09"|the plain rows' faint hover on the connected row
.surfaces.quickSettings.wifiMenu.other.background = "#00000a11"|every row filled as if connected
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
        if ((failures == 0 && open_gaps == 0 && passes == 17)); then
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
.surfaces.dialog.endSession.box.width = 384|upstream's 24em end-session dialog
.surfaces.dialog.endSession.contentSpacing = 18|the plain dialog gap in the end-session dialog
.surfaces.dialog.endSession.title.tracking = 0|an untracked end-session title
.surfaces.dialog.endSession.description.font.features = null|a countdown in proportional figures
.surfaces.dialog.endSession.buttons[2].background = "#ebebedff"|a plain Power Off button
.surfaces.dialog.endSession.buttons[2].hover.background = "#c01c28ff"|a Power Off button without hover feedback
.surfaces.dialog.endSession.buttons[1].background = "#c01c28ff"|a red Restart in the power-off dialog
.surfaces.dialog.endSession.icon = null|no icon above the title
.surfaces.dialog.endSession.icon.glyph = 16|stock's 16 px symbolic glyph in the circle
del(.surfaces.dialog.endSession.buttons[1])|stock's row, without Restart
.surfaces.dialog.endSession.rowSpacing = 12|dialog.js's 12 px between the buttons
.surfaces.dialog.endSession.buttons[1].width = 128|an even row
.surfaces.dialog.entry.focus.boxShadow.color = "#3584e4cc"|upstream's 80 % focus ring
.surfaces.dialog.buttons[0].radius = 12|upstream's square-ish buttons
.surfaces.dialog.buttons[1].background = "#00000a10"|a default button without the accent
.surfaces.dialog.buttons[1].background = "#3584e4ff"|a default button on the raw accent, 3.8:1 under white
.surfaces.dialog.updateCard.staged.icon.size = 16|a symbolic-sized update icon
.surfaces.dialog.updateCard.staged.below = false|the card above the dialog's text
.surfaces.dialog.updateCard.staged.radius = 18|a card at the menus' radius
.surfaces.dialog.updateCard.staged.subtitle.text = "45.20261010.133"|a subtitle without the versions
.surfaces.dialog.updateCard.staged.title.foreground = "#1d1d219e"|a dimmed title
.surfaces.dialog.updateCard.staged.toggle.on = false|the switch off by default
.surfaces.dialog.updateCard.staged.buttons = ["Cancel", "Restart"]|Restart not relabelled while the switch is on
.surfaces.dialog.updateCard.ready.toggle.sensitive = true|a ready-for-reboot switch that turns off
.surfaces.dialog.updateCard.ready.toggle.opacity = 1|a ready-for-reboot switch drawn like an active one
.surfaces.dialog.updateCard.ready.toggle.focusable = true|a ready-for-reboot switch that takes focus
.surfaces.dialog.updateCard.ready.toggle.a11ySensitive = true|a ready-for-reboot switch announced as available
CHANGES
}

test_date_menu() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run date_menu "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 16)); then
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
.surfaces.dateMenu.day.ink = "#000000ff"|day numbers left in Clutter's default black
.surfaces.dateMenu.otherMonth.ink = "#1d1d21ff"|other months' numbers not dimmed
.surfaces.dateMenu.otherMonth.foreground = "#1d1d2166"|other months at $apex_fg_faint, 2.4:1 on the card
.surfaces.dateMenu.today.background = "#3584e4ff"|today on the raw accent, 3.8:1 under white
.surfaces.dateMenu.eventsTitle.foreground = "#1d1d21ff"|an events title at full strength
.surfaces.dateMenu.weather.height = 66|upstream's padded card around a 40 px minimum
.surfaces.dateMenu.weatherHeader.x = 12|upstream's 12 px card padding
.surfaces.dateMenu.weather.radius = 18|a row at the calendar's 18 px radius
.surfaces.dateMenu.weather.y -= 2|upstream's 6 px between the rows
.surfaces.dateMenu.clocksHeader.font.weight = 700|upstream's bold heading
.surfaces.dateMenu.weatherHeader.foreground = "#1d1d21ff"|upstream's full-strength header with no location
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
  empty: {placeholder: true, clearVisible: true, clearReactive: false},
  calendar: {label: {x: 8, y: 60, width: 90, height: 20}, back: {x: 230, y: 56, width: 32, height: 32},
    forward: {x: 266, y: 56, width: 32, height: 32}, days: 2, dots: [{x: 20, y: 120, width: 4, height: 4}, {x: 60, y: 120, width: 4, height: 4}]},
  trees: [range(3) | "box[apex-message-row[message-icon,box[message-header,message-box[message-content,box]]],message-action-bin]"],
  layout: {collapsed: {card: {x: 0, y: 0, width: 400, height: 80}, icon: {x: 14, y: 12, width: 32, height: 32},
      header: {x: 58, y: 12, width: 280, height: 16}, title: {x: 58, y: 30, width: 200, height: 20},
      close: {x: 362, y: 10, width: 24, height: 24}, actions: null},
    expanded: {card: {x: 0, y: 0, width: 400, height: 124}, icon: {x: 14, y: 12, width: 32, height: 32},
      header: {x: 58, y: 12, width: 280, height: 16}, title: {x: 58, y: 30, width: 200, height: 20},
      close: {x: 362, y: 10, width: 24, height: 24}, actions: {x: 14, y: 80, width: 376, height: 32},
      tree: "box[apex-message-row[message-icon,box[message-header,message-box[message-content,box]]],message-action-bin]"},
    collapsedAgain: {card: {x: 0, y: 0, width: 400, height: 80}, icon: {x: 14, y: 12, width: 32, height: 32},
      header: {x: 58, y: 12, width: 280, height: 16}, title: {x: 58, y: 30, width: 200, height: 20},
      close: {x: 362, y: 10, width: 24, height: 24}, actions: null,
      tree: "box[apex-message-row[message-icon,box[message-header,message-box[message-content,box]]],message-action-bin]"}}}}}'

test_notifications_layer() {
    local change what passes failures
    jq -nc "$NOTIFICATIONS_REPORT" | sed 's/^/APEXG2-SCENES /' >"$T/notifications.log"
    read -r passes failures <<<"$(assertion_counts notifications_layer case "$T/notifications.log" apex)"
    expect_eq "notifications: the feature's list, cards, footer and calendar pass all ten assertions" "10/0" "$passes/$failures"
    while IFS='|' read -r change what; do
        jq -nc "$NOTIFICATIONS_REPORT | .surfaces.notificationsLayer |= ($change)" | sed 's/^/APEXG2-SCENES /' >"$T/notifications.log"
        read -r passes failures <<<"$(assertion_counts notifications_layer case "$T/notifications.log" apex)"
        expect_eq "notifications: $what fails one assertion" "9/1" "$passes/$failures"
    done <<'CHANGES'
.messages[1].y = 10|a stacked group
.header = true|a group header
.cardHeader.sourceIcon = true|a card header with the source glyph
.icon = null|a card without the app's icon
.dnd = null|a footer without Do Not Disturb
.clear.x = 200|Clear off the right edge
.dndClick.showBanners = true|a click that left banners on
.empty.clearVisible = false|Clear hidden with nothing to clear
.calendar.label.x = 250|the month between its chevrons
.calendar.dots = [.calendar.dots[0]]|a day without its dot
.trees[2] = "box[message-header,message-box[message-icon,message-content,box],message-action-bin]"|a back card in upstream's tree
.layout.collapsed.header.x = 50|the header 4 px from the icon's column
.layout.collapsed.icon.width = 48|a 48 px icon tile
.layout.expanded.actions.x = 58|the action row under the text column alone
.layout.expanded.actions = null|an expanded card without its action row
.layout.collapsedAgain.actions = {x: 14, y: 80, width: 376, height: 32}|the action row left shown, collapsed
CHANGES
    jq -nc "$NOTIFICATIONS_REPORT | .surfaces.notificationsLayer |= (.messages[1].y = 10 | .dnd = null | .empty.clearVisible = false
        | .cardHeader.sourceIcon = true | .icon = null | .calendar.label.x = 250 | .calendar.dots = []
        | .trees = [range(3) | \"box[message-header,message-box[message-icon,message-content,box],message-action-bin]\"])" |
        sed 's/^/APEXG2-SCENES /' >"$T/notifications.log"
    read -r passes failures <<<"$(assertion_counts notifications_layer case "$T/notifications.log" stock)"
    expect_eq "notifications: stock's stacked list, lone Clear and centred month pass all four stock assertions" "4/0" "$passes/$failures"
}

test_shadow_layers() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run shadow_layers "$variant")"
        if ((failures == 0 && passes == 5)); then
            ok "shadows ($variant): layers drawn from the tokens pass all $passes assertions"
        else
            not_ok "shadows ($variant): layers drawn from the tokens pass (passed/failed $passes/$failures): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run shadow_layers light "$change")"
        expect_eq "shadows: $what fails one assertion" "4/1" "$passes/$failures"
    done <<'CHANGES'
.surfaces.shadowLayers.quickSettings[0].radius = 0|a Quick Settings layer with square corners
.surfaces.shadowLayers.dateMenu = []|a calendar without its second layer
.surfaces.shadowLayers.dialog[0].besideBox = false|a dialog layer under the lightbox
.surfaces.shadowLayers.dateMenu[0].box[0] += 1|a layer 1 px off its surface's box
.surfaces.shadowLayers.popupMenu[0].box[2] = 10 + 105|a menu's layer at the surface's natural width, not its allocation
.surfaces.shadowLayers.popupMenu[0].natural[0] = 220|a menu no wider than its natural width, which proves nothing
.surfaces.shadowLayers.dialog[0].boxShadow.blur = 50|the first layer's blur on the second
.surfaces.idleRepaints.withShadows = 9|an idle desktop that repaints more with shadows
CHANGES
}

test_overview_layer() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run overview_layer "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 12)); then
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
.surfaces.overviewWindows.previews[0].caption.y = 480|a caption over the next row's preview
.surfaces.overviewWindows.previews[1].caption.visible = false|a caption shown only on hover
.surfaces.overviewWindows.previews[2].caption.y = 780|the last row's captions nearer the dock than $apex_dock_bottom_gap
.surfaces.overviewWindows.thumbnails[1].spread = 0|stock's flat thumbnail fill
.surfaces.overviewWindows.bottom.hook = 820|a bottom edge without the dock's gap
.surfaces.overviewWindows.previews[1].radius = 12|a preview rounded at libadwaita's 12, not board 35's 14
.surfaces.overviewWindows.previews[2].layers = [.surfaces.overviewWindows.previews[2].layers[0]]|a preview with one shadow layer
.surfaces.overviewWindows.previews[0].layers[1].box = [0, 0, 290, 240]|a layer cut shorter than its preview
.surfaces.overviewWindows.previews[0].layers[0].boxShadow.color = "#00000073"|the dark preview shadow in light
.surfaces.overviewWindows.previews[2].layers[1].boxShadow.blur = 32|the first layer's blur on the second
.surfaces.appGrid.grid.iconSize = 96|upstream's 96 px launcher icons
.surfaces.appGrid.box.y = 262|upstream's workspace strip above the grid
.surfaces.appGrid.box.y = 128|the grid at board 36's old 128, which assumed an 18 px spacing
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

test_screenshot_ui() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run screenshot_ui "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 8)); then
            ok "screenshot UI ($variant): drawn from the tokens it passes all $passes assertions"
        else
            not_ok "screenshot UI ($variant): drawn from the tokens it passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run screenshot_ui light "$change")"
        if ((failures == 1)); then
            ok "screenshot UI: $what fails one assertion"
        else
            not_ok "screenshot UI: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.screenshot.panel.background = "#222226ff"|upstream's dark OSD panel
.surfaces.screenshot.panel.padding.top = 17|no heading row
.surfaces.screenshot.close.y -= 29|upstream's close button on the panel's corner
.surfaces.screenshot.types[2].background = "#2e2e33ff"|upstream's insensitive Window button
.surfaces.screenshot.pointer.checked.background = "#00000a1e"|a pointer toggle that is not the accent when on
.surfaces.screenshot.capture.width = 48|upstream's 48 px capture button
.surfaces.screenshot.shot.background = "#ffffffff"|upstream's white checked switch
.surfaces.screenshot.handle.width = 24|upstream's 24 px handles
.surfaces.screenshot.screen.borderColor = "#ffffffff"|upstream's white screen frame
CHANGES
}

test_tile_preview() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run tile_preview "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 2)); then
            ok "tile preview ($variant): drawn from the tokens it passes all $passes assertions"
        else
            not_ok "tile preview ($variant): drawn from the tokens it passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run tile_preview light "$change")"
        if ((failures == 1)); then
            ok "tile preview: $what fails one assertion"
        else
            not_ok "tile preview: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.tilePreview.preview.width = 708|a preview shrunk to the inset instead of bordered
.surfaces.tilePreview.preview.borderColor = "#3584e4ff"|upstream's opaque accent border
.surfaces.tilePreview.preview.x = 6|a preview moved instead of inset
.surfaces.tilePreview.preview.radius = 0|upstream's square corners
.surfaces.tilePreview.preview.background = "#3584e480"|upstream's half-accent fill
.surfaces.tilePreview.preview.boxShadow = {inset: true, x: 0, y: 0, blur: 0, spread: 2, color: "#3584e4b3"}|the inset ring, thick at the corners, left on the classed preview
.surfaces.tilePreview.preview.styleClass = "tile-preview on-primary tile-preview-left"|a preview that lost its class to _updateStyle()
.surfaces.tilePreview.glass = null|no glass actor to draw the fill and ring
.surfaces.tilePreview.glass.border.top = 1|a ring a pixel thinner along the top
.surfaces.tilePreview.glass.background = "#00000000"|a glass actor without the fill
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
        if ((failures == 0 && open_gaps == 0 && passes == 17)); then
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
.surfaces.spotlight.rows[3].tile.background = "#6f8396ff"|Privacy in board 38's old grey
.surfaces.spotlight.rows[4].tile = null|a panel without a colour drawn bare
.surfaces.spotlight.rows[2].tile.foreground = "#1d1d21ff"|a dark glyph on a coloured tile
.surfaces.overviewSearch.opened = false|the overview's stock search
.surfaces.overviewSearch.overviewText = "disk"|the typed text left in the overview's field too
CHANGES
}

test_surface_metrics() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run surface_metrics "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 8)); then
            ok "surface metrics ($variant): boards 34 to 36 as laid out pass all $passes assertions"
        else
            not_ok "surface metrics ($variant): boards 34 to 36 as laid out pass (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run surface_metrics light "$change")"
        if ((failures == 1)); then
            ok "surface metrics: $what fails one assertion"
        else
            not_ok "surface metrics: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.notificationsLayer.layout.collapsed += {icon: {x: 368, y: 64, width: 48, height: 48}, header: {x: 428, y: 67, width: 255, height: 19}}|upstream's 48 px notification icon
.surfaces.notificationsLayer.layout.collapsed.icon.x -= 2|the icon at the card's 12 px padding, not its 14 px start
.surfaces.notificationsLayer.layout.collapsed.header.x -= 4|the header's column 8 px past the icon
.surfaces.notificationsLayer.layout.collapsed.close.x += 4|the close button 6 px from the card's right
.surfaces.notificationsLayer.layout.collapsed.close.y += 6|the close button centred down the card
.surfaces.notificationsLayer.footer.height = 48|a 48 px footer
.surfaces.notificationsLayer.dnd.x = 354|Do Not Disturb flush with the footer's left
.surfaces.notificationsLayer.clear.x += 4|Clear flush with the footer's right
.surfaces.notificationsLayer.clear.y -= 4|Clear off the footer's centre
.surfaces.notificationsLayer.clear.height = 36|a 36 px Clear
.surfaces.overview.indicator.boxShadow = {x: 0, y: 2, blur: 6}|a shadow under the current workspace's ring
.surfaces.overview.thumbnail.boxShadow = {x: 0, y: 2, blur: 6}|a shadow under the thumbnails
.surfaces.overview.indicator += {x: 599, width: 116}|the ring inside the thumbnail's sides, not around them
.surfaces.overviewWindows.thumbnails[1].x += 6|thumbnails 16 px apart
.surfaces.notificationsLayer.dnd.switch.x = 340|board 34's switch before the label
.surfaces.notificationsLayer.dnd.switch.x -= 2|board 34's 10 px gap before the switch
.surfaces.notificationsLayer.dnd.switch.y += 6|the switch off the row's centre
.surfaces.overviewWindows.previews[0].caption.y -= 15|board 35's caption 10 px under the preview
.surfaces.overviewWindows.previews[1].caption.height = 34|a caption taller than $apex_caption_height
.surfaces.appGrid.spacing.h = 11|board 36's 150 px pitch, against the grid's own
.surfaces.appGrid.tiles[3].x -= 13|a column off the grid's pitch
.surfaces.appGrid.tiles[2].width = 112|a tile narrower than the grid's
.surfaces.appGrid.tiles[6].y = 317|six tiles a row
.surfaces.appGrid.tiles[7].y += 20|the second row off the grid's pitch
.surfaces.appGrid.tiles[].x -= 30|the grid off the monitor's centre
.surfaces.appGrid.tiles[4].x += 2 * 163|a five-app row with a gap
.surfaces.launcher.pill.x = 500|the launcher's pill off centre
.surfaces.launcher.pill.y = 60|the launcher's pill 28 px below the bar
.surfaces.launcher.pill.height = 36|a 36 px launcher pill
.surfaces.appGrid.scrim.background = "#00000000"|the launcher over no scrim
CHANGES
}

test_launcher_search() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run launcher_search "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 3)); then
            ok "launcher search ($variant): drawn from the tokens it passes all $passes assertions"
        else
            not_ok "launcher search ($variant): drawn from the tokens it passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run launcher_search light "$change")"
        if ((failures == 1)); then
            ok "launcher search: $what fails one assertion"
        else
            not_ok "launcher search: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.launcher.pill.width = 440|the overview's 440 px pill
.surfaces.launcher.pill.hint = "Type to search"|upstream's hint
.surfaces.launcher.found.spotlightOpen = true|Spotlight opened instead
.surfaces.launcher.found.names = []|no app found for "files"
.surfaces.launcher.found.gridHidden = false|results under the full grid
.surfaces.launcher.found.results.y = 422|results centred in the grid's box instead of filling it
.surfaces.launcher.empty.top = 160|"No Results" centred instead of at its place
.surfaces.launcher.empty.title.font.weight = 600|a lighter "No Results"
.surfaces.launcher.empty.hint.foreground = "#1d1d21ff"|a hint at full strength
CHANGES
}

test_spotlight_glass() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run spotlight_glass "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 1)); then
            ok "Spotlight glass ($variant): drawn from the tokens it passes"
        else
            not_ok "Spotlight glass ($variant): drawn from the tokens it passes (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run spotlight_glass light "$change")"
        if ((failures == 1)); then
            ok "Spotlight glass: $what fails it"
        else
            not_ok "Spotlight glass: $what fails it (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.spotlight.glass.panelBeforeCopy.effect = null|a panel without its blur
.surfaces.spotlight.glass.toast.blur = 34|the toast at the panel's sigma 34
.surfaces.spotlight.glass.panelBeforeCopy.effect.radius = 68|a radius not scaled to the monitor
.surfaces.spotlight.glass.toast.effect.enabled = false|a toast whose blur is off
CHANGES
}

test_spotlight_keys() {
    local variant change what passes failures open_gaps
    for variant in light dark; do
        read -r passes failures open_gaps <<<"$(assert_run spotlight_keys "$variant")"
        if ((failures == 0 && open_gaps == 0 && passes == 5)); then
            ok "Spotlight keys ($variant): a slow provider and real key presses pass all $passes assertions"
        else
            not_ok "Spotlight keys ($variant): a slow provider and real key presses pass (passed/failed/gaps $passes/$failures/$open_gaps): $(grep -m3 '^FAIL' "$T/top-bar.out" | paste -sd'|' -)"
        fi
    done
    while IFS='|' read -r change what; do
        read -r passes failures open_gaps <<<"$(assert_run spotlight_keys light "$change")"
        if ((failures == 1)); then
            ok "Spotlight keys: $what fails one assertion"
        else
            not_ok "Spotlight keys: $what fails one assertion (passed/failed/gaps $passes/$failures/$open_gaps)"
        fi
    done <<'CHANGES'
.surfaces.spotlightKeys.early.sections = ["APPLICATIONS"]|Files held back by the slow Settings
.surfaces.spotlightKeys.early.ms = 1100|the sections seen only past the budget
.surfaces.spotlightKeys.late.rows = 0|every section hidden once the budget runs out
.surfaces.spotlightKeys.settings.cancelledMs = null|Settings never cancelled
.surfaces.spotlightKeys.settings.cancelledMs = 1051|Settings cancelled 1 ms before its budget from the ask ran out
.surfaces.spotlightKeys.late.ms = 1700|the sections read only after Settings would have answered
.surfaces.spotlightKeys.settings.cancelledMs = 1250|Settings cancelled only after the sections were read
.surfaces.spotlightKeys.down4 = "Applications/org.gnome.baobab.desktop"|Down kept inside its section
.surfaces.spotlightKeys.down20 = null|Down past the last row
.surfaces.spotlightKeys.enter.activated = []|Enter opening nothing
.surfaces.spotlightKeys.enter.modal += 1|a modal left behind after Enter
.surfaces.spotlightKeys.escape.open = true|Esc ignored
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
    G2_GJS=false bash -c '. "$1/assert.sh"; compare_with_fedora "$2" safe' _ "$HERE" "$T/run-a" >"$T/fedora-compare.out" 2>&1 || true
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

# stable.sh on two runs' reports: Spotlight keys' times may differ, any other field may not.
test_stable_reports() {
    local dir=$T/stable keys scenes
    keys='{"budgetMs": 1000, "early": {"ms": 367, "rows": 3}, "late": {"ms": 1126, "rows": 5},
           "settings": {"askedMs": 66, "cancelledMs": 1067}}'
    scenes=$(jq -c --argjson keys "$keys" -n '{scenes: {}, surfaces: {spotlightKeys: $keys}}')
    report_pair() {
        rm -rf "$dir" && mkdir -p "$dir/a" "$dir/b"
        printf 'APEXG2-SCENES %s\n' "$scenes" >"$dir/a/default.log"
        printf 'APEXG2-SCENES %s\n' "$(jq -c "$1" <<<"$scenes")" >"$dir/b/default.log"
        G2_GJS=false "$HERE/stable.sh" "$dir/a" "$dir/b" 2>&1 | grep '^[A-Z]* default: .*(APEXG2-SCENES)'
    }
    expect_eq "stable: runs whose Spotlight keys took other times report the same" \
        "PASS default: both runs report the same (APEXG2-SCENES)" \
        "$(report_pair '.surfaces.spotlightKeys |= (.early.ms += 1 | .late.ms += 1 | .settings.askedMs += 4 | .settings.cancelledMs += 4)')"
    expect_eq "stable: a run whose Spotlight keys showed other rows fails, naming the field" \
        "FAIL default: the runs report differently (APEXG2-SCENES): 1 differ: surfaces.spotlightKeys.late.rows 5 → 4" \
        "$(report_pair '.surfaces.spotlightKeys.late.rows = 4 | .surfaces.spotlightKeys.late.ms += 1')"
    expect_eq "stable: a run whose Settings provider was never cancelled fails" \
        'FAIL default: the runs report differently (APEXG2-SCENES): 1 differ: surfaces.spotlightKeys.settings.cancelledMs "measured" → null' \
        "$(report_pair '.surfaces.spotlightKeys.settings.cancelledMs = null')"
    expect_eq "stable: a run without a measured field fails" \
        'FAIL default: the runs report differently (APEXG2-SCENES): 1 differ: surfaces.spotlightKeys.settings.askedMs "measured" → absent' \
        "$(report_pair 'del(.surfaces.spotlightKeys.settings.askedMs)')"
    expect_eq "stable: a time outside Spotlight keys is still compared" \
        "FAIL default: the runs report differently (APEXG2-SCENES): 1 differ: surfaces.osd.ms 10 → 11" \
        "$(scenes=$(jq -c '.surfaces.osd.ms = 10' <<<"$scenes"); report_pair '.surfaces.osd.ms = 11')"
}

# A scenes report past an argument's size still plans its pair, with its masks; one jq cannot read fails it by name.
test_huge_plan() {
    local dir=$T/huge-plan filler entry
    rm -rf "$dir" && mkdir -p "$dir"
    filler=$(head -c 300000 /dev/zero | tr '\0' x)
    printf 'APEXG2-SCENES {"scenes": {"desktop": {"boxes": {"panel": {"x": 0, "y": 0, "width": 40, "height": 2}}}}, "filler": "%s"}\n' "$filler" |
        tee "$dir/a.log" >"$dir/b.log"
    # shellcheck disable=SC2016 # expanded by the inner bash
    entry=$(bash -c '. "$1/lib.sh"; plan_entry huge "$2" a "$2" b desktop "$2" panel' _ "$HERE" "$dir" 2>&1)
    expect_eq "captures: a scenes report of 300 kB plans its pair, with its masks" \
        '{"name":"huge","masks":[{"name":"panel","x":0,"y":0,"width":40,"height":2}]}' \
        "$(jq -c '{name, masks}' <<<"$entry" 2>&1)"
    echo 'APEXG2-SCENES {"scenes": {"desktop": }}' >"$dir/b.log"
    # shellcheck disable=SC2016 # expanded by the inner bash
    bash -c '. "$1/lib.sh"; plan_entry huge "$2" a "$2" b desktop "$2" panel | jq -s . >"$2/plan.json"
        G2_GJS=false compare_and_expect_equal "$2/plan.json" "$2/results.json"' _ "$HERE" "$dir" >"$dir/out" 2>&1
    if grep -q '^FAIL captures huge: not compared (jq could not write its plan entry (exit [0-9]*))$' "$dir/out"; then
        ok "captures: a pair jq could not plan fails by name"
    else
        not_ok "captures: a pair jq could not plan fails by name: $(head -n 3 "$dir/out")"
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

test_backdrop_painted() {
    local solid want_pass label what report passes failures
    # shellcheck disable=SC2016 # expanded by the inner bash
    solid=$(bash -c '. "$1/assert.sh"; echo "$SOLID_BACKDROP"' _ "$HERE")
    expect_eq "backdrop: assert.sh expects the stress backdrop direct.sh paints" "$solid" \
        "$(sed -n "s/^readonly SOLID_BACKDROP='\(#[0-9a-f]*\)'\$/\1/p" "$HERE/direct.sh")"
    while IFS='|' read -r want_pass label what report; do
        if [[ -n $report ]]; then printf 'APEXG2-BACKDROP %s\n' "$report" >"$T/backdrop.log"; else : >"$T/backdrop.log"; fi
        read -r passes failures <<<"$(assertion_counts backdrop_painted "$label" "$T/backdrop.log")"
        expect_eq "backdrop: $what" "$want_pass/$((1 - want_pass))" "$passes/$failures"
    done <<'CASES'
1|default|the light Facets, painted, passes|{"expected":"facets-light","patches":12,"delta":2.1,"waitedMs":0}
1|dark-style|the dark Facets in a dark case passes|{"expected":"facets-dark","patches":12,"delta":1,"waitedMs":250}
1|high-contrast-solid|the stress backdrop in a -solid case passes|{"expected":"#013b88","patches":12,"delta":0,"waitedMs":0}
0|default|a backdrop that never painted fails|{"expected":"facets-light","error":"the backdrop did not paint: after 10000 ms the desktop at 384,270 shows #013b88 where facets-light has #e9ecf3 (off by 233)"}
0|dark-style|the light Facets in a dark case fails|{"expected":"facets-light","patches":12,"delta":1,"waitedMs":0}
0|default-solid|the Facets in a -solid case fails|{"expected":"facets-light","patches":12,"delta":1,"waitedMs":0}
0|default|a case without a backdrop report fails|
CASES
    printf 'APEXG2-BACKDROP %s\n' '{"expected":"facets-light","error":"the backdrop did not paint: after 10000 ms the desktop at 384,270 shows #013b88"}' >"$T/backdrop.log"
    assertion_counts backdrop_painted default "$T/backdrop.log" >/dev/null
    if grep -q '^FAIL default: the facets-light backdrop painted (the backdrop did not paint: after 10000 ms' "$T/assertions.out"; then
        ok "backdrop: a backdrop that never painted fails by name, with what the desktop showed"
    else
        not_ok "backdrop: a backdrop that never painted fails by name (got: $(cat "$T/assertions.out"))"
    fi
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
  surfaces: (["dock-lift", "intellihide", "overview", "spotlight", "quick-settings", "calendar", "dialog"]
    | map({name: ., eases: 2, apexEases: 1}) as $steps
    | {animated: {steps: $steps, eases: 14, apexEases: 6,
                  lasting: [{apex: true, where: "ui/apex/dock/dock.js:71:23", durations: [180]},
                            {apex: false, where: "ui/popupMenu.js:1132:26", durations: [180, 0]}]},
       still: {steps: $steps, eases: 14, apexEases: 6, lasting: []}}),
  previews: [{styled: true, layers: [
    {shown: true, radius: 14, boxShadow: {color: "#141e3c33", inset: false, x: 0, y: 12, blur: 32, spread: 0}},
    {shown: true, radius: 14, boxShadow: {color: "#141e3c1a", inset: false, x: 0, y: 1, blur: 4, spread: 0}}]}]}'

write_motion_run() {
    local change=$1 dir=$T/motion
    rm -rf "$dir" && mkdir -p "$dir"
    {
        printf 'APEXG2 %s\n' "$APEX_LIGHT_REPORT"
        printf 'APEXG2-MOTION %s\n' "$(jq -nc "$MOTION_REPORT | .animated.surfaces = .surfaces.animated | .still.surfaces = .surfaces.still | del(.surfaces) | $change")"
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
.animated.surfaces.lasting = []|a control in which no Apex ease lasts
.still.surfaces.lasting = [{apex: true, where: "ui/apex/dock/intellihide.js:74:19", durations: [380]}]|an Apex ease left at 380 ms with animations off
.still.surfaces.lasting = [{apex: false, where: "ui/boxpointer.js:1:1", durations: [180]}]|a stock ease left at 180 ms with animations off
.still.surfaces.steps = .still.surfaces.steps[:-1]|a surface the probe never opened
.still.surfaces.apexEases = 0|a run in which no Apex code eased
CHANGES
    write_motion_run '{error: "the test client never mapped (Gtk-WARNING: Failed to open display)\nprobe.js:1700"}'
    read -r passes failures <<<"$(assertion_counts motion_curve "$T/motion")"
    expect_eq "motion: a client that never mapped fails once, with its stderr, not every assertion after it" \
        "$((all - 9))/1 the test client never mapped (Gtk-WARNING: Failed to open display)" \
        "$passes/$failures $(sed -n 's/^FAIL motion: //p' "$T/assertions.out")"
}

# shellcheck disable=SC2016 # a jq program
readonly IDLE_REPORT='{windowMs: 10000,
  settled: {startingUp: false, overview: false, actionMode: "NORMAL", dock: {visible: true, rested: true}, barGlass: true, dockGlass: true,
    easing: []},
  idle: {afterPaints: 0, frames: [], relayouts: {}},
  quickSettings: {afterPaints: 0, frames: [], relayouts: {}},
  reduceTransparency: {idle: {afterPaints: 0, frames: [], relayouts: {}}, quickSettings: {afterPaints: 0, frames: [], relayouts: {}}},
  control: {afterPaints: 3, frames: [{atMs: 512, damage: {rectangles: 2, extents: {x: 1050, y: 36, width: 376, height: 418},
    under: [["StBoxLayout.quick-settings", "StBoxLayout.popup-menu-content"]]}}]},
  overview: {shown: true, wallpapers: 2, idle: {afterPaints: 0, frames: [], relayouts: {}}}}'
# shellcheck disable=SC2016 # a jq program
readonly IDLE_FRAME='{atMs: 4210, damage: {rectangles: 1, extents: {x: 600, y: 838, width: 240, height: 62},
  under: [["StIcon.apex-dock-trash", "ApexDock#apexDock"]]}}'

# shellcheck disable=SC2016 # a jq program
readonly DOCK_PIN_REPORT='{settled: {startingUp: false, overview: false, actionMode: "NORMAL", dock: {visible: true, rested: true}},
  pinned: "org.gnome.Calculator.desktop", dockApps: ["org.gnome.Nautilus.desktop", "org.gnome.Calculator.desktop"],
  dockUpdate: {afterPaints: 4}, windowMs: {dockUpdate: 3000, fallback: 21000}, fallbackFiredMs: [20004],
  fallback: {afterPaints: 0, frames: [], relayouts: {}},
  stock: {shown: true, dashApps: ["org.gnome.Nautilus.desktop"], favorites: ["org.mozilla.firefox.desktop", "org.gnome.Nautilus.desktop"]}}'

write_dock_pin_run() {
    local change=$1 dir=$T/dock-pin
    rm -rf "$dir" && mkdir -p "$dir"
    printf 'APEXG2-DOCK-PIN %s\n' "$(jq -nc --argjson frame "$(jq -nc "$IDLE_FRAME")" "$DOCK_PIN_REPORT | $change")" >"$dir/dock-pin.log"
    echo 'dock-pin exit=0 secs=58 marker-after-exit=no' >"$dir/results-main.txt"
}

test_dock_pin() {
    local change what passes failures all
    write_dock_pin_run .
    read -r all failures <<<"$(assertion_counts dock_pin "$T/dock-pin")"
    if ((failures == 0 && all > 5)); then
        ok "dock-pin: the pin shows at once, no frame through the fallback, stock's dash full, pass all $all assertions"
    else
        not_ok "dock-pin: a clean run passes (passed/failed $all/$failures): $(grep -m3 '^FAIL' "$T/assertions.out" | paste -sd'|' -)"
    fi
    while IFS='|' read -r change what; do
        write_dock_pin_run "$change"
        read -r passes failures <<<"$(assertion_counts dock_pin "$T/dock-pin")"
        expect_eq "dock-pin: $what fails one assertion" "$((all - 1))/1" "$passes/$failures"
    done <<'CHANGES'
.fallback += {afterPaints: 1, frames: [$frame]}|a frame when the fallback comes round
.fallback.afterPaints = 1|a paint the counter saw but did not keep
.dockApps = ["org.gnome.Nautilus.desktop"]|a dock that never showed the pin
.dockUpdate.afterPaints = 0|a pin the dock did not paint at once
.windowMs.fallback = 10000|windows that end before the fallback
.stock.dashApps = []|an overview dash left empty with the dock off
.stock.shown = false|an overview that never showed
.settled.overview = true|an overview left open before the pin
.settled.actionMode = "NONE"|main.js's NONE action mode left after settleDesktop
CHANGES
    write_dock_pin_run '{error: "no installed app outside the favourites to pin\ndock-pin.js:64"}'
    read -r passes failures <<<"$(assertion_counts dock_pin "$T/dock-pin")"
    expect_eq "dock-pin: a probe error fails once" "2/1 no installed app outside the favourites to pin" \
        "$passes/$failures $(sed -n 's/^FAIL dock-pin: //p' "$T/assertions.out")"
}

write_idle_run() {
    local change=$1 dir=$T/idle feature
    rm -rf "$dir" && mkdir -p "$dir"
    {
        printf 'APEXG2 %s\n' "$APEX_LIGHT_REPORT"
        # shellcheck disable=SC2016 # expanded by the inner bash
        for feature in $(bash -c '. "$1/assert.sh"; layer_features' _ "$HERE"); do
            printf 'Gjs-Console-Message: 09:41:00.000: Apex: feature %s enabled\n' "$feature"
        done
        printf 'APEXG2-IDLE %s\n' "$(jq -nc --argjson frame "$(jq -nc "$IDLE_FRAME")" "$IDLE_REPORT | $change")"
    } >"$dir/idle.log"
    echo 'idle exit=0 secs=31 marker-after-exit=no' >"$dir/results-main.txt"
}

# shellcheck disable=SC2016 # a jq program
readonly DOCK_DND_REPORT='def at_rest: {placeholder: false, emptyTarget: false, modals: 0, actionMode: "NORMAL", grab: false,
    showAppsLabel: "Show Apps", showAppsName: "Show Apps", faded: [],
    strays: [{type: "Clutter_Actor", name: null, width: 0, height: 0, children: 0}]};
  def shows($f; $a): {favorites: $f, apps: $a, drawnInOrder: true, tail: ["separator", "show-apps", "trash"], drag: at_rest};
  def shows($f): shows($f; $f);
  "org.gnome.Nautilus.desktop" as $files | "org.gnome.clocks.desktop" as $clocks | "org.gnome.Weather.desktop" as $weather |
  "io.github.apex_linux.G2Window.desktop" as $running |
  {settled: {startingUp: false, overview: false, actionMode: "NORMAL", dock: {visible: true, rested: true}},
   steps: {initial: shows([$files, $clocks]), reorder: shows([$clocks, $files]), fromGrid: shows([$clocks, $weather, $files]),
     unpin: (shows([$clocks, $files]) + {label: "Unpin"}), dropOff: shows([$clocks, $files]), onTrash: shows([$clocks, $files]),
     running: {installed: true, running: true, shown: true, before: shows([$clocks, $files]; [$clocks, $files, $running]),
       after: shows([$clocks, $running, $files])},
     cancelled: shows([$clocks, $files])}}'

write_report_run() {
    local name=$1 tag=$2 report=$3 change=$4 dir=$T/$1
    rm -rf "$dir" && mkdir -p "$dir"
    printf 'APEXG2-%s %s\n' "$tag" "$(jq -nc "$report | $change")" >"$dir/$name.log"
    echo "$name exit=0 secs=40 marker-after-exit=no" >"$dir/results-main.txt"
}

test_dock_dnd() {
    local change what passes failures all
    write_report_run dock-dnd DOCK-DND "$DOCK_DND_REPORT" .
    read -r all failures <<<"$(assertion_counts dock_dnd_case "$T/dock-dnd")"
    if ((failures == 0 && all > 15)); then
        ok "dock-dnd: every drag lands in favorite-apps and the drawn order, nothing left dragging, pass all $all assertions"
    else
        not_ok "dock-dnd: a clean run passes (passed/failed $all/$failures): $(grep -m3 '^FAIL' "$T/assertions.out" | paste -sd'|' -)"
    fi
    while IFS='|' read -r change what; do
        write_report_run dock-dnd DOCK-DND "$DOCK_DND_REPORT" "$change"
        read -r passes failures <<<"$(assertion_counts dock_dnd_case "$T/dock-dnd")"
        expect_eq "dock-dnd: $what fails one assertion" "$((all - 1))/1" "$passes/$failures"
    done <<'CHANGES'
.settled.actionMode = "OVERVIEW"|a session that never left the overview's action mode
.steps.initial.favorites = ["org.gnome.Nautilus.desktop"]|a case without its two favourites
.steps.reorder.favorites = [.steps.reorder.favorites[1], .steps.reorder.favorites[0]]|a reorder that favorite-apps never saw
.steps.fromGrid.apps = [.steps.fromGrid.apps[2], .steps.fromGrid.apps[1], .steps.fromGrid.apps[0]]|an app grid drop the dock draws out of order
.steps.unpin.label = "Show Apps"|Show Apps not offering to unpin
.steps.unpin.favorites += ["org.gnome.Weather.desktop"]|a drop on Show Apps that keeps the favourite
.steps.dropOff.favorites = ["org.gnome.clocks.desktop"]|a drop off the dock that unpins
.steps.onTrash.favorites = ["org.gnome.clocks.desktop"]|Trash taking a favourite
.steps.running.shown = false|a running app the dock never shows
.steps.running.after.favorites = ["org.gnome.clocks.desktop", "org.gnome.Nautilus.desktop"]|a running app the drop does not pin
.steps.cancelled.drawnInOrder = false|a cancelled drag that leaves the icons out of order
.steps.fromGrid.tail = ["separator", "trash", "show-apps"]|Trash before Show Apps after a drop
.steps.reorder.drag.placeholder = true|a placeholder left after a drop
.steps.running.after.drag.grab = true|a grab left after a drop
.steps.unpin.drag.showAppsLabel = "Unpin"|Show Apps still named Unpin after the drag
.steps.onTrash.drag.strays += [{type: "ApexDockIcon", name: null, width: 54, height: 54, children: 1}]|a drag actor left on the stage
.steps.cancelled.drag.modals = 1|a modal left after Esc
CHANGES
    write_report_run dock-dnd DOCK-DND '{error: "the dock shows 1 favourites, not two to reorder\ndock-dnd.js:165"}' .
    read -r passes failures <<<"$(assertion_counts dock_dnd_case "$T/dock-dnd")"
    expect_eq "dock-dnd: a probe error fails once" "3/1 the dock shows 1 favourites, not two to reorder" \
        "$passes/$failures $(sed -n 's/^FAIL dock-dnd: //p' "$T/assertions.out")"
}

# shellcheck disable=SC2016 # a jq program
readonly DOCK_EXTERNAL_REPORT='def lay($p; $window; $hidden; $solid): {primary: $p,
    monitors: [{x: 0, y: 0, width: 1440, height: 900, index: 0}, {x: 1440, y: 0, width: 960, height: 540, index: 1}],
    dockBox: (if $p == 0 then {x: 596, y: 820, width: 249, height: 80} else {x: 1796, y: 460, width: 249, height: 80} end),
    dockHidden: $hidden,
    panelBox: (if $p == 0 then {x: 0, y: 0, width: 1440, height: 32} else {x: 1440, y: 0, width: 960, height: 32} end),
    barSolid: $solid, window: $window};
  def glass($radius; $scale; $box): {radius: $radius, enabled: true, resourceScale: $scale, box: $box};
  def mon0: {x: 0, y: 0, width: 1440, height: 900};
  def mon1: {x: 1440, y: 0, width: 960, height: 540};
  def ext1: {x: 1440, y: 0, width: 1920, height: 1080};
  def unscaled: {clone: {x: 0, y: 0, width: 0, height: 0}, source: {x: 0, y: 0, width: 0, height: 0}};
  def overview($state): {shown: true, controlsState: $state,
    scrims: [{visible: true, box: mon0, launcher: ($state == 2)}, {visible: true, box: mon1, launcher: ($state == 2)}],
    monitors: [mon0, mon1],
    views: [{x: 0, y: 185, width: 1440, height: 618}, {x: 1440, y: 0, width: 960, height: 540}]};
  {settled: {startingUp: false, overview: false, actionMode: "NORMAL", dock: {visible: true, rested: true}},
   steps: {initial: (lay(0; null; false; false) + {dock: {bottomGap: 10, centreOffset: 0.5, visible: true}}),
     onSecondary: lay(0; {monitor: 1, maximised: true}; false; false),
     onPrimary: lay(0; {monitor: 0, maximised: true}; true; true),
     backOnSecondary: lay(0; {monitor: 1, maximised: true}; false; false),
     overview: (overview(1) + {glass: {scrims: [(glass(144; 2; mon0) + unscaled), (glass(144; 2; mon1) + unscaled)],
       cost: {perMonitor: 6.29, wholeStage: 7.85}}}),
     launcher: overview(2),
     swapped: (lay(1; {monitor: 0, maximised: true}; false; false) + {changed: true, dock: {bottomGap: 10, centreOffset: 0.5}}),
     mixedOnExternal: (lay(1; {monitor: 0, maximised: true}; false; false) + {changed: true,
       monitors: [{x: 0, y: 0, width: 1440, height: 900, index: 0}, {x: 1440, y: 0, width: 1920, height: 1080, index: 1}],
       dockBox: {x: 2276, y: 1000, width: 249, height: 80}, panelBox: {x: 1440, y: 0, width: 1920, height: 32},
       dock: {bottomGap: 10, centreOffset: 0.5},
       overview: (overview(1) + {stage: {x: 0, y: 0, width: 3360, height: 1080},
         scrims: [{visible: true, box: mon0, launcher: false}, {visible: true, box: ext1, launcher: false}], monitors: [mon0, ext1]}),
       glass: {dock: glass(56; 1; {x: 2276, y: 1010, width: 249, height: 70}), bar: glass(48; 1; {x: 1440, y: 0, width: 1920, height: 32}),
         scrims: [(glass(144; 2; mon0) + unscaled), (glass(72; 1; ext1) + unscaled)], cost: {perMonitor: 6.6, wholeStage: 13.18}},
       desktopGlass: {dock: glass(56; 1; {x: 2276, y: 1010, width: 249, height: 70}), bar: glass(48; 1; {x: 1440, y: 0, width: 1920, height: 32}),
         scrims: [(glass(144; 2; mon0) + {enabled: false}), (glass(72; 1; ext1) + {enabled: false})]}}),
     mixed: (lay(0; {monitor: 0, maximised: true}; true; true) + {changed: true,
       monitors: [{x: 0, y: 0, width: 1440, height: 900, index: 0}, {x: 1440, y: 0, width: 1920, height: 1080, index: 1}],
       dockBox: {x: 596, y: 980, width: 249, height: 80},
       glass: {dock: glass(112; 2; {x: 596, y: 990, width: 249, height: 70}), bar: (glass(96; 2; {x: 0, y: 0, width: 1440, height: 32}) + {enabled: false})}})}}'

test_dock_external() {
    local change what passes failures all
    write_report_run dock-external DOCK-EXTERNAL "$DOCK_EXTERNAL_REPORT" .
    read -r all failures <<<"$(assertion_counts dock_external_case "$T/dock-external")"
    if ((failures == 0 && all > 15)); then
        ok "dock-external: the dock and the bar keep to the primary and follow a new one, pass all $all assertions"
    else
        not_ok "dock-external: a clean run passes (passed/failed $all/$failures): $(grep -m3 '^FAIL' "$T/assertions.out" | paste -sd'|' -)"
    fi
    while IFS='|' read -r change what; do
        write_report_run dock-external DOCK-EXTERNAL "$DOCK_EXTERNAL_REPORT" "$change"
        read -r passes failures <<<"$(assertion_counts dock_external_case "$T/dock-external")"
        expect_eq "dock-external: $what fails one assertion" "$((all - 1))/1" "$passes/$failures"
    done <<'CHANGES'
.settled.actionMode = "OVERVIEW"|a session that never left the overview's action mode
.steps.initial.primary = 1|the external display as the first primary
.steps.initial.dockBox.x = 1796|a dock on the external display
.steps.initial.dock.bottomGap = 0|a dock on the primary's bottom edge
.steps.initial.panelBox.width = 2400|a bar across both monitors
.steps.onSecondary += {dockHidden: true, barSolid: true}|the external display's maximised window hiding the dock
.steps.onPrimary.dockHidden = false|a primary's maximised window the dock ignores
.steps.backOnSecondary.barSolid = true|a bar left solid after the window moved away
.steps.overview.views = .steps.overview.views[:1]|an overview on the primary alone
.steps.launcher.scrims[1].launcher = false|a launcher scrim without apex-launcher
.steps.launcher.scrims = .steps.launcher.scrims[:1]|a scrim on the primary alone
.steps.overview.glass.scrims[1] += {radius: 72, resourceScale: 1}|a scale-2 monitor's scrim blurred at scale 1
.steps.swapped.changed = false|a DisplayConfig change the shell never saw
.steps.swapped.dockBox.x = 596|a dock left on the old primary
.steps.swapped.panelBox.x = 0|a bar left on the old primary
.steps.swapped.barSolid = true|a bar solid for a window on the new secondary
.steps.mixedOnExternal.changed = false|a scale change the shell never saw
.steps.mixedOnExternal.panelBox.width = 960|a bar the scale change left at the old width
.steps.mixedOnExternal.desktopGlass.dock.radius = 112|dock glass still blurring at scale 2 on a scale-1 monitor
.steps.mixedOnExternal.desktopGlass.bar.box.height = 0|bar glass on an empty box
.steps.mixedOnExternal.overview.scrims = [{visible: true, box: {x: 0, y: 0, width: 3360, height: 1080}, launcher: false}]|one stage-wide scrim, not one per monitor
.steps.mixedOnExternal.overview.scrims[1].box = {x: 1440, y: 0, width: 960, height: 540}|a scrim left at the monitor's old size
.steps.mixedOnExternal.glass.scrims[1].clone = {x: 1440, y: 0, width: 1920, height: 1080}|a scrim whose clone is not moved by its monitor's origin
.steps.mixedOnExternal.glass.scrims[1] += {radius: 144, resourceScale: 2}|the scale-1 display's scrim blurred at the panel's scale
.steps.mixedOnExternal.glass.cost.perMonitor = 14|scrims per monitor modelled no cheaper than one stage-wide scrim
.steps.mixedOnExternal.desktopGlass.scrims[1].enabled = true|a hidden scrim still blurring
.steps.mixed.barSolid = false|a bar translucent over the panel's maximised window
.steps.mixed.glass.dock.resourceScale = 1|dock glass left at scale 1 back on the panel
CHANGES
    write_report_run dock-external DOCK-EXTERNAL '{error: "G2 runs 1 monitor(s), not two\ndock-external.js:98"}' .
    read -r passes failures <<<"$(assertion_counts dock_external_case "$T/dock-external")"
    expect_eq "dock-external: a probe error fails once" "3/1 G2 runs 1 monitor(s), not two" \
        "$passes/$failures $(sed -n 's/^FAIL dock-external: //p' "$T/assertions.out")"
}

test_idle() {
    local change what passes failures all
    write_idle_run .
    read -r all failures <<<"$(assertion_counts idle_desktop "$T/idle")"
    if ((failures == 0 && all > 10)); then
        ok "idle: no frame and no relayout over 10 s, every feature on, the counter checked, pass all $all assertions"
    else
        not_ok "idle: a clean run passes (passed/failed $all/$failures): $(grep -m3 '^FAIL' "$T/assertions.out" | paste -sd'|' -)"
    fi
    while IFS='|' read -r change what; do
        write_idle_run "$change"
        read -r passes failures <<<"$(assertion_counts idle_desktop "$T/idle")"
        expect_eq "idle: $what fails one assertion" "$((all - 1))/1" "$passes/$failures"
    done <<'CHANGES'
.idle += {afterPaints: 1, frames: [$frame]}|a frame painted while idle
.idle.afterPaints = 2|paints the counter saw but did not keep
.idle.relayouts = {"StLabel.clock < StBin.clock-display": 10}|a relayout queued while idle
.settled.easing = [{actor: ["ApexDock#apexDock"], properties: ["translation-y"]}]|an actor still easing when the window opens
.settled.dock.rested = false|a dock that never came to rest
.settled.overview = true|an overview left open
.settled.barGlass = false|a bar without its glass
.settled.actionMode = "OVERVIEW"|an action mode settleDesktop did not bring back to NORMAL
.windowMs = 2000|a window shorter than 10 s
.control.afterPaints = 0|a counter that counts nothing
.control.frames[0].damage.under = []|a control frame whose actors went unnamed
.quickSettings += {afterPaints: 146, frames: [$frame]}|Quick Settings and the bar redrawing each other while idle
.reduceTransparency.idle.afterPaints = 1|a paint while idle with Reduce Transparency
.reduceTransparency.quickSettings.afterPaints = 1|a paint with Quick Settings open and Reduce Transparency
.overview.idle += {afterPaints: 1, frames: [$frame]}|a frame painted in the idle overview
.overview.idle.relayouts = {"MetaBackgroundActor < ClutterActor": 3}|a relayout queued in the idle overview
.overview.wallpapers = 0|an idle overview whose thumbnails draw no wallpaper
CHANGES
    # shellcheck disable=SC2016 # a jq variable
    write_idle_run '.idle += {afterPaints: 1, frames: [$frame]}'
    assertion_counts idle_desktop "$T/idle" >/dev/null
    expect_eq "idle: a painted frame is named, with its damage, the actors under it and their ui/apex/ files" \
        "1 painted: at 4210 ms, 1 rectangle(s) in 600,838 240x62 under StIcon.apex-dock-trash < ApexDock#apexDock; from ApexDock in ui/apex/dock/dock.js; apex-dock-trash in ui/apex/dock/trash.js" \
        "$(sed -n 's/^FAIL idle: over 10000 ms of an idle desktop the stage paints no frame (\(.*\))$/\1/p' "$T/assertions.out")"
    write_idle_run .
    sed -i '/feature polkit enabled/d' "$T/idle/idle.log"
    read -r passes failures <<<"$(assertion_counts idle_desktop "$T/idle")"
    expect_eq "idle: a feature of layer.js's list that did not enable fails one assertion" "$((all - 1))/1" "$passes/$failures"
    write_idle_run '{error: "idle.js: settle never returned\nidle.js:150"}'
    read -r passes failures <<<"$(assertion_counts idle_desktop "$T/idle")"
    expect_eq "idle: a probe error fails once, with its message, not every assertion after it" \
        "$((all - 10))/1 idle.js: settle never returned" \
        "$passes/$failures $(sed -n 's/^FAIL idle: //p' "$T/assertions.out")"
}

# shellcheck disable=SC2016 # a jq program
readonly GLASS_LOAD_REPORT='def run($frames; $content; $surfaces): {frames: $frames, contentFrames: $content, extraFrames: ($frames - $content),
    surfaces: $surfaces, missed: [], boxes: {}, trace: [], modelledMsPerFrame: 0.2};
  {scenarioMs: 5000, toggles: 20, scenarios: {
    A: {glass: run(151; 150; {dock: {reblurs: 150, partial: 0, contentUnder: 150}, "quick-settings": {reblurs: 0, partial: 0, contentUnder: 0}}),
        reduceTransparency: run(151; 150; {})},
    B: {glass: run(142; 137; {dock: {reblurs: 40, partial: 0, contentUnder: 38}, "quick-settings": {reblurs: 36, partial: 0, contentUnder: 34},
                              calendar: {reblurs: 53, partial: 0, contentUnder: 52}, panel: {reblurs: 3, partial: 1, contentUnder: 0}}),
        reduceTransparency: run(142; 137; {})},
    C: {glass: run(241; 210; {panel: {reblurs: 57, partial: 0, contentUnder: 0}, dock: {reblurs: 240, partial: 0, contentUnder: 210}}),
        reduceTransparency: run(211; 191; {})}}}'

write_glass_load_run() {
    local change=$1 dir=$T/glass-load
    rm -rf "$dir" && mkdir -p "$dir"
    printf 'APEXG2-GLASS-LOAD %s\n' "$(jq -nc "$GLASS_LOAD_REPORT | $change")" >"$dir/glass-load.log"
    echo 'glass-load exit=0 secs=95 marker-after-exit=no' >"$dir/results-main.txt"
}

test_glass_load() {
    local change what passes failures all
    write_glass_load_run .
    read -r all failures <<<"$(assertion_counts glass_load "$T/glass-load")"
    if ((failures == 0 && all > 8)); then
        ok "glass-load: forwarded damage, re-blurs where the content changes and no extra frames pass all $all assertions"
    else
        not_ok "glass-load: a clean run passes (passed/failed $all/$failures): $(grep -m3 '^FAIL' "$T/assertions.out" | paste -sd'|' -)"
    fi
    while IFS='|' read -r change what; do
        write_glass_load_run "$change"
        read -r passes failures <<<"$(assertion_counts glass_load "$T/glass-load")"
        expect_eq "glass-load: $what fails one assertion" "$((all - 1))/1" "$passes/$failures"
    done <<'CHANGES'
.scenarios.A.glass.missed = [{atMs: 900, surface: "dock", overlap: "part"}]|a change under the dock it did not re-blur at once
.scenarios.A.glass.frames = 300|the bar and Quick Settings keeping each other drawing
.scenarios.A.glass.surfaces.panel = {reblurs: 1, partial: 0, contentUnder: 0}|the bar re-blurring with nothing under it
.scenarios.A.glass.surfaces.dock.reblurs = 100|a dock that re-blurred less often than the video changed
.scenarios.A.glass.surfaces.dock.reblurs = 151|a dock that re-blurred once more than the video changed
.scenarios.A.reduceTransparency.surfaces = {dock: {reblurs: 1, partial: 0, contentUnder: 1}}|glass left on with Reduce Transparency
.scenarios.B.glass.missed = [{atMs: 3100, surface: "calendar", overlap: "out"}]|a window moved under the calendar without a re-blur
.scenarios.B.glass.frames = 160|extra frames while a window is dragged
.scenarios.B.glass.surfaces.calendar.contentUnder = 0|a drag that never reached the calendar
.scenarios.B.glass.surfaces.panel.reblurs = 5|the bar re-blurring more than once per open or close of a bar menu
.scenarios.C.glass.missed = [{atMs: 400, surface: "spotlight", overlap: "part"}]|a missed re-blur under Spotlight
.scenarios.C.glass.surfaces.scrim = {reblurs: 10, partial: 0, contentUnder: 6, empty: 1}|a scrim drawn before it has its box
CHANGES
    write_glass_load_run '.scenarios.A.glass.tail = {dock: "in", "quick-settings": "in"}'
    read -r passes failures <<<"$(assertion_counts glass_load "$T/glass-load")"
    expect_eq "glass-load: the frame before counting, repainting the window's earlier damage, is not a re-blur" "$all/0" "$passes/$failures"
    write_glass_load_run '.scenarios.B.glass.surfaces.panel.reblurs = 4'
    read -r passes failures <<<"$(assertion_counts glass_load "$T/glass-load")"
    expect_eq "glass-load: one bar re-blur per menu open or close in B passes" "$all/0" "$passes/$failures"
    write_glass_load_run '.scenarios.C.glass.frames = 400'
    read -r passes failures <<<"$(assertion_counts glass_load "$T/glass-load")"
    expect_eq "glass-load: C's frame count is reported, not asserted" "$all/0" "$passes/$failures"
    write_glass_load_run '.scenarios.A.glass.frames = 300'
    assertion_counts glass_load "$T/glass-load" >/dev/null
    expect_eq "glass-load: extra frames are named with both counts" 1 \
        "$(grep -c '^FAIL glass-load A: glass adds at most 1 % frames over Reduce Transparency, per change under it (300/150 against 151/150; ' "$T/assertions.out")"
    write_glass_load_run '{error: "the load window never mapped in 10000 ms\nglass-load.js:170"}'
    read -r passes failures <<<"$(assertion_counts glass_load "$T/glass-load")"
    expect_eq "glass-load: a probe error fails once" "2/1 the load window never mapped in 10000 ms" \
        "$passes/$failures $(sed -n 's/^FAIL glass-load: //p' "$T/assertions.out")"
}

write_glass_stress_run() {
    local synthetic=$1 real=$2 dir=$T/glass-stress
    rm -rf "$dir" && mkdir -p "$dir"
    {
        printf 'APEXG2-GLASS %s\n' "$(jq -nc "{patched: true, stress: {seconds: 60, paint: null, stock: false, frames: 1800, clipped: 900, compared: 45, black: 0, stale: 0, unequal: 0}} | $synthetic")"
        printf 'APEXG2-GLASS-LOAD-STRESS %s\n' "$(jq -nc "{seconds: 60, frames: 1810, contentFrames: 1800, extraFrames: 10, surfaces: {}, missed: [], boxes: {}, trace: [], modelledMsPerFrame: 0.2} | $real")"
    } >"$dir/glass-stress.log"
    echo 'glass-stress exit=0 secs=160 marker-after-exit=no' >"$dir/results-main.txt"
}

test_glass_stress() {
    local synthetic real what passes failures all
    write_glass_stress_run . .
    read -r all failures <<<"$(assertion_counts glass_stress "$T/glass-stress")"
    if ((failures == 0 && all > 4)); then
        ok "glass-stress: 60 s on the synthetic box and on the real ones pass all $all assertions"
    else
        not_ok "glass-stress: a clean run passes (passed/failed $all/$failures): $(grep -m3 '^FAIL' "$T/assertions.out" | paste -sd'|' -)"
    fi
    while IFS='|' read -r synthetic real what; do
        write_glass_stress_run "$synthetic" "$real"
        read -r passes failures <<<"$(assertion_counts glass_stress "$T/glass-stress")"
        expect_eq "glass-stress: $what fails one assertion" "$((all - 1))/1" "$passes/$failures"
    done <<'CHANGES'
.stress.seconds = 30|.|a synthetic stress shorter than 60 s
.stress.black = 1|.|a black frame
.stress.stale = 2|.|stale frames
.stress.unequal = 1|.|a compared frame unlike a full redraw
.|.seconds = 10|a real-box stress shorter than 60 s
.|.missed = [{atMs: 5000, surface: "dock", overlap: "part"}]|a change under the dock it did not re-blur at once
CHANGES
}

fixtures_report() {
    local part
    for part in main kernel fedora; do
        printf '%s\n' "$1" >"$T/fixtures/fixtures-$part.txt"
    done
}

# What the shell reads: network.js through libnm, bluetooth.js through gnome-bluetooth,
# system.js the display device's properties and appMenu.js switcheroo-control's.
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
const switcheroo = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SYSTEM, Gio.DBusProxyFlags.NONE, null,
    'net.hadess.SwitcherooControl', '/net/hadess/SwitcherooControl', 'net.hadess.SwitcherooControl', null);
// network.js's scan: request one, then wait for LastScan to move, its spinner turning meanwhile.
const lastScan = device?.last_scan;
let scanFinishes = false;
device?.connect('notify::last-scan', () => (scanFinishes = device.last_scan !== lastScan));
device?.request_scan_async(null, (d, result) => d.request_scan_finish(result));
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
            full: nm.connectivity === NM.ConnectivityState.FULL, wireless: nm.wireless_enabled, scanFinishes},
        battery: {present: upower.get_cached_property('IsPresent')?.unpack() ?? null,
            percentage: upower.get_cached_property('Percentage')?.unpack() ?? null},
        connectedBluetooth: connected,
        hasDualGpu: switcheroo.get_cached_property('HasDualGpu')?.unpack() ?? null,
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

test_part_ran() {
    local run=$T/part-run c passes failures
    local -a cases
    mkdir -p "$run"
    # shellcheck disable=SC2016 # expanded by the inner bash
    read -ra cases <<<"$(bash -c '. "$1/parts.sh"; echo "${PR_CASES[*]}"' _ "$HERE")"
    : >"$run/results-pr.txt"
    for c in "${cases[@]}"; do
        echo "$c exit=0 secs=1 marker-after-exit=no" >>"$run/results-pr.txt"
        [[ $c == fault-abort ]] || echo 'APEXG2 {"probe": true}' >"$run/$c.log"
    done
    read -r passes failures <<<"$(assertion_counts part_ran "$run" pr "${cases[@]}")"
    expect_eq "parts: every case of the pr part ran and reported (fault-abort may abort first)" "${#cases[@]}/0" "$passes/$failures"
    sed -i '/^indicators-dark /d' "$run/results-pr.txt"
    read -r passes failures <<<"$(assertion_counts part_ran "$run" pr "${cases[@]}")"
    expect_eq "parts: a case the part skipped fails, never passes unasserted" "$((${#cases[@]} - 1))/1" "$passes/$failures"
    echo "indicators-dark exit=0 secs=1 marker-after-exit=no" >>"$run/results-pr.txt"
    : >"$run/large-text.log"
    read -r passes failures <<<"$(assertion_counts part_ran "$run" pr "${cases[@]}")"
    expect_eq "parts: a case that ran but reported nothing fails" "$((${#cases[@]} - 1))/1" "$passes/$failures"
    printf '%s\n' 'default exit=0 secs=91 marker-after-exit=no' 'indicators exit=124 secs=150 marker-after-exit=yes' \
        >"$run/results-pr.txt"
    read -r passes failures <<<"$(assertion_counts hung_part "$run" pr)"
    expect_eq "parts: a hung case in the pr part fails once" "0/1" "$passes/$failures"
    expect_eq "parts: and the failure names the part, the case and its limit" 1 \
        "$(grep -c '^FAIL direct.sh pr: indicators had no report within 150 s; G2 stops at a hung case' "$T/assertions.out")"
}

test_parental_controls_ready() {
    local run=$T/parental-run failed passes failures
    failed='(gnome-shell:2405): GNOME Shell-CRITICAL **: 09:41:00.000: Failed to get parental controls settings: Gio.DBusError: GDBus.Error:org.freedesktop.DBus.Error.Spawn.ExecFailed: Cannot launch daemon'
    mkdir -p "$run"
    echo 'APEXG2 {"probe": true}' >"$run/dock-pin.log"
    read -r passes failures <<<"$(assertion_counts parental_controls_ready dock-pin "$run/dock-pin.log")"
    expect_eq "parental controls: a log without the failed read passes" "1/0" "$passes/$failures"
    echo "$failed" >>"$run/dock-pin.log"
    read -r passes failures <<<"$(assertion_counts parental_controls_ready dock-pin "$run/dock-pin.log")"
    expect_eq "parental controls: a failed read fails, naming the error" "0/1 1" \
        "$passes/$failures $(grep -c 'hides every app: Gio.DBusError: GDBus.Error:org.freedesktop.DBus.Error.Spawn.ExecFailed' "$T/assertions.out")"
    echo 'APEXG2 {"probe": true}' >"$run/dock-pin.log"
    echo "$failed" >"$run/dock-pin.late.log"
    read -r passes failures <<<"$(assertion_counts parental_controls_ready dock-pin "$run/dock-pin.log")"
    expect_eq "parental controls: one in the late first start fails too" "0/1" "$passes/$failures"
}

test_no_st_css_warning() {
    local run=$T/st-css-run warning passes failures
    warning="(gnome-shell:42): St-WARNING **: 09:41:00.000: Ignoring length property that isn't a number at line 4217, col 16"
    mkdir -p "$run"
    printf '%s\n' 'APEXG2 {"probe": true}' "(gnome-shell:42): St-CRITICAL **: 09:41:00.000: st_widget_get_theme_node called on the widget" \
        >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts no_st_css_warning default "$run/default.log")"
    expect_eq "St CSS warnings: a log without one passes, whatever else St says" "1/0" "$passes/$failures"
    printf '%s\n' "$warning" "$warning" >>"$run/default.log"
    read -r passes failures <<<"$(assertion_counts no_st_css_warning default "$run/default.log")"
    expect_eq "St CSS warnings: a declaration St ignored fails once" "0/1" "$passes/$failures"
    expect_eq "St CSS warnings: and the failure counts it with its line" 1 "$(grep -c "warning: 2 Ignoring length property that isn't a number at line 4217, col 16$" "$T/assertions.out")"
    echo 'APEXG2 {"probe": true}' >"$run/default.log"
    echo "$warning" >"$run/default.late.log"
    read -r passes failures <<<"$(assertion_counts no_st_css_warning default "$run/default.log")"
    expect_eq "St CSS warnings: one in the late first start fails too" "0/1" "$passes/$failures"
}

test_no_nan_allocation() {
    local run=$T/nan-run critical passes failures
    critical="Clutter-CRITICAL **: clutter_actor_allocate: assertion '!isnan (real_allocation.x1) && !isnan (real_allocation.x2)' failed"
    mkdir -p "$run"
    echo 'APEXG2 {"probe": true}' >"$run/glass-load.log"
    read -r passes failures <<<"$(assertion_counts no_nan_allocation glass-load "$run/glass-load.log")"
    expect_eq "NaN allocations: a clean log passes" "1/0" "$passes/$failures"
    printf '%s\n' "$critical" "$critical" >>"$run/glass-load.log"
    read -r passes failures <<<"$(assertion_counts no_nan_allocation glass-load "$run/glass-load.log")"
    expect_eq "NaN allocations: a case that survives two fails once" "0/1" "$passes/$failures"
    expect_eq "NaN allocations: and the failure counts them" 1 "$(grep -c 'per log: glass-load.log:2$' "$T/assertions.out")"
    echo 'APEXG2 {"probe": true}' >"$run/glass-load.log"
    echo "$critical" >"$run/glass-load.late.log"
    read -r passes failures <<<"$(assertion_counts no_nan_allocation glass-load "$run/glass-load.log")"
    expect_eq "NaN allocations: one in the late first start fails too" "0/1" "$passes/$failures"
    rm "$run/glass-load.late.log"
    printf '%s\n' 'APEXG2-LATE startup completed while main.js imported the probe' "$critical" >"$run/glass-load.log"
    read -r passes failures <<<"$(assertion_counts no_nan_allocation glass-load "$run/glass-load.log")"
    expect_eq "NaN allocations: a late start CI kept as its only log fails too (G2_LATE=report)" "0/1 1" \
        "$passes/$failures $(grep -c 'per log: glass-load.log:1$' "$T/assertions.out")"
}

test_no_spurious_allocation() {
    local run=$T/spurious-run layer passes failures
    layer='Clutter-WARNING **: 09:41:00.000: Spurious clutter_actor_allocate called for actor 0x55/apex-shadow-apex-shadow-layer [StWidget] which isn'"'"'t a descendent of the stage!'
    mkdir -p "$run"
    echo 'APEXG2 {"probe": true}' >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts no_spurious_allocation default "$run/default.log")"
    expect_eq "spurious allocation: a clean log passes" "1/0" "$passes/$failures"
    printf '%s\n' "$layer" 'APEXG2 {"probe": true}' "${layer/0x55/0x66}" >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts no_spurious_allocation default "$run/default.log")"
    expect_eq "spurious allocation: two before shutdown fail, counted by actor" "0/1 1" \
        "$passes/$failures $(grep -c '^FAIL default: spurious allocations, count and actor: 2 apex-shadow-apex-shadow-layer \[StWidget\]$' "$T/assertions.out")"
    echo 'APEXG2 {"probe": true}' >"$run/default.log"
    echo "${layer/apex-shadow-apex-shadow-layer \[StWidget\]/panelBox [StBoxLayout]}" >"$run/default.late.log"
    read -r passes failures <<<"$(assertion_counts no_spurious_allocation default "$run/default.log")"
    expect_eq "spurious allocation: one in the late first start's log fails too, naming it" "0/1 1" \
        "$passes/$failures $(grep -c '^FAIL default: spurious allocations, count and actor: 1 panelBox \[StBoxLayout\]$' "$T/assertions.out")"
    rm "$run/default.late.log"
}

test_clean_shutdown() {
    local run=$T/shutdown-run offstage passes failures
    offstage='St-CRITICAL **: 09:41:00.000: st_widget_get_theme_node called on the widget [0x55 StBoxLayout:insensitive "panelBox"] which is not in the stage.'
    mkdir -p "$run"
    printf '%s\n' 'APEXG2 {"probe": true}' '** Message: 09:41:00.000: Shutting down GNOME Shell' >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts clean_shutdown default "$run/default.log")"
    expect_eq "shutdown: a clean one passes" "1/0" "$passes/$failures"
    printf '%s\n' "$offstage" 'APEXG2 {"probe": true}' '** Message: 09:41:00.000: Shutting down GNOME Shell' >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts clean_shutdown default "$run/default.log")"
    expect_eq "shutdown: the warning before it is another check's" "1/0" "$passes/$failures"
    printf '%s\n' '** Message: 09:41:00.000: Shutting down GNOME Shell' "$offstage" >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts clean_shutdown default "$run/default.log")"
    expect_eq "shutdown: the panel laid out off the stage after it fails, naming the actor" "0/1 1" \
        "$passes/$failures $(grep -c '^FAIL default: at shutdown: .*"panelBox"\] which is not in the stage.$' "$T/assertions.out")"
    printf '%s\n' 'APEXG2 {"probe": true}' >"$run/default.log"
    printf '%s\n' '** Message: 09:41:00.000: Shutting down GNOME Shell' "$offstage" >"$run/default.late.log"
    read -r passes failures <<<"$(assertion_counts clean_shutdown default "$run/default.log")"
    expect_eq "shutdown: and so does it in the late first start's log" "0/1" "$passes/$failures"
    rm "$run/default.late.log"
    printf '%s\n' '** Message: 09:41:00.000: Shutting down GNOME Shell' \
        "Shell-CRITICAL **: 09:41:00.000: shell_global_get: assertion 'the_object' failed" >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts clean_shutdown default "$run/default.log")"
    expect_eq "shutdown: a window effect reaching the disposed global fails, quoting the shell" "0/1 1" \
        "$passes/$failures $(grep -c "^FAIL default: at shutdown: shell_global_get: assertion 'the_object' failed$" "$T/assertions.out")"
    printf '%s\n' '** Message: 09:41:00.000: Shutting down GNOME Shell' \
        "GLib-GObject-CRITICAL **: 09:41:00.000: g_object_get: assertion 'G_IS_OBJECT (object)' failed" >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts clean_shutdown default "$run/default.log")"
    expect_eq "shutdown: and so does reading its window manager through NULL" "0/1" "$passes/$failures"
    local ibus="(ibus-daemon:1240): GLib-GObject-CRITICAL **: 09:41:00.000: g_object_ref: assertion 'G_IS_OBJECT (object)' failed"
    printf '%s\n' '** Message: 09:41:00.000: Shutting down GNOME Shell' "$ibus" \
        '(/usr/libexec/xdg-desktop-portal:1311): xdg-desktop-portal-WARNING **: 09:41:00.000: lost the bus' >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts clean_shutdown default "$run/default.log")"
    expect_eq "shutdown: ibus-daemon's own CRITICAL as it loses the display is not the shell's" "1/0" "$passes/$failures"
    expect_eq "shutdown: but prints as a note, as does another process's WARNING" \
        "# note ibus-daemon: GLib-GObject-CRITICAL **: 09:41:00.000: g_object_ref: assertion 'G_IS_OBJECT (object)' failed|# note xdg-desktop-portal: xdg-desktop-portal-WARNING **: 09:41:00.000: lost the bus" \
        "$(grep '^# note ' "$T/assertions.out" | paste -sd'|' -)"
    printf '%s\n' '** Message: 09:41:00.000: Shutting down GNOME Shell' "${ibus/ibus-daemon:1240/gnome-shell:766}" >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts clean_shutdown default "$run/default.log")"
    expect_eq "shutdown: the same line from gnome-shell itself fails" "0/1" "$passes/$failures"
    printf '%s\n' '** Message: 09:41:00.000: Shutting down GNOME Shell' "$ibus" \
        "Shell-CRITICAL **: 09:41:00.000: shell_global_get: assertion 'the_object' failed" >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts clean_shutdown default "$run/default.log")"
    expect_eq "shutdown: and an unprefixed shell_global_get fails after another process's note" "0/1 1" \
        "$passes/$failures $(grep -c "^FAIL default: at shutdown: shell_global_get: assertion 'the_object' failed$" "$T/assertions.out")"
}

test_no_disposed_at_shutdown() {
    local run=$T/disposed-shutdown-run disposed frame passes failures
    disposed='Gjs-CRITICAL **: 09:41:00.000: Object Gjs_ui_messageTray_MessageTray (0x55e780c0), has been already disposed — impossible to access it.'
    frame='#0   7ffd b   resource:///org/gnome/shell/ui/messageTray.js:1062 (29fd @ 15)'
    mkdir -p "$run"
    printf '%s\n' "$disposed" '== Stack trace for context 0x55 ==' "$frame" '** Message: 09:41:00.000: Shutting down GNOME Shell' >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts no_disposed_at_shutdown default "$run/default.log")"
    expect_eq "disposed at shutdown: one before it is another check's" "1/0" "$passes/$failures"
    printf '%s\n' '** Message: 09:41:00.000: Shutting down GNOME Shell' "$disposed" '== Stack trace for context 0x55 ==' "$frame" >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts no_disposed_at_shutdown default "$run/default.log")"
    expect_eq "disposed at shutdown: the tray's banner timeout after it fails, naming the object and the frame" "0/1 1" \
        "$passes/$failures $(grep -c '^FAIL default: .*touched: Gjs_ui_messageTray_MessageTray at resource:///org/gnome/shell/ui/messageTray.js:1062$' "$T/assertions.out")"
    echo 'APEXG2 {"probe": true}' >"$run/default.log"
    printf '%s\n' '** Message: 09:41:00.000: Shutting down GNOME Shell' "$disposed" >"$run/default.late.log"
    read -r passes failures <<<"$(assertion_counts no_disposed_at_shutdown default "$run/default.log")"
    expect_eq "disposed at shutdown: and so does one with no stack, in the late first start's log" "0/1 1" \
        "$passes/$failures $(grep -c '^FAIL default: .*touched: Gjs_ui_messageTray_MessageTray$' "$T/assertions.out")"
    rm "$run/default.late.log"
}

readonly EXIT_CUT='{"changed":2,"notify::has-calendars":1,"installed-changed":4}'

test_exit_cut() {
    local want_pass what report passes failures
    while IFS='|' read -r want_pass what report; do
        if [[ -n $report ]]; then printf 'APEXG2-EXIT %s\n' "$report" >"$T/exit.log"; else : >"$T/exit.log"; fi
        read -r passes failures <<<"$(assertion_counts exit_cut default "$T/exit.log")"
        expect_eq "exit: $what" "$want_pass/$((1 - want_pass))" "$passes/$failures"
    done <<CASES
1|an idle tray and every date-menu path blocked pass|{"tray":true,"cut":$EXIT_CUT}
0|a banner still up fails|{"tray":false,"cut":$EXIT_CUT}
0|a path that blocked no handler fails|{"tray":true,"cut":{"changed":2,"notify::has-calendars":0,"installed-changed":4}}
0|a path missing from the cut fails|{"tray":true,"cut":{"changed":2,"installed-changed":4}}
0|no report fails|
CASES
}

test_shutdown_banner_case() {
    local run=$T/shutdown-banner passes failures status pending armed cut shutdown what
    mkdir -p "$run"
    while IFS='|' read -r failures status pending armed cut shutdown what; do
        echo "shutdown-banner exit=$status secs=5 marker-after-exit=no" >"$run/results-main.txt"
        echo "APEXG2-SHUTDOWN-BANNER {\"pending\":$pending,\"armed\":$armed,\"cut\":${cut:-$EXIT_CUT}}" >"$run/shutdown-banner.log"
        echo "$shutdown" >>"$run/shutdown-banner.log"
        read -r passes _ <<<"$(assertion_counts shutdown_banner_case "$run")"
        expect_eq "shutdown-banner: $what fails $failures of 4" "$failures" $((4 - passes))
    done <<'CHANGES'
0|0|true|true||** Message: 09:41:00.000: Shutting down GNOME Shell|a notification pending, the timeout armed and the date menu cut as the shell exits
1|134|true|true||** Message: 09:41:00.000: Shutting down GNOME Shell|the shell aborting in the shutdown loop
1|0|false|true||** Message: 09:41:00.000: Shutting down GNOME Shell|no notification pending
1|0|true|false||** Message: 09:41:00.000: Shutting down GNOME Shell|no timeout armed
1|0|true|true|{"changed":0,"notify::has-calendars":1,"installed-changed":4}|** Message: 09:41:00.000: Shutting down GNOME Shell|a date-menu path with no handler blocked
1|0|true|true|||a log without the shutdown
CHANGES
}

readonly SESSION_REPORT='{"settings": {"font-name": "Adwaita Sans 10.125", "document-font-name": "Adwaita Sans 10.125",
    "monospace-font-name": "JetBrains Mono 9.75", "font-hinting": "none", "icon-theme": "Apex"},
  "shell": {"font": "Adwaita Sans 10.125", "iconTheme": "Apex"},
  "apexSymbolic": ["battery-level-80-symbolic", "pan-end-symbolic", "window-close-symbolic"],
  "fontconfig": {"sans": {"family": "Adwaita Sans", "file": "/usr/share/fonts/adwaita-sans-fonts/AdwaitaSans-Regular.ttf", "features": ["ss03"]},
    "mono": {"family": "JetBrains Mono", "file": "/usr/share/fonts/jetbrains-mono-fonts/JetBrainsMono-Regular.otf", "features": []}},
  "drawn": {"clock": "Adwaita Sans"},
  "icons": {"bar": [{"icon": "battery-level-80-symbolic", "file": "/usr/share/icons/Apex/symbolic/battery-level-80-symbolic.svg", "app": null}],
    "dock": [{"icon": "org.gnome.Nautilus", "file": "/usr/share/icons/Apex/scalable/apps/org.gnome.Nautilus.svg", "app": "org.gnome.Nautilus.desktop"},
      {"icon": "application-x-executable", "file": "/usr/share/icons/Adwaita/scalable/mimetypes/application-x-executable.svg",
       "app": "io.github.apex_linux.G2Stub1.desktop"}],
    "dash": null,
    "quickSettings": [{"icon": ". GThemedIcon screenshooter-symbolic screenshooter",
      "file": "/org/gnome/shell/icons/scalable/actions/screenshooter-symbolic.svg", "app": null}]}}'

test_session_defaults() {
    local passes failures change what stubs
    stubs=$(sed -n "s/^readonly STUB_APPS='\(.*\)'\$/\1/p" "$HERE/direct.sh" | tr ' ' '\n' | sed 's/$/.desktop/' | paste -sd' ' -)
    # shellcheck disable=SC2016 # expanded by the inner bash
    expect_eq "session defaults: assert.sh's fixture apps are direct.sh's STUB_APPS" "$stubs" \
        "$(bash -c '. "$1/assert.sh"; echo "${FIXTURE_APPS[*]}"' _ "$HERE")"
    while IFS='|' read -r failures change what; do
        printf 'APEXG2-SESSION %s\n' "$(jq -nc "$SESSION_REPORT | $change")" >"$T/session.log"
        read -r passes _ <<<"$(assertion_counts session_defaults default "$T/session.log")"
        expect_eq "session defaults: $what fails $failures of 7" "$failures" $((7 - passes))
    done <<'CHANGES'
0|.|apex-desktop's defaults, a fixture app's generic icon and the shell's own screenshooter
1|.settings["monospace-font-name"] = "DejaVu Sans Mono 10"|another monospace font in the settings
1|.settings["icon-theme"] = "Adwaita"|another icon theme in the settings
1|.shell.iconTheme = "Adwaita"|a shell that draws another icon theme
1|.fontconfig.sans.features = []|Adwaita Sans without ss03
1|.fontconfig.mono = {family: "DejaVu Sans Mono", file: "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf", features: []}|no JetBrains Mono, so fontconfig falls back
1|.drawn.clock = "Cantarell"|a clock drawn in another family
1|.icons.bar[0].file = "/usr/share/icons/Adwaita/symbolic/status/battery-level-80-symbolic.svg"|an Adwaita glyph in the bar
1|.icons.quickSettings[0].file = null|an icon that resolves nowhere
1|.icons.dock[0].file = "/usr/share/icons/hicolor/scalable/apps/org.gnome.Nautilus.svg"|an image app's icon from outside Apex
1|.icons.quickSettings[0].icon = ". GThemedIcon camera-photo-symbolic"|a shell icon that is not on the list
1|.icons = {bar: [], dock: null, dash: null, quickSettings: []}|no icons reported
1|.apexSymbolic = ["battery-level-80-symbolic", "screenshooter-symbolic"]|an icon listed as the shell's own that Apex now ships
1|.apexSymbolic = []|no Apex Symbolic glyphs reported
7|{error: "sessionDefaultsReport: no panel"}|a probe error
CHANGES
    printf 'APEXG2-SESSION %s\n' "$(jq -nc "$SESSION_REPORT | .icons.bar[0].file = null")" >"$T/session.log"
    assertion_counts session_defaults default "$T/session.log" >/dev/null
    expect_eq "session defaults: a failure names the place and the icon" 1 \
        "$(grep -c '^FAIL default: every icon .* (bar battery-level-80-symbolic: no icon)$' "$T/assertions.out")"
    printf 'APEXG2-SESSION %s\n' "$(jq -nc "$SESSION_REPORT | .fontconfig.mono = {family: \"Noto Sans\", file: \"NotoSans.ttf\", features: []}")" \
        >"$T/session.log"
    assertion_counts session_defaults default "$T/session.log" >/dev/null
    expect_eq "session defaults: a missing JetBrains Mono names the family fontconfig fell back to" 1 \
        "$(grep -c '^FAIL default: fontconfig gives JetBrains Mono .*(got {"family":"Noto Sans",' "$T/assertions.out")"
    printf 'APEXG2-SESSION %s\n' "$(jq -nc "$SESSION_REPORT | .apexSymbolic += [\"switch-on-symbolic\"]")" >"$T/session.log"
    assertion_counts session_defaults default "$T/session.log" >/dev/null
    expect_eq "session defaults: a listed icon Apex ships is named, so it leaves the list" 1 \
        "$(grep -c '^FAIL default: no icon listed .*(listed as shell-only, but /usr/share/icons/Apex has it: switch-on-symbolic)$' "$T/assertions.out")"
}

# One icon per surface probe.js's iconSurfaces opens, each resolved under Apex.
readonly SURFACES_REPORT='{
  "dateMenu": [{"icon": "software-update-available-symbolic", "file": "/usr/share/icons/Apex/symbolic/software-update-available-symbolic.svg", "app": null}],
  "overview": [{"icon": "view-app-grid-symbolic", "file": "/usr/share/icons/Apex/symbolic/view-app-grid-symbolic.svg", "app": null}],
  "launcher": [{"icon": "org.gnome.Nautilus", "file": "/usr/share/icons/Apex/scalable/apps/org.gnome.Nautilus.svg", "app": "org.gnome.Nautilus.desktop"}],
  "spotlight": [{"icon": "edit-find-symbolic", "file": "/usr/share/icons/Apex/symbolic/edit-find-symbolic.svg", "app": null}],
  "switcher": [{"icon": "application-x-executable", "file": "/usr/share/icons/Apex/scalable/mimetypes/application-x-executable.svg", "app": null}],
  "surfaces": [{"icon": "user-home-symbolic", "file": "/usr/share/icons/Apex/symbolic/user-home-symbolic.svg", "app": null}],
  "dialog": [{"icon": "dialog-password-symbolic", "file": "/usr/share/icons/Apex/symbolic/dialog-password-symbolic.svg", "app": null}],
  "endSession": [{"icon": "system-shutdown-symbolic", "file": "/usr/share/icons/Apex/symbolic/system-shutdown-symbolic.svg", "app": null}],
  "screenshot": [{"icon": ". GThemedIcon screenshooter-symbolic screenshooter",
    "file": "/org/gnome/shell/icons/scalable/actions/screenshooter-symbolic.svg", "app": null}]}'

test_session_surface_icons() {
    local passes failures want change what scenes
    while IFS='|' read -r want scenes change what; do
        { printf 'APEXG2-SESSION %s\n' "$(jq -nc "$SESSION_REPORT")"
          [[ $scenes == 1 ]] && printf 'APEXG2-SCENES {}\n'
          [[ $change == - ]] || printf 'APEXG2-SESSION-SURFACES %s\n' "$(jq -nc "$SURFACES_REPORT | $change")"; } >"$T/surfaces.log"
        read -r passes failures <<<"$(assertion_counts session_defaults default "$T/surfaces.log")"
        expect_eq "surface icons: $what" "$want" "$passes/$failures"
    done <<'CHANGES'
16/0|1|.|every surface's icons through Apex, the shell's own screenshooter on the list
15/1|1|.dateMenu[0].file = "/usr/share/icons/Adwaita/symbolic/status/software-update-available-symbolic.svg"|an Adwaita glyph in the date menu
15/1|1|.dialog[0].file = null|a dialog icon that resolves nowhere
15/1|1|.switcher[0] = {icon: "org.gnome.Nautilus", file: "/usr/share/icons/hicolor/scalable/apps/org.gnome.Nautilus.svg", app: null}|a hicolor app icon in the switcher
16/0|1|.switcher[0].file = "/usr/share/icons/Adwaita/scalable/mimetypes/application-x-executable.svg"|the switcher stand-in's generic app icon, from Adwaita, on its list
16/0|1|.spotlight += [{icon: "drive-harddisk", file: "/usr/share/icons/Adwaita/scalable/devices/drive-harddisk.svg", app: null}]|a search provider's full-colour device icon in Spotlight, on its list
15/1|1|.dateMenu += [{icon: "drive-harddisk", file: "/usr/share/icons/Adwaita/scalable/devices/drive-harddisk.svg", app: null}]|that device icon on another surface
15/1|1|.screenshot[0].icon = ". GThemedIcon camera-photo-symbolic"|a resource icon that is not on the list
15/1|1|.spotlight = null|a surface that never opened
15/1|1|.endSession = []|a surface that drew no icon
15/1|1|.screenshot = {error: "no screenshot UI"}|a surface whose opener threw
7/1|1|{error: "surfaceIconsReport: no stage"}|a walk that failed
7/1|1|-|scenes with no walk reported
7/0|0|-|a case without scenes, which opens no surface
CHANGES
    { printf 'APEXG2-SESSION %s\nAPEXG2-SCENES {}\n' "$(jq -nc "$SESSION_REPORT")"
      printf 'APEXG2-SESSION-SURFACES %s\n' "$(jq -nc "$SURFACES_REPORT | .dateMenu[0].file = null")"; } >"$T/surfaces.log"
    assertion_counts session_defaults default "$T/surfaces.log" >/dev/null
    expect_eq "surface icons: a failure names the board, the surface and the icon" 1 \
        "$(grep -c "^FAIL default: every icon board 34's date menu and notifications draws resolves through Apex (dateMenu software-update-available-symbolic: no icon)\$" "$T/assertions.out")"
}

test_repeat_compare() {
    local out status
    printf '%s\n' '# a comment' 'PASS default: the shell exits 0' 'FAIL motion: the easing (got false)' 'GAP  S1b: dots: 3:1 (got [2.86])' \
        'PASS idle: nothing paints' 'PASS idle: nothing paints' >"$T/repeat-1.log"
    cp "$T/repeat-1.log" "$T/repeat-2.log"
    out=$("$HERE/repeat.sh" compare "$T/repeat-1.log" "$T/repeat-2.log") && status=0 || status=$?
    expect_eq "repeat: two identical runs differ nowhere" "0 repeat: 2 runs, 5 assertions, 0 differ" "$status $out"
    printf '%s\n' 'PASS default: the shell exits 0' 'PASS motion: the easing' 'GAP  S1b: dots: 3:1 (got [2.91])' \
        'PASS idle: nothing paints' 'FAIL idle: nothing paints (got 3 frames)' >"$T/repeat-2.log"
    out=$("$HERE/repeat.sh" compare "$T/repeat-1.log" "$T/repeat-2.log") && status=0 || status=$?
    expect_eq "repeat: a fail and a pass of one assertion share a row, and a twice-made one gets a row per time" \
        "1 F P  motion: the easing|P F  idle: nothing paints [2]|repeat: 2 runs, 5 assertions, 2 differ" "$status $(paste -sd'|' - <<<"$out")"
    printf '%s\n' 'PASS default: the probe started (on time)' 'PASS idle: dots at 3:1 (WCAG 1.4.11)' >"$T/repeat-4.log"
    printf '%s\n' 'PASS default: the probe started (late)' 'FAIL idle: dots at 3:1 (WCAG 1.4.11) (got [2.86])' >"$T/repeat-5.log"
    out=$("$HERE/repeat.sh" compare "$T/repeat-4.log" "$T/repeat-5.log") && status=0 || status=$?
    expect_eq "repeat: a pass closing on what its run saw shares a row, and a failure keeps its pass's own parenthesis" \
        "1 P F  idle: dots at 3:1|repeat: 2 runs, 2 assertions, 1 differ" "$status $(paste -sd'|' - <<<"$out")"
    printf '%s\n' 'PASS default: the shell exits 0' >"$T/repeat-3.log"
    out=$({ "$HERE/repeat.sh" compare "$T/repeat-1.log" "$T/repeat-1.log" "$T/repeat-3.log" || :; } | grep -c '^P P -  ')
    expect_eq "repeat: an assertion a run never made shows -" 2 "$out"
    "$HERE/repeat.sh" compare "$T/repeat-1.log" >/dev/null 2>&1 && status=0 || status=$?
    expect_eq "repeat: one log is not a comparison" 2 "$status"
}

test_no_binding_overwritten() {
    local run=$T/keys-run overwritten passes failures
    overwritten='libmutter-WARNING **: 09:41:00.000: Overwriting existing binding of keysym 20 with keysym 20 (keycode 41).'
    mkdir -p "$run"
    echo 'APEXG2 {"probe": true}' >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts no_binding_overwritten default "$run/default.log")"
    expect_eq "key bindings: a clean log passes" "1/0" "$passes/$failures"
    echo "$overwritten" >"$run/default.late.log"
    read -r passes failures <<<"$(assertion_counts no_binding_overwritten default "$run/default.log")"
    expect_eq "key bindings: one overwritten, in the late first start's log too, fails" "0/1" "$passes/$failures"
    expect_eq "key bindings: and the failure quotes mutter" 1 \
        "$(grep -c '^FAIL default: Overwriting existing binding of keysym 20 with keysym 20 (keycode 41).$' "$T/assertions.out")"
    rm "$run/default.late.log"
}

readonly KEYS_ALL_MODES='["NORMAL", "OVERVIEW", "LOCK_SCREEN", "UNLOCK_SCREEN", "LOGIN_SCREEN", "SYSTEM_MODAL", "LOOKING_GLASS", "POPUP"]'
readonly KEYS_REPORT="{bindings: {
    inputSource: {modes: $KEYS_ALL_MODES, accelerators: [\"<Super><Alt>space\", \"XF86Keyboard\"]},
    inputSourceBackward: {modes: $KEYS_ALL_MODES, accelerators: [\"<Shift><Super><Alt>space\", \"<Shift>XF86Keyboard\"]},
    panels: {modes: [\"NORMAL\", \"OVERVIEW\", \"LOCK_SCREEN\", \"UNLOCK_SCREEN\", \"LOGIN_SCREEN\"], accelerators: [\"<Control><Alt>Tab\"]},
    appView: {modes: [\"NORMAL\", \"OVERVIEW\"], accelerators: [\"<Super>a\"]},
    overlay: {modes: [\"NORMAL\", \"OVERVIEW\"], key: \"Super\"}},
  allModes: $KEYS_ALL_MODES,
  pressed: {sources: [\"us\", \"fr\"], first: \"us\", superSpace: {spotlight: true, source: \"us\"},
    superAltSpace: {source: \"fr\"}, shiftSuperAltSpace: {source: \"us\"},
    ctrlAltTab: {groups: [{name: \"Windows\", dock: false}, {name: \"Top Bar\", dock: false}, {name: \"Dash\", dock: true}], dockFocused: true},
    superTap: {overview: true, apps: false}, superA: {overview: true, apps: true}},
  modals: 0}"

test_keys_case() {
    local run=$T/keys passes failures change what
    mkdir -p "$run"
    echo 'keys exit=0 secs=40 marker-after-exit=no' >"$run/results-main.txt"
    while IFS='|' read -r failures change what; do
        printf 'APEXG2-KEYS %s\n' "$(jq -nc "$KEYS_REPORT | $change")" >"$run/keys.log"
        read -r passes _ <<<"$(assertion_counts keys_case "$run")"
        expect_eq "keys: $what fails $failures of 13" "$failures" $((13 - passes))
    done <<'CHANGES'
0|.|the keys as registered and pressed
1|.bindings.inputSource.accelerators = ["<Super>space", "XF86Keyboard"]|GNOME's input source key, on Spotlight's Super+Space
1|.bindings.inputSourceBackward.modes = ["NORMAL"]|a backward input source key in one mode only
1|.bindings.panels.accelerators = []|no Ctrl+Alt+Tab
1|.bindings.overlay.key = "Super_R"|another overlay key
1|.pressed.superSpace.source = "fr"|Super+Space that also switches the input source
1|.pressed.shiftSuperAltSpace.source = "fr"|a Shift variant that does not go back
1|.pressed.ctrlAltTab.groups[2].dock = false|Ctrl+Alt+Tab without the dock
1|.pressed.ctrlAltTab.dockFocused = false|a dock group the focus never reaches
1|.pressed.superTap.overview = false|a Super tap that opens nothing
1|.pressed.superA.apps = false|Super+A that opens the windows, not the launcher
1|.modals = 1|a grab left behind
10|{error: "keysCase: no keyboard"}|a probe error
CHANGES
}

test_no_disposed_apex() {
    local run=$T/disposed-run disposed passes failures
    disposed='Gjs-CRITICAL **: Object St.Widget (0x55e780c0), has been already disposed — impossible to access it.'
    mkdir -p "$run"
    printf '%s\n' "$disposed" '== Stack trace for context 0x55 ==' '#0   7ffd b   file:///w/probe.js:2635 (29fd @ 15)' \
        >"$run/motion.log"
    read -r passes failures <<<"$(assertion_counts no_disposed_apex motion "$run/motion.log")"
    expect_eq "disposed objects: one the probe touches is the probe's own" "1/0" "$passes/$failures"
    printf '%s\n' "$disposed" '== Stack trace for context 0x55 ==' '#0   7ffd b   resource:///org/gnome/shell/ui/dash.js:683 (29fd @ 15)' \
        '#1   7ffd b   resource:///org/gnome/shell/ui/apex/dock/feature.js:83 (29fd @ 15)' 'GNOME Shell-Message: next' >"$run/motion.late.log"
    read -r passes failures <<<"$(assertion_counts no_disposed_apex motion "$run/motion.log")"
    expect_eq "disposed objects: one an Apex frame touches fails, in the late first start's log too" "0/1" "$passes/$failures"
    expect_eq "disposed objects: and the failure names the object and the Apex frame" 1 \
        "$(grep -c 'touched: 1 with an Apex frame, first St.Widget at resource:///org/gnome/shell/ui/apex/dock/feature.js:83' "$T/assertions.out")"
    rm "$run/motion.late.log"
}

test_startup_handler_ran() {
    local run=$T/startup-run passes failures
    local started='GNOME Shell-Message: 09:41:00.000: GNOME Shell started at Mon Sep 28 2026 09:41:00 GMT+0000'
    local late='APEXG2-LATE startup completed while main.js imported the probe; startup-complete again'
    mkdir -p "$run"
    printf '%s\n' "$started" 'APEXG2 {"probe": true}' >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts startup_handler_ran default "$run/default.log")"
    expect_eq "startup: a probe run on time from main.js's handler passes" "1/0" "$passes/$failures"
    printf '%s\n' "$late" "$started" 'APEXG2 {"probe": true}' >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts startup_handler_ran default "$run/default.log")"
    expect_eq "startup: a late import whose startup-complete came again passes, said so" "1/0 1" \
        "$passes/$failures $(grep -c 'ran once, and the probe from it (after the import, from startup-complete again)' "$T/assertions.out")"
    printf '%s\n' "$late" 'APEXG2 {"probe": true}' >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts startup_handler_ran default "$run/default.log")"
    expect_eq "startup: a probe that ran without main.js's handler fails" "0/1" "$passes/$failures"
    printf '%s\n' "$late" "$started" "$started" 'APEXG2 {"probe": true}' >"$run/default.log"
    read -r passes failures <<<"$(assertion_counts startup_handler_ran default "$run/default.log")"
    expect_eq "startup: a handler that ran twice fails" "0/1 1" \
        "$passes/$failures $(grep -c 'ran 2 times, not once' "$T/assertions.out")"
}

test_network_rows_centred() {
    local good passes failures change what
    good='{rows: [
        {box: {y: 100, height: 38}, label: {y: 109, height: 20}, signal: {y: 111, height: 16}, lockBox: {y: 112, height: 14}},
        {box: {y: 140, height: 38}, label: {y: 149, height: 20}, signal: {y: 151, height: 16}, lockBox: null}]}'
    while IFS='|' read -r failures change what; do
        jq -c "$good | $change" -n | sed 's/^/APEXG2-SCENES /' >"$T/rows.log"
        # shellcheck disable=SC2016 # expanded by the inner bash
        read -r passes failures_got <<<"$(bash -c '. "$1/assert.sh"; network_rows_centred light "$(report_of "$2" APEXG2-SCENES)" .rows \
            >"$3" 2>&1; echo "$npass $nfail"' _ "$HERE" "$T/rows.log" "$T/rows.out")"
        expect_eq "network rows: $what fails $failures" "$failures" "$failures_got"
    done <<'CHANGES'
0|.|names, glyphs and locks centred on their rows
1|.rows[0].label.y = 100|network.js's name at the top of the connected row
1|.rows[1].label.y = 100|another row's name at the top
1|.rows[0].lockBox.y = 120|a lock below the row's centre
1|.rows[1].signal.y = 140|a signal glyph at the top
1|.rows = [.rows[0]]|a menu with one network
CHANGES
}

test_pr_assertions() {
    local run=$T/pr-run label rest stray="" missing
    local -a cases fedora
    # shellcheck disable=SC2016 # expanded by the inner bash
    read -ra cases <<<"$(bash -c '. "$1/parts.sh"; echo "${PR_CASES[*]}"' _ "$HERE")"
    # shellcheck disable=SC2016 # expanded by the inner bash
    read -ra fedora <<<"$(bash -c '. "$1/parts.sh"; echo "${PR_FEDORA_CASES[*]}"' _ "$HERE")"
    mkdir -p "$run"
    : >"$run/results-pr.txt"
    : >"$run/results-fedora.txt"
    assertion_counts patched_assertions "$run" pr >/dev/null
    # The Fedora comparison's captures name their pair: Apex's desktop, and safe mode's every scene.
    while read -r _ label rest; do
        label=${label%:}
        [[ $label == captures && ($rest == apex-*-vs-fedora-desktop* || $rest == safe-*-vs-fedora-*) ]] && continue
        [[ " ${cases[*]} ${fedora[*]} " == *" $label "* ]] || stray+=" $label"
    done < <(grep -E '^(PASS|FAIL) ' "$T/assertions.out")
    expect_eq "parts: the pr part asserts no case it does not run" "" "$stray"
    missing=$(grep -c ': direct.sh pr did not run it$' "$T/assertions.out")
    expect_eq "parts: and with none of its cases run, part_ran fails each one" "${#cases[@]}" "$missing"
    missing=$(grep -c ': direct.sh fedora did not run it$' "$T/assertions.out")
    expect_eq "parts: and each of the fedora part's baselines too" "${#fedora[@]}" "$missing"
    expect_eq "parts: CI's pr part compares Apex's desktop with Fedora's" 2 \
        "$(grep -cE '^(PASS|FAIL) captures apex-(light|dark)-vs-fedora-desktop' "$T/assertions.out")"
    expect_eq "parts: and safe mode's desktop and overview, light and dark" 4 \
        "$(grep -cE '^(PASS|FAIL) captures safe-(light|dark)-vs-fedora-(desktop|overview)' "$T/assertions.out")"
    expect_eq "parts: CI's pr assertions check main.js's startup-complete handler ran" 1 \
        "$(grep -c "^FAIL default: main.js's startup-complete handler ran 0 times, not once" "$T/assertions.out")"
    # shellcheck disable=SC2016 # expanded by the inner bash
    expect_eq "parts: main asserts every case, pr only its own" "0 1 0" \
        "$(bash -c '. "$1/assert.sh"; part=main; asserted glass; a=$?; part=pr; asserted glass; b=$?; asserted default; echo "$a $b $?"' _ "$HERE")"
}

test_one_gpu() {
    local failures what menu passes
    while IFS='|' read -r failures what menu; do
        printf 'APEXG2-GPU %s\n' "$menu" >"$T/one-gpu.log"
        read -r passes _ <<<"$(assertion_counts one_gpu_menu dock-one-gpu "$T/one-gpu.log")"
        expect_eq "one GPU: $what fails $failures of 2" "$failures" $((2 - passes))
    done <<'MENUS'
0|stock's menu without the discrete GPU|{"app": "Files", "hasDualGpu": false, "items": ["Open Windows", "New Window", "Unpin", "App Details"]}
1|a menu that still offers it|{"app": "Files", "hasDualGpu": false, "items": ["New Window", "Launch Using Discrete Graphics Card", "Unpin"]}
1|a switcheroo-control still reporting two GPUs|{"app": "Files", "hasDualGpu": true, "items": ["New Window", "Unpin"]}
2|no menu at all|null
MENUS
}

# shellcheck disable=SC2016 # a jq program
readonly NO_DOCK_REPORT='{dock: null, bottom: {stock: 900, hook: 900}, previews: [
    {window: {x: 561, y: 198, width: 317, height: 236}, caption: {x: 602, y: 459, width: 235, height: 29, visible: true}},
    {window: {x: 414, y: 520, width: 290, height: 250}, caption: {x: 520, y: 795, width: 78, height: 29, visible: true}},
    {window: {x: 736, y: 520, width: 290, height: 250}, caption: {x: 842, y: 795, width: 78, height: 29, visible: true}}]}'

test_action_modes() {
    local failures what modes passes
    while IFS='|' read -r failures what modes; do
        if [[ -n $modes ]]; then printf 'APEXG2-MODES %s\n' "$modes" >"$T/modes.log"; else : >"$T/modes.log"; fi
        read -r passes _ <<<"$(assertion_counts action_modes default "$T/modes.log")"
        expect_eq "action modes: $what fails $failures of 2" "$failures" $((2 - passes))
    done <<'MODES'
0|an on-time probe, back on the desktop|{"late": false, "atRun": "OVERVIEW", "atEnd": "NORMAL", "modals": 0, "overview": false}
0|a late one, the same|{"late": true, "atRun": "OVERVIEW", "atEnd": "NORMAL", "modals": 0, "overview": false}
0|a case that ends in the overview|{"late": true, "atRun": "OVERVIEW", "atEnd": "OVERVIEW", "modals": 1, "overview": true}
1|a late probe under main.js's NONE, as a startup overview without its grab leaves it|{"late": true, "atRun": "NONE", "atEnd": "NORMAL", "modals": 0, "overview": false}
1|an OVERVIEW mode left with no modal and the overview closed|{"late": false, "atRun": "OVERVIEW", "atEnd": "OVERVIEW", "modals": 0, "overview": false}
1|a NONE mode under a modal|{"late": true, "atRun": "OVERVIEW", "atEnd": "NONE", "modals": 1, "overview": false}
2|no modes reported|
MODES
}

# shellcheck disable=SC2016 # a jq program
readonly BAR_OVER_FIXTURE='{kind: "text", name: "Desktop", alpha: 1, inactive: false, offscreen: false, ratio: 6.3} as $text
| ($text + {kind: "dot", name: "workspace-dot", alpha: 0.447}) as $inactive
| {box: {x: 0, y: 0, width: 1440, height: 32}, targets: [$text, ($text + {kind: "dot", name: "workspace-dot", ratio: 6.8})]} as $bar
| {previews: [], bar: {overview: ($bar | .targets += [$inactive + {ratio: 2.58}]), desktop: ($bar | .targets += [$inactive + {ratio: 2.32}])}}'

test_bar_over_fixture() {
    local want what change passes failures
    while IFS='|' read -r want what change; do
        if [[ -n $change ]]; then
            printf 'APEXG2-OVERVIEW-WINDOWS %s\n' "$(jq -nc "$BAR_OVER_FIXTURE | $change")" >"$T/no-dock.log"
        else
            : >"$T/no-dock.log"
        fi
        read -r passes failures <<<"$(assertion_counts bar_over_fixture no-dock "$T/no-dock.log")"
        expect_eq "bar over the fixture wallpaper: $what fails $want" "$want" "$failures"
    done <<'CHANGES'
0|text at 6.3:1, the active dot at 6.8:1 and the inactive at today's 2.58:1 and 2.32:1|.
1|the clock at 4.4:1 in the overview|.bar.overview.targets[0].ratio = 4.4
1|the active dot at 2.9:1 on the desktop|.bar.desktop.targets[1].ratio = 2.9
1|the inactive dot below today's 2.32:1 on the desktop|.bar.desktop.targets[2].ratio = 2.31
1|the inactive dot at 3:1 in the overview: the gap must go|.bar.overview.targets[2].ratio = 3
2|the desktop left unmeasured|del(.bar.desktop)
2|nothing measured in the overview|.bar.overview.targets = []
4|a probe error|{error: "overviewWithWindows: 0 of 3 test windows mapped"}
1|no report|
CHANGES
}

# shellcheck disable=SC2016 # a jq program
readonly SOLID_BAR_FROM_TOKENS='{solid: false, background: ($t.apex_bar | hex), boxShadow: null, glass: {enabled: true}} as $glass
| {steps: {unmaximised: $glass, restored: $glass, maximised: {solid: true, background: ($t.apex_bar_solid | hex), glass: {enabled: false},
    boxShadow: {color: ($t.apex_border | hex), inset: false, x: 0, y: 1, blur: 0, spread: 0}}}}'

test_solid_bar() {
    local variant failures what change passes
    for variant in light dark; do
        while IFS='|' read -r failures what change; do
            jq -nc --argjson t "$(tokens_for "$variant")" "$JQ_DEFS $HEX_DEF $SOLID_BAR_FROM_TOKENS | $change" |
                sed 's/^/APEXG2-SOLID-BAR /' >"$T/solid-bar.log"
            read -r passes _ <<<"$(assertion_counts solid_bar case "$T/solid-bar.log" "$variant")"
            expect_eq "solid bar ($variant): $what fails $failures of 3" "$failures" $((3 - passes))
        done <<'CHANGES'
0|glass, solid while maximised, glass again|.
1|a bar that stays glass while maximised|.steps.maximised.solid = false
1|the maximised bar filled with the glass tint|.steps.maximised.background = ($t.apex_bar | hex)
1|its glass left on|.steps.maximised.glass.enabled = true
1|no line under it|.steps.maximised.boxShadow = null
1|a bar left solid after un-maximising|.steps.restored = .steps.maximised
1|a line under the glass bar|.steps.unmaximised.boxShadow = .steps.maximised.boxShadow
1|glass paused before any maximise|.steps.unmaximised.glass.enabled = false
3|a probe error|{error: "no io.github.apex_linux.G2Window window in 10000 ms"}
CHANGES
    done
}

test_desktop_without_dock() {
    local failures what change passes
    while IFS='|' read -r failures what change; do
        if [[ -n $change ]]; then
            printf 'APEXG2-SCENES %s\n' "$(jq -nc "{desktopOnly: true, dock: null,
                scenes: {desktop: {file: \"no-dock-desktop.png\", boxes: {panel: {x: 0, y: 0, width: 2880, height: 64}, dock: null}}}} | $change")" >"$T/no-dock.log"
        else
            : >"$T/no-dock.log"
        fi
        read -r passes _ <<<"$(assertion_counts desktop_without_dock no-dock "$T/no-dock.log")"
        expect_eq "dock-off desktop: $what fails $failures of 2" "$failures" $((2 - passes))
    done <<'CHANGES'
0|the desktop captured with no dock|.
1|a desktop never captured|del(.scenes.desktop.file)
1|a full scenes report in its place|del(.desktopOnly)
1|an Apex dock still in the report|.dock = {visible: true}
1|a dock box in the capture|.scenes.desktop.boxes.dock = {x: 968, y: 1640, width: 946, height: 140}
1|a probe error|{error: "desktopScene: no capture"}
2|no report|
CHANGES
}

test_no_dock() {
    local failures what change passes
    while IFS='|' read -r failures what change; do
        printf 'APEXG2-OVERVIEW-WINDOWS %s\n' "$(jq -nc "$NO_DOCK_REPORT | $change")" >"$T/no-dock.log"
        read -r passes _ <<<"$(assertion_counts overview_without_dock no-dock "$T/no-dock.log")"
        expect_eq "no dock: $what fails $failures of 2" "$failures" $((2 - passes))
    done <<'CHANGES'
0|stock's bottom edge, three captions clear of each other|.
1|the dock's edge kept without the dock|.bottom.hook = 810
1|a caption over the next row|.previews[0].caption.y = 500
2|a probe error|{error: "overviewWithWindows: 0 of 3 test windows mapped"}
CHANGES
}

# shellcheck disable=SC2016 # a jq program
readonly TOGGLED_FROM_TOKENS='{toggle: {title: "Dark Style", checkedBefore: true, checkedAfter: false}, colorSchemeSetting: "default",
    stylesheet: $sheet, sheet: {markers: ["light"]}, variant: "light", markerColor: "#16161aff",
    calendar: {day: {foreground: ($t.apex_fg | hex), ink: ($t.apex_fg | hex)},
        otherMonth: {foreground: ($t.apex_calendar_other_month | hex), ink: ($t.apex_calendar_other_month | hex)},
        today: {foreground: "#ffffffff", ink: "#ffffffff"}}}'

test_dark_style_off() {
    local change what passes failures all
    toggled_log() {
        jq -nc --argjson t "$(tokens_for light)" --arg sheet resource:///org/gnome/shell/theme/gnome-shell-light.css \
            "$JQ_DEFS $HEX_DEF $TOGGLED_FROM_TOKENS | $1" | sed 's/^/APEXG2-TOGGLED /' >"$T/toggled.log"
    }
    toggled_log .
    read -r all failures <<<"$(assertion_counts dark_style_off dark-style "$T/toggled.log")"
    expect_eq "dark style off: the toggle, the light sheet and the restyled calendar pass all four assertions" "4/0" "$all/$failures"
    while IFS='|' read -r change what; do
        toggled_log "$change"
        read -r passes failures <<<"$(assertion_counts dark_style_off dark-style "$T/toggled.log")"
        expect_eq "dark style off: $what fails one assertion" "3/1" "$passes/$failures"
    done <<'CHANGES'
.calendar.day.ink = "#f4f4f6ff"|day numbers still in the dark colour
.calendar.otherMonth.ink = "#000000ff"|other months' numbers left black
.calendar.today.ink = "#000000ff"|today's number left black on the accent
CHANGES
}

test_fixtures() {
    local passes failures address missing=()
    mkdir -p "$T/fixtures"
    local report='G2-FIXTURES {"battery": {"percentage": 87.0, "present": true, "onBattery": true}, '
    report+='"wifi": {"primary": "Apex-5G", "ssid": "Apex-5G", "strength": 90, "inRange": ["Apex-5G", "Apex-2.4G", "Library Guest"], '
    report+='"state": 70, "connectivity": 4}, "keyboard": {"alias": "Keychron K3", "connected": true, "icon": "input-keyboard"}, '
    report+='"gpus": {"hasDualGpu": true, "names": ["AMD Radeon Graphics", "NVIDIA GeForce RTX 3050 Laptop GPU"]}, '
    report+='"powerProfiles": {"active": "balanced", "profiles": ["power-saver", "balanced", "performance"]}, '
    report+='"accounts": {"user": "/org/freedesktop/Accounts/User0", "appsFiltered": [false, []], "sessionLimit": 0}}'
    fixtures_report "$report"
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: what fixtures.py reports passes each part's seven assertions" "21/0" "$passes/$failures"
    report='G2-FIXTURES {"battery": {"percentage": 0.0, "present": false, "onBattery": false}, '
    report+='"wifi": {"primary": "Apex-5G", "ssid": "Apex-5G", "strength": 30, "inRange": ["Apex-5G"], "state": 70, "connectivity": 4}, '
    report+='"keyboard": {"alias": "Keychron K3", "connected": false, "icon": "phone"}, "gpus": {"hasDualGpu": false, "names": ["AMD Radeon Graphics"]}, '
    report+='"powerProfiles": null, "accounts": {"user": "/org/freedesktop/Accounts/User0", "appsFiltered": [true, ["org.gnome.Nautilus.desktop"]], "sessionLimit": 1}}'
    fixtures_report "$report"
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: no battery, a weak signal, one network in range, a keyboard left unconnected, one GPU, no power-profiles-daemon and a filtering, limiting user fail all seven" "0/21" "$passes/$failures"
    fixtures_report 'fixtures.py: no owner for org.bluez after 20 s'
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: a fixtures.py that failed fails them" "0/21" "$passes/$failures"

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
    DBUS_SYSTEM_BUS_ADDRESS=$address G2_POWER_PROFILES=1 G2_ACCOUNTS=1 python3 "$HERE/fixtures.py" "$T/fixtures" >"$T/fixtures/fixtures-main.txt" 2>&1 || true
    cp "$T/fixtures/fixtures-main.txt" "$T/fixtures/fixtures-kernel.txt"
    cp "$T/fixtures/fixtures-main.txt" "$T/fixtures/fixtures-fedora.txt"
    read -r passes failures <<<"$(assertion_counts fixtures_on_the_bus "$T/fixtures")"
    expect_eq "fixtures: fixtures.py on a private bus passes the fixture assertions" "21/0" "$passes/$failures"
    write_fixture_reader
    expect_eq "fixtures: libnm, gnome-bluetooth, UPower's display device and switcheroo-control read them as the shell does" \
        '{"wifi":{"id":"Apex-5G","strength":90,"listed":["Apex-5G","Apex-2.4G","Library Guest"],"full":true,"wireless":true,"scanFinishes":true},"battery":{"present":true,"percentage":87},"connectedBluetooth":["Keychron K3"],"hasDualGpu":true}' \
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

test_shadows_under_glass() {
    local surface='{"covered": true, "sameSize": true, "interiorDiffering": 0, "rim": 9, "picked": "St.BoxLayout.popup-menu-content", "samePick": true}'
    local good passes failures what change
    good=$(jq -nc --argjson s "$surface" '{patched: true, shadows: ({quickSettings: ($s + {arrowless: true}), popupMenu: ($s + {arrowless: true}),
        dialog: ($s + {arrowless: null})} as $v | {light: ($v | .quickSettings.corners = "shadow-corners-light.png"),
        dark: ($v | .quickSettings.corners = "shadow-corners-dark.png")})}')
    while IFS='|' read -r failures what change; do
        jq -c "$change" <<<"$good" | sed 's/^/APEXG2-GLASS /' >"$T/glass.log"
        read -r passes _ <<<"$(assertion_counts shadows_under_glass glass "$T/glass.log")"
        expect_eq "shadows over surfaces: $what fails $failures of 5" "$failures" $((5 - passes))
    done <<'CHANGES'
0|exact interiors, rims within the tolerance, clicks through, no arrows, corners captured|.
1|one dark dialog pixel the layer darkened|.shadows.dark.dialog.interiorDiffering = 1
1|a popup menu rim 12.5/255 off|.shadows.light.popupMenu.rim = 13
1|a layer that takes the click|.shadows.light.quickSettings.picked = "St.Widget.apex-shadow-layer"
1|a click that lands elsewhere with shadows on|.shadows.dark.dialog.samePick = false
1|a BoxPointer that draws an arrow|.shadows.dark.popupMenu.arrowless = false
1|no dark corner crops|.shadows.dark.quickSettings.corners = null
5|a probe that never read the frames|.shadows = null
CHANGES
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
        "stock": {"covered": false, "tries": 1, "differingFromLast": 2304, "differingFromFull": 43927,
            "box": {"max": [180, 150, 170], "mean": [9, 7, 8]}, "interior": {"max": [180, 150, 170], "mean": [9, 7, 8]}, "edge": {"max": [60, 50, 40], "mean": [5, 4, 4]}}}}'
    while IFS='|' read -r failures what change; do
        jq -c "$change" <<<"$good" | sed 's/^/APEXG2-GLASS /' >"$T/glass.log"
        read -r passes _ <<<"$(assertion_counts glass_frames glass "$T/glass.log")"
        expect_eq "glass: $what fails $failures of 7" "$failures" $((7 - passes))
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
0|a stock control that needed 3 tries|.pixels.stock.tries = 3
2|5 tries that never obtained a partial redraw|.pixels.stock += {covered: true, tries: 5, differingFromFull: 0}
7|Fedora's effect|{patched: false, pixels: null}
7|a probe that failed|{error: "no frame within 2000 ms"}
CHANGES

    local fit='{"cornerRadius": 52, "allocation": [360, 400], "painted": {"box": [0, 0, 360, 400], "radii": [52, 52, 52, 52]}}'
    local on='{"radius": 96, "saturation": 1.6, "enabled": true, "fine": true, "followOpacity": true, "background": true,
        "cornerRadius": 0, "allocation": [1440, 32], "painted": {"box": [0, 0, 1440, 32], "radii": [0, 0, 0, 0]}}'
    local popover
    popover=$(jq -c '. + {radius: 120, saturation: 1.8, enabled: true, fine: true, followOpacity: true, background: true}' <<<"$fit")
    local dock
    dock=$(jq -c '. + {radius: 112, saturation: 1.8, enabled: true, fine: true, followOpacity: true, background: true}' <<<"$fit")
    local manager
    manager=$(jq -nc --argjson on "$on" --argjson p "$popover" --argjson dock "$dock" '{mapped: true, glass: null, borders: [2, 2, 2, 2], radius: 14,
            borderColor: "#3584e4b3", background: "#3584e429", glassed: true, previewBackground: "#3584e400", previewShadow: false} as $ring
        | {panel: $on, dock: $dock, quickSettings: $p, calendar: $p, banner: $p, blurEffects: ["panel"], solidClass: false} as $g
        | {panel: null, dock: null, quickSettings: null, calendar: null, banner: null, blurEffects: []} as $none
        | {radius: 144, saturation: 1.5, enabled: true, fine: true, followOpacity: true, background: false} as $scrim
        | {radius: 52, outside: 560, inside: 2080, ring: 760, square: 2704, blurredOutside: 0, blurredInside: 2080, blurredRing: 760,
            capturedDiffering: 0, capturedMax: 0, glassEffects: 1} as $corner
        | {manager: {monitorScale: 2, glass: $g, reduceTransparency: ($none + {solidClass: true}), highContrast: ($none + {solidClass: true}),
            disabled: ($none + {solidClass: false}), restored: $g,
            scrims: {overview: $scrim, launcher: ($scrim + {radius: 160, saturation: 1.6}), hidden: ($scrim + {enabled: false}), barOverScrim: $on,
                unforwarded: {changed: 59520, differingFromFull: 42880}, forwarded: {changed: 102400, differingFromFull: 0}},
            derived: {osd: $p, screenshot: ($p + {enabled: false}),
                switcher: ($p + {corner: {radius: 52, outside: 560, inside: 2080, square: 2704, blurredOutside: 0, blurredInside: 2080, capturedDiffering: 0}})},
            emptyBox: {shown: ($scrim + {enabled: false}), hidden: ($scrim + {enabled: false}), shownAgain: ($scrim + {enabled: false}),
                emptyFrames: 3, laidOut: ($scrim + {frames: 1, allocation: [320, 200]}), zeroHeight: ($scrim + {enabled: false})},
            tile: {shown: {scale: 2, inset: 6, preview: {x: 168, y: 224, width: 384, height: 192},
                glassBox: {x: 174, y: 230, width: 372, height: 180}, inner: {x: 174, y: 230, width: 372, height: 180},
                glass: {radius: 80, saturation: 1.6, cornerRadius: 28, enabled: true, fine: true, followOpacity: true, background: true,
                    allocation: [372, 180], painted: {box: [0, 0, 372, 180], radii: [28, 28, 28, 28]}},
                downscale: 8, box: {mean: [0.4, 0.4, 0.4]}, interior: {max: [2, 2, 2]}, edge: {max: [6, 6, 6]},
                bandDiffering: 0, innerDiffering: 267840},
                hidden: {glass: null, visible: false, differing: 0},
                ring: ($ring + {expected: 4, corners: [4.02, 3.98, 4, 4.01], edges: [4, 4, 4, 4]}),
                reduceTransparency: $ring,
                highContrast: ($ring + {borders: [0, 0, 0, 0], radius: 0, borderColor: "#00000000", background: "#00000000", previewBackground: "#3584e47f"})},
            conformance: {registered: ["banner", "calendar", "dock", "osd", "panel", "quick-settings", "scrim-0", "screenshot", "spotlight",
                    "switcher", "tilePreview", "toast"], unchecked: [],
                checked: {panel: $on, "scrim-0": ($scrim + {cornerRadius: 0, allocation: [1440, 900], painted: {box: [0, 0, 1440, 900], radii: [0, 0, 0, 0]}}),
                    dock: ($dock + {corner: $corner}), "quick-settings": ($p + {corner: $corner}), calendar: ($p + {corner: $corner}),
                    banner: ($p + {corner: $corner}), osd: ($p + {corner: $corner}), spotlight: ($p + {corner: $corner}),
                    toast: ($p + {corner: $corner, tries: 1}), switcher: ($p + {corner: $corner}), screenshot: ($p + {enabled: false, allocation: [null, null]}),
                    tilePreview: {radius: 80, saturation: 1.6, cornerRadius: 28, enabled: true, fine: true, followOpacity: true, background: true,
                        allocation: [372, 180], painted: {box: [0, 0, 372, 180], radii: [28, 28, 28, 28]}}}}}}')
    while IFS='|' read -r failures what change; do
        jq -c "$change" <<<"$manager" | sed 's/^/APEXG2-GLASS /' >"$T/glass.log"
        read -r passes _ <<<"$(assertion_counts glass_manager glass "$T/glass.log" light)"
        expect_eq "glass manager: $what fails $failures of 25" "$failures" $((25 - passes))
    done <<'CHANGES'
0|the bar, the dock and the popovers at their tokens, every switch honoured|.
1|the bar at the popovers' sigma|.manager.glass.panel.radius = 120
1|a banner at the bar's saturation|.manager.glass.banner.saturation = 1.6
1|the dock at the popovers' sigma|.manager.glass.dock.radius = 120
1|a dock left blurred by high contrast|.manager.highContrast.dock = .manager.glass.dock
1|a popover without fine|.manager.glass.calendar.fine = false
1|a blur left behind by Reduce Transparency|.manager.reduceTransparency.blurEffects = ["St_BoxLayout"]
1|Reduce Transparency without apex-solid|.manager.reduceTransparency.solidClass = false
1|high contrast that keeps the bar's glass|.manager.highContrast.panel = .manager.glass.panel
1|the kill switch that turns the tints solid|.manager.disabled.solidClass = true
1|glass that does not come back|.manager.restored.panel = null
1|the launcher at the overview's sigma|.manager.scrims.launcher.radius = 144
1|a scrim in background mode|.manager.scrims.overview.background = true
1|a scrim left on after the overview|.manager.scrims.hidden.enabled = true
1|a forwarded damage that leaves a stale halo|.manager.scrims.forwarded.differingFromFull = 120
2|an OSD without glass|.manager.derived.osd = null
1|an Alt+Tab list at the bar's saturation|.manager.derived.switcher.saturation = 1.6
2|a tile preview that never registers its glass|.manager.tile.shown.glass = null
1|a tile preview at the popovers' glass|.manager.tile.shown.glass.radius = 120
1|a blurred box that includes the clear border|.manager.tile.shown.glassBox = .manager.tile.shown.preview
1|a tile blur off the reference by 9/255 inside|.manager.tile.shown.interior.max = [9, 2, 2]
1|a tile that draws the pattern unblurred|.manager.tile.shown.innerDiffering = 0
1|a blur that reaches into the clear border|.manager.tile.shown.bandDiffering = 4800
1|a blur left after the preview hides|.manager.tile.hidden.glass = .manager.tile.shown.glass
1|a hidden preview whose blur still shows|.manager.tile.hidden.differing = 267840
1|an empty actor-mode box that blurs|.manager.emptyBox.shownAgain.enabled = true
1|an empty box that never drew a frame|.manager.emptyBox.emptyFrames = 0
1|a laid-out box whose blur never comes on|.manager.emptyBox.laidOut.enabled = false
1|an Alt+Tab list's blur rounded twice its border's radius|.manager.derived.switcher.cornerRadius = 104
1|a banner rounded at one corner only|.manager.glass.banner.painted.radii = [52, 0, 0, 0]
1|a blur over a box other than the painted background|.manager.glass.banner.painted.box = [0, 8, 360, 392]
1|a screenshot panel rounded unlike its border|.manager.derived.screenshot.cornerRadius = 40
1|a corner whose blur reaches past the border's arc|.manager.derived.switcher.corner.blurredOutside = 120
1|a corner left unblurred inside the arc|.manager.derived.switcher.corner.blurredInside = 1960
1|a screenshot whose corner is not the screen's|.manager.derived.switcher.corner.capturedDiffering = 640
1|the inset-shadow ring St thickens at the corners|.manager.tile.ring.corners = [8, 8, 8, 8]
1|one corner 0.3 px wider|.manager.tile.ring.corners[3] = 4.3
1|a ring left on the preview, under the class|.manager.tile.ring.previewShadow = true
1|the fill left on the preview|.manager.tile.ring.previewBackground = "#3584e429"
1|a ring at 1 px|.manager.tile.ring.borders = [1, 1, 1, 1]
1|a ring in another hue than the fill|.manager.tile.ring.borderColor = "#e01b24b3"
1|Reduce Transparency that drops the glass actor, ring and all|.manager.tile.reduceTransparency.mapped = false
1|high contrast that drops the class|.manager.tile.highContrast.glassed = false
1|a glass actor that paints a ring over upstream's high-contrast preview|.manager.tile.highContrast.borders = [2, 2, 2, 2]
1|a surface a later slice registers that the case never reached|.manager.conformance += {registered: (.manager.conformance.registered + ["notifications"]), unchecked: ["notifications"]}
1|a checked surface the assertions do not know|.manager.conformance.registered += ["notifications"]
1|a Spotlight panel rounded one px off its border|.manager.conformance.checked.spotlight.cornerRadius = 51
1|a toast blurred over a box larger than its paint box|.manager.conformance.checked.toast.allocation = [361, 400]
1|a blur past the Spotlight panel's arc|.manager.conformance.checked.spotlight.corner.blurredOutside = 40
1|a toast corner left unblurred in the band|.manager.conformance.checked.toast.corner.blurredRing = 700
1|a toast blurred by two glass effects|.manager.conformance.checked.toast.corner.glassEffects = 2
1|a dock corner a screenshot draws otherwise|.manager.conformance.checked.dock.corner.capturedMax = 2
3|a toast never checked|.manager.conformance.checked.toast = null
25|no manager|.manager = null
CHANGES
}

test_png_js
test_compare_js
test_frame_rect
test_incomplete_compare
test_stable_reports
test_huge_plan
test_token_file
test_top_bar
test_dock
test_live_keys
test_indicators
test_shell_surfaces
test_quick_settings
test_window_switcher
test_modal_dialog
test_a11y
test_inactive_dot_gap
test_pill_gaps
test_signoff
test_goldens
test_goldens_rows
test_date_menu
test_overview_style
test_app_grid
test_overview_layer
test_notifications_layer
test_shadow_layers
test_derived_surfaces
test_tile_preview
test_spotlight_style
test_launcher_search
test_surface_metrics
test_spotlight_glass
test_spotlight_keys
test_screenshot_ui
test_today_pins
test_known_gaps
test_fixed_clock
test_backdrop_painted
test_clock_c
test_overview_below_bar
test_layer_cycles
test_motion
test_idle
test_dock_pin
test_dock_dnd
test_dock_external
test_glass_load
test_glass_stress
test_spotlight_key
test_one_gpu
test_part_ran
test_no_nan_allocation
test_no_st_css_warning
test_parental_controls_ready
test_no_disposed_apex
test_no_binding_overwritten
test_no_spurious_allocation
test_clean_shutdown
test_repeat_compare
test_session_defaults
test_session_surface_icons
test_no_disposed_at_shutdown
test_exit_cut
test_keys_case
test_shutdown_banner_case
test_startup_handler_ran
test_network_rows_centred
test_pr_assertions
test_action_modes
test_no_dock
test_desktop_without_dock
test_bar_over_fixture
test_solid_bar
test_dark_style_off
test_fixtures
test_glass
test_shadows_under_glass

printf '1..%d\n' "$tests"
((failed == 0))
