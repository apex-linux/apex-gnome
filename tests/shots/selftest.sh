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
    clockShowsWeekday: true,
    corner: {name: "panelActivities", type: "ActivitiesButton", x: 0, y: 0, width: 84, height: $h},
    dnd: {off: $glyphs, on: (["notifications-disabled-symbolic"] + $glyphs)},
    leftItems: [{accessibleName: "Activities", label: null, pill: {x: $pad, y: 4, width: 76, height: 24, radius: 12}}],
    rightItems: [{accessibleName: "System", label: null, pill: {x: 1337, y: 4, width: 95, height: 24, radius: 12}}],
    opaque: {background: ($t.apex_bar | hex), boxShadow: null},
    glass: []}}'
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
the clock gap|.topBar.clockTextGap = 8
the clock pill without the pad|.topBar.withDot.pillWidth -= ($t.apex_bar_clock_gap | px) + ($t.apex_bar_clock_dot_size | px)
the raw accent dot|.topBar.withDot.dot.background = .topBar.accent'

assert_run() {
    local assertions=$1 variant=$2 change=${3:-.} tokens report=$REPORT_OF_A_BAR_DRAWN_FROM_TOKENS
    [[ $assertions == shell_surfaces ]] && report=$REPORT_OF_SURFACES_DRAWN_FROM_TOKENS
    [[ $assertions == quick_settings ]] && report=$REPORT_OF_QUICK_SETTINGS_DRAWN_FROM_TOKENS
    [[ $assertions == window_switcher ]] && report=$REPORT_OF_A_SWITCHER_DRAWN_FROM_TOKENS
    [[ $assertions == modal_dialog ]] && report=$REPORT_OF_A_DIALOG_DRAWN_FROM_TOKENS
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
CHANGES
    assert_run top_bar light '.monitorScale = 1 | .topBar.diamond.inkPixels = 16' >/dev/null
    expect_eq "top bar: at scale 1 a quarter of the diamond's stroke is 16 capture pixels" 0 "$(grep -c '^FAIL' "$T/top-bar.out")"
    assert_run top_bar light '.monitorScale = 1 | .topBar.diamond.inkPixels = 15' >/dev/null
    expect_eq "top bar: and fewer fail" 1 "$(grep -c '^FAIL' "$T/top-bar.out")"
    assert_run top_bar light 'del(.topBar)' >/dev/null
    expect_eq "top bar: a report without the top bar passes none" 0 "$(grep -c '^PASS' "$T/top-bar.out")"
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

test_png_js
test_compare_js
test_incomplete_compare
test_token_file
test_top_bar
test_shell_surfaces
test_quick_settings
test_window_switcher
test_modal_dialog
test_today_pins
test_known_gaps
test_fixed_clock
test_clock_c
test_overview_below_bar
test_layer_cycles
test_spotlight_key
test_fixtures

printf '1..%d\n' "$tests"
((failed == 0))
