#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/assert.sh RUN_DIR

The G2 assertions over one run of run.sh: one PASS, FAIL or GAP line each, then a
count, and exit 1 when one fails. compare.js compares the captures through G2_GJS, a
command prefix that runs gjs (default: gjs).
EOF
}

# shellcheck source=tests/shots/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

readonly APEX_LIGHT_SHEET=resource:///org/gnome/shell/theme/gnome-shell-light.css
readonly APEX_DARK_SHEET=resource:///org/gnome/shell/theme/gnome-shell-dark.css
readonly STOCK_SHEETS=resource:///org/gnome/shell/theme/stock
readonly FEDORA_SHEETS=resource:///org/gnome/shell/theme
readonly DIRECT_CASES=(default default-scale1 dark-style dock-intellihide dock-intellihide-dark stock-light stock-dark safe-env layer-disabled
    layer-cycles fault-configure fault-enable fault-abort kernel-safe fedora-light fedora-dark)
readonly DIRECT_PARTS=(main kernel fedora)
readonly CAPTURE_CASES=(default default-scale1 dark-style stock-light stock-dark fedora-light fedora-dark)
readonly SCENES=(desktop overview)
readonly STOCK_MAX_THUMBNAIL_SCALE=0.05
readonly DIAMOND_SQUARE_PX=8
readonly DIAMOND_STROKE_PX=2
readonly DIAMOND_STROKE_AREA_PX=$((4 * DIAMOND_SQUARE_PX * DIAMOND_STROKE_PX))
readonly LARGE_TEXT_SCALING_FACTOR=1.25
readonly HOT_CORNER_SIZE=4px
readonly SEARCH_BUTTON_NAME='Search (Super+Space)'
readonly STATUS_BUTTON_NAME=System
readonly INACTIVE_DOT_OPACITY=0.45
readonly TODAY_CLOCK_TEXT_GAP=7.04
readonly TODAY_CLOCK_PILL_EXTRA=13
readonly LAYER_CYCLES=3
readonly SPOTLIGHT_ACCELERATORS='["<Super>space"]'
readonly SPOTLIGHT_MODES='["NORMAL", "OVERVIEW"]'
# direct.sh's G2_CLOCK, in UTC; the clock shows it as weekday, date, EN SPACE, 24-hour time.
readonly FIXED_CLOCK=2026-09-28T09:41:00Z
readonly FIXED_CLOCK_TEXT='Mon Sep 28\u200209:41'
readonly BATTERY_PERCENT=87
readonly WIFI_GLYPH=network-wireless-signal-excellent-symbolic
readonly BATTERY_GLYPH=battery-level-80-symbolic
readonly BLUETOOTH_GLYPH=bluetooth-active-symbolic
readonly ALWAYS_LOADED_USER_UNIT=default.target
readonly APEX_UNIT_STARTED='(Starting|Started) [^ ]*[Aa]pex|Activating service name=.[^ ]*[Aa]pex'

result_of() {
    local run=$1 case_name=$2
    sed -n "s/^$case_name //p" "$run"/results-*.txt | head -n 1
}

exits() {
    local run=$1 case_name=$2 status=$3
    if [[ $(result_of "$run" "$case_name") == "exit=$status "* ]]; then
        pass "$case_name: the shell exits $status"
    else
        fail "$case_name: the shell exits $status (got: $(result_of "$run" "$case_name"))"
    fi
}

no_js_error() {
    local label=$1 log=$2 errors
    errors=$(grep -c 'JS ERROR' "$log")
    if [[ $errors == 0 ]]; then
        pass "$label: no 'JS ERROR' in the log"
    else
        fail "$label: $errors 'JS ERROR' line(s): $(grep -m1 -A3 'JS ERROR' "$log" | paste -sd'|' -)"
    fi
}

no_late_start() {
    local label=$1 log=$2
    if grep -q 'APEXG2-LATE' "$log"; then
        fail "$label: the probe started late twice, so main.js's startup-complete handler never ran"
    else
        pass "$label: the probe ran from startup-complete"
    fi
}

no_apex_failure() {
    local label=$1 log=$2
    local failure='Apex: (the layer did not load|hook .* threw|enable failed|feature .* off for this session|feature .* did not disable cleanly|cannot restyle)'
    if grep -Eq "$failure" "$log"; then
        fail "$label: an Apex failure is logged: $(grep -Em1 "$failure" "$log")"
    else
        pass "$label: no Apex layer, hook or feature failure is logged"
    fi
}

no_apex_unit_active() {
    local units=$1
    [[ $(grep -c "^$ALWAYS_LOADED_USER_UNIT \|^# listed\$" "$units") == 2 ]] &&
        ! awk '$1 ~ /^apex/ && $3 ~ /^(active|activating|reloading)$/ { found = 1 } END { exit !found }' "$units"
}

no_line_matches() {
    local pattern=$1 log=$2
    [[ -f $log ]] && ! grep -Eq -- "$pattern" "$log"
}

logs() {
    local label=$1 log=$2 pattern=$3 desc=$4
    if grep -Eq -- "$pattern" "$log"; then pass "$label: $desc"; else fail "$label: $desc (no line matches /$pattern/)"; fi
}

apex_light() {
    local label=$1 log=$2
    expect_report "$label" "$log" '.mode == "user"' "the user mode"
    expect_report "$label" "$log" ".stylesheet == \"$APEX_LIGHT_SHEET\"" "loads the Apex light sheet"
    expect_report "$label" "$log" '.sheet.markers == ["light"] and .sheet.apexRule' \
        "the loaded sheet carries /*! apex-shell-theme light */ and the .apex-theme-marker rule"
    expect_report "$label" "$log" '.markerColor | colour_is("#16161a")' \
        "an actor of class apex-theme-marker takes the light bar token (#16161a)"
    expect_report "$label" "$log" '.colorSchemeSetting == "default"' "color-scheme is 'default': the override sets none"
    expect_report "$label" "$log" '.sessionColorScheme == "prefer-light" and .variant == "light"' \
        "the session colour scheme is prefer-light, the variant light"
    expect_report "$label" "$log" '.safe == false' "not in safe mode"
}

# The path suffices: the lane's check.sh proves that theme/stock/ holds upstream's
# sheets byte for byte.
stock_view() {
    local label=$1 log=$2 variant=$3
    expect_report "$label" "$log" ".stylesheet == \"$STOCK_SHEETS/gnome-shell-$variant.css\"" \
        "loads upstream's $variant sheet from theme/stock/"
    expect_report "$label" "$log" '.sheet.markers == [] and (.sheet.apexRule | not) and (.sheet.structure | not)' \
        "the loaded sheet has no Apex marker or rule"
    expect_report "$label" "$log" '.markerColor | (colour_is("#16161a") or colour_is("#f6f6f8")) | not' \
        "an apex-theme-marker actor takes no Apex colour"
    expect_report "$label" "$log" ".variant == \"$variant\"" "the $variant variant"
    expect_report "$label" "$log" '.safe == true and .testFault == "stock"' "safe mode: every hook gives its stock value"
    expect_report "$label" "$log" '.startingMarker == false' "no crash-guard marker: the layer did not run"
    no_spotlight_key "$label" "$log"
}

spotlight_key() {
    local label=$1 log=$2
    expect_report "$label" "$log" ".spotlightKey.accelerators == $SPOTLIGHT_ACCELERATORS" \
        "toggle-spotlight in the Keybindings schema is Super+Space"
    expect_report "$label" "$log" ".spotlightKey.modes == $SPOTLIGHT_MODES" \
        "the layer registered it in the normal and overview modes only"
}

no_spotlight_key() {
    local label=$1 log=$2
    expect_report "$label" "$log" '.spotlightKey.modes == []' "no Super+Space: toggle-spotlight is not registered"
}

# Until apex-desktop's schema has the key, the panel shows no hint and says so.
search_hint() {
    local label=$1 log=$2 shown=$3
    if [[ $shown == true ]]; then
        expect_report "$label" "$log" '.searchHintShown == true or .searchHintShown == "no-key"' \
            "the panel showed the one-time search hint and set search-hint-shown"
    else
        expect_report "$label" "$log" '.searchHintShown != true' "the stock shell shows no search hint"
    fi
}

stock_scheme() {
    local label=$1 log=$2
    expect_report "$label" "$log" '.sessionColorScheme == "prefer-dark" and .variant == "dark"' \
        "the stock colour scheme: prefer-dark, the dark variant"
}

virtual_monitor() {
    local label=$1 log=$2 scale=${3:-2}
    expect_report "$label" "$log" ".monitors == 1 and .monitorScale == $scale and .logical == \"1440x900\"" \
        "one virtual monitor at scale $scale (1440x900 logical)"
}

with_token_values() {
    local text=$1 tokens=$2
    jq -rn --arg d "$text" --argjson t "$tokens" \
        '$d | gsub("\\$(?<n>apex_[a-z0-9_]+)"; "$\(.n) (\($t[.n] // "no such token"))")'
}

top_bar_metric() {
    local label=$1 scenes=$2 tokens=$3 desc_naming_tokens=$4 actual_path=$5 check=$6 desc
    desc=$(with_token_values "$desc_naming_tokens" "$tokens")
    if [[ -z $scenes ]]; then
        fail "$label: $desc (no APEXG2-SCENES report)"
    elif jq -e --argjson t "$tokens" "$JQ_DEFS ($actual_path) | $check" <<<"$scenes" >/dev/null 2>&1; then
        pass "$label: $desc"
    else
        fail "$label: $desc (got $(jq -c --argjson t "$tokens" "$JQ_DEFS $actual_path" <<<"$scenes" 2>&1 | head -c 400))"
    fi
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
top_bar() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label top bar" "$scenes" "$tokens")
    local buttons='[.topBar.activities, .topBar.clock, .topBar.status]'
    local pills='[.topBar.activities.pill, .topBar.clock.pill, .topBar.status.pill]'

    "${metric[@]}" 'the bar is $apex_bar_height high' \
        '.topBar.panel.height' 'px_is($t.apex_bar_height)'
    "${metric[@]}" 'the bar is filled with $apex_bar' \
        '.topBar.panel.background' 'colour_is($t.apex_bar)'
    "${metric[@]}" 'its text is $apex_font_bar_size at weight $apex_font_bar_weight' \
        '.topBar.panel.font' '(.size | px_is($t.apex_font_bar_size)) and .weight == ($t.apex_font_bar_weight | tonumber)'
    "${metric[@]}" 'its digits are proportional (no tnum)' \
        '.topBar.clock.label.font' 'has("features") and (.features == null or (.features | test("tnum") | not))'
    "${metric[@]}" 'the clock starts with the weekday (the vendor override'"'"'s clock-show-weekday)' \
        '.topBar.clockShowsWeekday' '. == true'
    "${metric[@]}" 'the left and right boxes put their items $apex_bar_gap apart, with no inset of their own' \
        '[.topBar.left, .topBar.right]' 'all((.spacing | px_is($t.apex_bar_gap)) and .padding.left == 0 and .padding.right == 0)'
    "${metric[@]}" 'the activities, clock and status buttons fill the bar ($apex_bar_height)' \
        "$buttons | map(.height)" 'all(px_is($t.apex_bar_height))'
    "${metric[@]}" 'the Activities and status buttons reach the screen'"'"'s left and right edges (a click in a top corner opens them)' \
        '.topBar | {left: .activities.x, right: (.panel.width - .status.x - .status.width)}' '.left == 0 and .right == 0'
    "${metric[@]}" 'the bar'"'"'s own text and its buttons'"'"' text and glyphs are $apex_bar_fg' \
        "[.topBar.panel] + $buttons | map(.foreground)" 'all(colour_is($t.apex_bar_fg))'
    "${metric[@]}" 'their pills are $apex_bar_pill_height high, radius $apex_radius_bar_pill' \
        "$pills | map({height, radius})" 'all((.height | px_is($t.apex_bar_pill_height)) and (.radius | px_is($t.apex_radius_bar_pill)))'
    "${metric[@]}" 'the pills have no fill while closed' \
        "$pills | map(.background)" 'all(rgba | .[3] == 0)'
    "${metric[@]}" 'a hovered or open (checked) pill is filled with $apex_bar_hover' \
        "$pills | map([.hover.background, .checked.background])" 'flatten | all(colour_is($t.apex_bar_hover))'
    "${metric[@]}" 'the clock and status pills are padded $apex_bar_pill_padding' \
        '[.topBar.clock.pill, .topBar.status.pill] | map(.padding)' 'all((.left | px_is($t.apex_bar_pill_padding)) and (.right | px_is($t.apex_bar_pill_padding)))'
    "${metric[@]}" 'the activities pill leaves $apex_bar_pill_padding + $apex_bar_diamond_size + $apex_bar_activities_gap on the left for the diamond' \
        '.topBar.activities.pill.padding' '(.left | px_is(($t.apex_bar_pill_padding | px) + ($t.apex_bar_diamond_size | px) + ($t.apex_bar_activities_gap | px))) and (.right | px_is($t.apex_bar_pill_padding))'
    "${metric[@]}" 'the clock text is $apex_font_bar_size at weight $apex_font_bar_emphasis_weight in $apex_bar_fg' \
        '.topBar.clock.label' '(.font.size | px_is($t.apex_font_bar_size)) and .font.weight == ($t.apex_font_bar_emphasis_weight | tonumber) and (.foreground | colour_is($t.apex_bar_fg))'
    "${metric[@]}" 'the activities pill starts $apex_bar_padding from the left edge' \
        '.topBar.activities.pill.x' 'px_is($t.apex_bar_padding)'
    "${metric[@]}" 'the focused-app name follows the Activities pill: "Desktop" at $apex_font_bar_emphasis_weight while nothing has focus' \
        '.topBar.leftItems' 'length == 2 and .[0].accessibleName == "Activities" and (.[1].label | .text == "Desktop" and .weight == ($t.apex_font_bar_emphasis_weight | tonumber))'
    "${metric[@]}" 'the status pill ends $apex_bar_padding from the right edge' \
        '.topBar | .panel.width - .status.pill.x - .status.pill.width' 'px_is($t.apex_bar_padding)'
    "${metric[@]}" "the search button comes just before the status pill: a \$apex_bar_search_width x \$apex_bar_pill_height pill, radius \$apex_radius_bar_pill, named \"$SEARCH_BUTTON_NAME\"" \
        '.topBar.rightItems | .[-2:]' \
        "length == 2 and .[1].accessibleName == \"$STATUS_BUTTON_NAME\" and .[0].accessibleName == \"$SEARCH_BUTTON_NAME\"
            and (.[0].pill | (.width | px_is(\$t.apex_bar_search_width)) and (.height | px_is(\$t.apex_bar_pill_height)) and (.radius | px_is(\$t.apex_radius_bar_pill)))"
    "${metric[@]}" 'the clock pill is centred on the bar' \
        '.topBar | .clock.pill.x + .clock.pill.width / 2 - .panel.width / 2' 'fabs <= 0.5'
    "${metric[@]}" 'the bar changes over $apex_bar_transition' \
        '.topBar.panel.transition' '. == ($t.apex_bar_transition | rtrimstr("ms") | tonumber)'
    "${metric[@]}" 'with translucent-top-bar off the bar is $apex_bar_solid over a 0 1px 0 $apex_border line' \
        '.topBar.opaque' \
        '(.background | colour_is($t.apex_bar_solid)) and (.boxShadow | .inset == false and .x == 0 and .y == 1 and .blur == 0 and .spread == 0 and (.color | colour_is($t.apex_border)))'
    "${metric[@]}" 'the workspace dots are $apex_bar_dots_gap apart, the active one $apex_bar_dot_size high, each with radius $apex_radius_workspace_dot' \
        '.topBar | {spacing: .activities.pill.spacing, active: (.dots | map(select(.active)) | map(.height)), radii: (.dots | map(.radius))}' \
        '(.spacing | px_is($t.apex_bar_dots_gap)) and .active != [] and (.active | all(px_is($t.apex_bar_dot_size))) and (.radii | all(px_is($t.apex_radius_workspace_dot)))'
    "${metric[@]}" 'the active workspace dot is $apex_bar_dot_active_width x $apex_bar_dot_size' \
        '.topBar.dots | map(select(.active)) | map({width, height})' \
        'length == 1 and (.[0] | (.width | px_is($t.apex_bar_dot_active_width)) and (.height | px_is($t.apex_bar_dot_size)))'
    "${metric[@]}" "an inactive workspace dot is \$apex_bar_dot_size square at opacity $INACTIVE_DOT_OPACITY" \
        '.topBar.dots | map(select(.active | not)) | map({width, height, opacity})' \
        "length > 0 and all((.width | px_is(\$t.apex_bar_dot_size)) and (.height | px_is(\$t.apex_bar_dot_size)) and ((.opacity - $INACTIVE_DOT_OPACITY) | fabs < 0.01))"
    "${metric[@]}" "the hot corner: the top-left pixel reaches a reactive $HOT_CORNER_SIZE square zone at 0,0" \
        '.topBar.corner' ".x == 0 and .y == 0 and (.width | px_is(\"$HOT_CORNER_SIZE\")) and (.height | px_is(\"$HOT_CORNER_SIZE\"))"
    "${metric[@]}" 'the clock'"'"'s unread-notification dot is $apex_bar_clock_dot_size square, radius $apex_radius_clock_dot' \
        '.topBar.withDot.dot' '.visible and (.width | px_is($t.apex_bar_clock_dot_size)) and (.height | px_is($t.apex_bar_clock_dot_size)) and (.radius | px_is($t.apex_radius_clock_dot))'
    "${metric[@]}" "the diamond is drawn: at least a quarter of its $DIAMOND_STROKE_AREA_PX px² stroke in capture pixels of \$apex_bar_fg, left of the dots" \
        '{diamond: .topBar.diamond, scale: .monitorScale}' "(.diamond.colour | colour_is(\$t.apex_bar_fg)) and .diamond.inkPixels >= $DIAMOND_STROKE_AREA_PX * .scale * .scale / 4"
    "${metric[@]}" 'the status pill puts its glyphs $apex_bar_status_gap apart' \
        '.topBar.status.pill.spacing' 'px_is($t.apex_bar_status_gap)'
    "${metric[@]}" 'its glyphs are $apex_bar_icon_size' \
        '.topBar.statusGlyphs' 'length > 0 and all(.iconSize | px_is($t.apex_bar_icon_size))'
    "${metric[@]}" "it shows the fixtures' Wi-Fi at full signal ($WIFI_GLYPH) and their battery ($BATTERY_GLYPH)" \
        '.topBar.statusGlyphs | map(.name)' "index([\"$WIFI_GLYPH\"]) != null and index([\"$BATTERY_GLYPH\"]) != null"
    "${metric[@]}" "and the battery's $BATTERY_PERCENT% at \$apex_font_bar_percentage_size in \$apex_bar_fg" \
        '.topBar.statusLabels' "length == 1 and (.[0] | .text == \"$BATTERY_PERCENT%\" and (.font.size | px_is(\$t.apex_font_bar_percentage_size)) and (.foreground | colour_is(\$t.apex_bar_fg)))"
    "${metric[@]}" 'the status pill shows network, volume and battery only: the fixtures'"'"' connected Bluetooth keyboard adds no glyph' \
        '.topBar.statusGlyphs | map(.name)' "length > 0 and index([\"$BLUETOOTH_GLYPH\"]) == null"
    "${metric[@]}" 'and Do Not Disturb adds none' \
        '.topBar.dnd' '(.off | type == "array") and .on == .off'
    "${metric[@]}" 'on the lock screen and the greeter, upstream'"'"'s hover fill of the status button is centred on its pill' \
        '.topBar.lockScreen | {fill: .statusHover, left: (.status.pill.x - .status.x), right: (.status.x + .status.width - .status.pill.x - .status.pill.width)}' \
        '(.fill.boxShadow.inset == true or (.fill.background | rgba | .[3] > 0)) and ((.left - .right) | fabs <= 0.5)'
    "${metric[@]}" "with Large Text ($LARGE_TEXT_SCALING_FACTOR) the bar, the clock pill and the glyphs keep \$apex_bar_height, \$apex_bar_pill_height and \$apex_bar_icon_size" \
        '.topBar.largeText' "(.textScalingFactor == $LARGE_TEXT_SCALING_FACTOR) and (.barHeight | px_is(\$t.apex_bar_height))
            and (.clockPillHeight | px_is(\$t.apex_bar_pill_height))
            and (.statusGlyphs | length > 0 and all(.iconSize | px_is(\$t.apex_bar_icon_size)))"
    "${metric[@]}" "and only the text grows: the clock at $LARGE_TEXT_SCALING_FACTOR x \$apex_font_bar_size, within its pill" \
        '.topBar.largeText' "((.clockText.size - $LARGE_TEXT_SCALING_FACTOR * (\$t.apex_font_bar_size | px)) | fabs < 0.05)
            and .clockText.naturalHeight <= .clockPillHeight"
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
dock_metrics() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label dock" "$scenes" "$tokens")

    "${metric[@]}" 'the dock is shown, $apex_dock_bottom_gap above the bottom edge and centred' \
        '.dock' '.visible == true and (.bottomGap | px_is($t.apex_dock_bottom_gap)) and (.centreOffset | fabs <= 0.5)'
    "${metric[@]}" 'its background has radius $apex_radius_dock' \
        '.dock.radius' 'px_is($t.apex_radius_dock)'
    "${metric[@]}" 'every icon is $apex_dock_icon_size (dock-icon-size medium)' \
        '.dock.items | map(select(.iconSize != null))' 'length > 0 and all(.iconSize | px_is($t.apex_dock_icon_size))'
    "${metric[@]}" 'its apps come first, then the separator, Show Apps and Trash, with no other separator' \
        '.dock.items | map(.kind)' \
        '(.[-3:] == ["separator", "show-apps", "trash"]) and (.[:-3] | all(. == "app"))'
    "${metric[@]}" 'the Show Apps tile is full colour (view-app-grid)' \
        '.dock.items | map(select(.kind == "show-apps")) | .[0].iconName' '. == "view-app-grid"'
    "${metric[@]}" 'the overview keeps the dock and hides its own dash' \
        '{dash: .dock.overviewDashVisible, overview: .scenes.overview.dockVisible}' '.dash == false and .overview == true'
    "${metric[@]}" 'and lays its workspaces out above the dock' \
        '{dock: .dock, clearance: .scenes.overview.dockClearance}' '.dock != null and .clearance != null and .clearance >= 0'
}

dock_intellihide() {
    local label=$1 log=$2
    expect_report "$label" "$log" '.error == null and .steps.initial.hidden == false' \
        "the dock shows while no window is maximised" APEXG2-DOCK
    expect_report "$label" "$log" '.steps.maximised | .window == true and .hidden == true and .barSolid == true' \
        "a maximised window hides it (dock-intellihide) and makes the bar solid" APEXG2-DOCK
    expect_report "$label" "$log" '.steps.revealed | .hidden == false and .underPointer == true' \
        "pushing against the bottom edge under it reveals it, under the pointer" APEXG2-DOCK
    expect_report "$label" "$log" '.steps.left.hidden == true' "leaving it hides it again" APEXG2-DOCK
    expect_report "$label" "$log" '.steps.overview.hidden == false' "the overview shows it over the maximised window" APEXG2-DOCK
    expect_report "$label" "$log" '.steps.intellihideOff | .hidden == false and .window == true' \
        "with dock-intellihide off it stays over the maximised window" APEXG2-DOCK
    expect_report "$label" "$log" '.steps.intellihideOn.hidden == true' "turned back on, it hides again" APEXG2-DOCK
    expect_report "$label" "$log" '.steps.closed | .hidden == false and .window == false' \
        "the window gone, it shows" APEXG2-DOCK
    check "$label: the maximised and revealed scenes are captured" \
        test -s "$3/captures/$label-maximised.png" -a -s "$3/captures/$label-revealed.png"
}

no_dock() {
    local label=$1 log=$2
    expect_report "$label" "$log" '.dock == null' "no Apex dock" APEXG2-SCENES
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
top_bar_today() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label top bar, until its known gap closes" "$scenes" "$tokens")

    "${metric[@]}" 'the bar has no blur effect' \
        '.topBar.glass' '. == []'
    "${metric[@]}" "the clock's date and time are $TODAY_CLOCK_TEXT_GAP px apart (one EN SPACE, 24-hour clock)" \
        '.topBar.clockTextGap' "(. - $TODAY_CLOCK_TEXT_GAP) | fabs <= 0.5"
    "${metric[@]}" "with the dot, the clock pill is $TODAY_CLOCK_PILL_EXTRA px wider than \$apex_bar_pill_padding + the text + \$apex_bar_clock_gap + \$apex_bar_clock_dot_size + \$apex_bar_pill_padding" \
        '.topBar.withDot' \
        ".dot.visible and ((.pillWidth - .labelWidth - 2 * (\$t.apex_bar_pill_padding | px) - (\$t.apex_bar_clock_gap | px) - (\$t.apex_bar_clock_dot_size | px) - $TODAY_CLOCK_PILL_EXTRA) | fabs <= 0.5)"
    "${metric[@]}" 'the unread-notification dot is $apex_bar_fg' \
        '.topBar.withDot.dot.background' 'colour_is($t.apex_bar_fg)'
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
top_bar_gaps() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label top bar" "$scenes" "$tokens")
    local clock_hook='no step yet (a clock hook, or the owner accepts it)'
    local wallpaper='S1b (the Facets wallpaper and the light overview)'

    known_gap 'S2b (patch 0003, the glass manager)' "${metric[@]}" 'the bar is glass: a Shell.BlurEffect of radius 2 x $apex_bar_blur x the monitor scale at $apex_bar_saturation' \
        '{glass: .topBar.glass, scale: .monitorScale}' \
        '.scale as $s | .glass | any((.radius - 2 * ($t.apex_bar_blur | px) * $s | fabs < 0.01) and .saturation != null and ((.saturation - ($t.apex_bar_saturation | rtrimstr("%") | tonumber / 100)) | fabs < 0.01))'
    known_gap "$clock_hook" "${metric[@]}" 'the clock'"'"'s date and time are $apex_bar_clock_gap apart (G2'"'"'s 24-hour clock puts an EN SPACE between them; en-US'"'"'s 12-hour clock adds a FIGURE SPACE before a one-digit hour, about 14 px in all)' \
        '.topBar.clockTextGap' '(. - ($t.apex_bar_clock_gap | px)) | fabs <= 0.5'
    known_gap "$clock_hook" "${metric[@]}" 'with the dot, the clock pill is $apex_bar_pill_padding + the text + $apex_bar_clock_gap + $apex_bar_clock_dot_size + $apex_bar_pill_padding wide' \
        '.topBar.withDot' \
        '.dot.visible and ((.pillWidth - .labelWidth - 2 * ($t.apex_bar_pill_padding | px) - ($t.apex_bar_clock_gap | px) - ($t.apex_bar_clock_dot_size | px)) | fabs <= 0.5)'
    known_gap "$wallpaper" "${metric[@]}" 'the unread-notification dot is the raw accent, unmixed in both variants (the theme context'"'"'s accent colour)' \
        '{dot: .topBar.withDot.dot.background, accent: .topBar.accent}' '. as $x | $x.dot | colour_is($x.accent)'
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
shell_surfaces() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label" "$scenes" "$tokens")
    local m=.surfaces.popupMenu o=.surfaces.osd b=.surfaces.banner
    local surface='(.border | [.top, .right, .bottom, .left] | all(px_is($t.apex_surface_border))) and (.borderColor | colour_is($t.apex_panel_border))
        and (.boxShadow | .inset == false and .x == 0 and (.y | px_is($t.apex_shadow_y)) and (.blur | px_is($t.apex_shadow_blur)) and (.color | colour_is($t.apex_shadow)))'

    "${metric[@]}" 'a popup menu is solid $apex_panel_solid with $apex_fg text at $apex_font_size, radius $apex_radius_menu' \
        "$m.content" '(.background | colour_is($t.apex_panel_solid)) and (.foreground | colour_is($t.apex_fg)) and (.font.size | px_is($t.apex_font_size)) and (.radius | px_is($t.apex_radius_menu))'
    "${metric[@]}" 'its ring is a $apex_surface_border border in $apex_panel_border, its shadow 0 $apex_shadow_y $apex_shadow_blur $apex_shadow' \
        "$m.content" "$surface"
    "${metric[@]}" 'it is inset $apex_menu_padding and at least $apex_menu_min_width wide' \
        "$m.content" '(.padding | [.top, .right, .bottom, .left] | all(. + ($t.apex_surface_border | px) | px_is($t.apex_menu_padding))) and .width >= ($t.apex_menu_min_width | px)'
    "${metric[@]}" 'its rows are $apex_menu_row_height high, radius $apex_radius_menu_row, padded $apex_menu_row_padding, $apex_menu_row_spacing between glyph and label' \
        "$m.rows" 'length == 3 and all((.height | px_is($t.apex_menu_row_height)) and (.radius | px_is($t.apex_radius_menu_row))
            and (.padding.left | px_is($t.apex_menu_row_padding)) and (.padding.right | px_is($t.apex_menu_row_padding)) and (.spacing | px_is($t.apex_menu_row_spacing)))'
    "${metric[@]}" 'a row has no fill until hovered, then $apex_button_hover' \
        "$m.rows" 'all((.background | rgba | .[3] == 0) and (.hover.background | colour_is($t.apex_button_hover)))'
    "${metric[@]}" 'adjacent rows are $apex_menu_row_gap apart' \
        "$m.rows" '.[1].y - .[0].y - .[0].height | px_is($t.apex_menu_row_gap)'
    "${metric[@]}" 'a separator is a 1 px $apex_border line, inset $apex_menu_separator_inset, with $apex_menu_separator_margin + $apex_menu_row_gap above and below' \
        "$m" '(.separator.height | px_is(1)) and (.separator.background | colour_is($t.apex_border))
            and (.separator.x - .content.x - .content.padding.left - .content.border.left | px_is($t.apex_menu_separator_inset))
            and ((.separator.y - .rows[1].y - .rows[1].height) | px_is(($t.apex_menu_separator_margin | px) + ($t.apex_menu_row_gap | px)))
            and ((.rows[2].y - .separator.y - .separator.height) | px_is(($t.apex_menu_separator_margin | px) + ($t.apex_menu_row_gap | px)))'
    "${metric[@]}" 'a row glyph is $apex_menu_icon_size' \
        "$m.icon" 'px_is($t.apex_menu_icon_size)'

    "${metric[@]}" 'the OSD is $apex_osd_height high, radius $apex_radius_osd, tinted $apex_panel' \
        "$o.box" '(.height | px_is($t.apex_osd_height)) and (.radius | px_is($t.apex_radius_osd)) and (.background | colour_is($t.apex_panel)) and (.foreground | colour_is($t.apex_fg))'
    "${metric[@]}" 'its ring is a $apex_surface_border border in $apex_panel_border, its shadow 0 $apex_shadow_y $apex_shadow_blur $apex_shadow' \
        "$o.box" "$surface"
    "${metric[@]}" 'it is inset $apex_osd_padding at the sides, $apex_osd_gap between its parts, its text $apex_font_size at $apex_font_label_weight' \
        "$o.box" '(.padding.left + .border.left | px_is($t.apex_osd_padding)) and (.padding.right + .border.right | px_is($t.apex_osd_padding)) and (.spacing | px_is($t.apex_osd_gap))
            and (.font.size | px_is($t.apex_font_size)) and .font.weight == ($t.apex_font_label_weight | tonumber)'
    "${metric[@]}" 'its glyph is $apex_osd_icon_size; its level $apex_osd_level_width x $apex_osd_level_height in $apex_button_hover, filled with the accent' \
        "{osd: $o, accent: .topBar.accent}" '.accent as $accent | (.osd.icon | px_is($t.apex_osd_icon_size)) and (.osd.level | (.width | px_is($t.apex_osd_level_width)) and (.barHeight | px_is($t.apex_osd_level_height))
            and (.background | colour_is($t.apex_button_hover))) and (.osd.level.active | colour_is($accent))'
    "${metric[@]}" 'it sits $apex_osd_bottom above the screen'"'"'s bottom edge' \
        "$o.bottomGap" 'px_is($t.apex_osd_bottom)'

    "${metric[@]}" 'a banner is $apex_banner_width wide, radius $apex_radius_banner, tinted $apex_panel, $apex_banner_top below the bar' \
        "$b" '(.box.width | px_is($t.apex_banner_width)) and (.box.radius | px_is($t.apex_radius_banner)) and (.box.background | colour_is($t.apex_panel)) and (.topGap | px_is($t.apex_banner_top))'
    "${metric[@]}" 'its ring is a $apex_surface_border border in $apex_panel_border, its shadow 0 $apex_shadow_y $apex_shadow_blur $apex_shadow' \
        "$b.box" "$surface"
    "${metric[@]}" 'it is inset $apex_banner_padding' \
        "$b.box" '[.padding, .border] | [.[0].top + .[1].top, .[0].right + .[1].right, .[0].bottom + .[1].bottom, .[0].left + .[1].left] | all(px_is($t.apex_banner_padding))'
    "${metric[@]}" 'its header is $apex_font_banner_header_size in $apex_fg_dim; its title $apex_font_size at $apex_font_heading_weight; its body $apex_font_banner_body_size in $apex_fg_dim' \
        "$b" '(.header.font.size | px_is($t.apex_font_banner_header_size)) and (.header.foreground | colour_is($t.apex_fg_dim))
            and (.title.font.size | px_is($t.apex_font_size)) and .title.font.weight == ($t.apex_font_heading_weight | tonumber)
            and (.body.font.size | px_is($t.apex_font_banner_body_size)) and (.body.foreground | colour_is($t.apex_fg_dim))'
    "${metric[@]}" 'its icon is $apex_banner_icon_size, $apex_banner_gap from the text' \
        "$b" '(.icon | px_is($t.apex_banner_icon_size)) and (.title.x - .box.x - .box.padding.left - .box.border.left | px_is(($t.apex_banner_icon_size | px) + ($t.apex_banner_gap | px)))'
    "${metric[@]}" 'its close button is a $apex_banner_close_size circle filled with $apex_button' \
        "$b.close" '(.width | px_is($t.apex_banner_close_size)) and (.height | px_is($t.apex_banner_close_size)) and .radius >= (($t.apex_banner_close_size | px) / 2) and (.background | colour_is($t.apex_button))'
    "${metric[@]}" 'its action buttons are $apex_banner_button_height high, radius $apex_radius_banner_button, $apex_button, $apex_font_banner_button_size at $apex_font_label_weight, $apex_banner_button_gap apart under the text' \
        "$b" '(.button | (.minHeight | px_is($t.apex_banner_button_height)) and (.radius | px_is($t.apex_radius_banner_button)) and (.background | colour_is($t.apex_button))
            and (.font.size | px_is($t.apex_font_banner_button_size)) and .font.weight == ($t.apex_font_label_weight | tonumber))
            and (.actions | (.spacing | px_is($t.apex_banner_button_gap)) and (.padding.left | px_is(($t.apex_banner_icon_size | px) + ($t.apex_banner_gap | px))))'
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
quick_settings() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label Quick Settings" "$scenes" "$tokens")
    local q=.surfaces.quickSettings
    local toggle_width='((($t.apex_quick_settings_width | px) - 2 * ($t.apex_quick_settings_padding | px) - ($t.apex_quick_settings_grid_gap | px)) / 2)'
    local shade='(1 - ($t.apex_quick_toggle_menu_button_shade | rtrimstr("%") | tonumber) / 100)'

    "${metric[@]}" 'the panel is $apex_quick_settings_width wide, radius $apex_radius_quick_settings, tinted $apex_panel, inset $apex_quick_settings_padding' \
        "$q.box" '(.width | px_is($t.apex_quick_settings_width)) and (.radius | px_is($t.apex_radius_quick_settings)) and (.background | colour_is($t.apex_panel))
            and ([.padding, .border] | [.[0].top + .[1].top, .[0].right + .[1].right, .[0].bottom + .[1].bottom, .[0].left + .[1].left] | all(px_is($t.apex_quick_settings_padding)))'
    "${metric[@]}" 'its ring is a $apex_surface_border border in $apex_panel_border, its shadow 0 $apex_shadow_y $apex_shadow_blur $apex_shadow' \
        "$q.box" '(.border.top | px_is($t.apex_surface_border)) and (.borderColor | colour_is($t.apex_panel_border))
            and (.boxShadow | .y == ($t.apex_shadow_y | px) and .blur == ($t.apex_shadow_blur | px) and (.color | colour_is($t.apex_shadow)))'
    "${metric[@]}" 'the grid puts $apex_quick_settings_grid_gap between rows and columns, and $apex_quick_settings_section_gap under the top row' \
        "$q" '(.grid.rows | px_is($t.apex_quick_settings_grid_gap)) and (.grid.columns | px_is($t.apex_quick_settings_grid_gap))
            and (.wifi.y - .system.y - .system.height | px_is($t.apex_quick_settings_section_gap))'
    "${metric[@]}" 'the top row'"'"'s round buttons are $apex_quick_settings_button_size circles in $apex_button, $apex_quick_settings_button_gap apart, glyphs $apex_quick_settings_icon_size' \
        "$q.system" '(.spacing | px_is($t.apex_quick_settings_button_gap)) and (.screenshot | (.width | px_is($t.apex_quick_settings_button_size)) and (.height | px_is($t.apex_quick_settings_button_size))
            and .radius >= ($t.apex_quick_settings_button_size | px) / 2 and (.background | colour_is($t.apex_button)) and (.icon | px_is($t.apex_quick_settings_icon_size)))'
    "${metric[@]}" 'the battery pill is $apex_quick_settings_button_size high in $apex_button, padded $apex_quick_settings_battery_padding, $apex_quick_settings_battery_gap to its text at $apex_font_quick_settings_battery_size $apex_font_label_weight' \
        "$q.system.battery" '(.height | px_is($t.apex_quick_settings_button_size)) and .radius >= ($t.apex_quick_settings_button_size | px) / 2 and (.background | colour_is($t.apex_button))
            and (.box.padding.left | px_is($t.apex_quick_settings_battery_padding)) and (.box.padding.right | px_is($t.apex_quick_settings_battery_padding)) and (.box.spacing | px_is($t.apex_quick_settings_battery_gap))
            and (.title.font.size | px_is($t.apex_font_quick_settings_battery_size)) and .title.font.weight == ($t.apex_font_label_weight | tonumber)'
    "${metric[@]}" 'toggles fill half the grid and are $apex_quick_toggle_height high, fully round' \
        "[$q.wifi, $q.unchecked]" "all((.width | px_is($toggle_width)) and (.height | px_is(\$t.apex_quick_toggle_height)))
            and (.[1].radius >= (\$t.apex_quick_toggle_height | px) / 2)"
    "${metric[@]}" 'an unchecked toggle is $apex_button with $apex_fg text, $apex_button_hover when hovered' \
        "$q.unchecked" '(.background | colour_is($t.apex_button)) and (.foreground | colour_is($t.apex_fg)) and (.hover.background | colour_is($t.apex_button_hover))'
    "${metric[@]}" 'a checked toggle is the accent, its text the accent'"'"'s foreground, its subtitle that at $apex_quick_toggle_subtitle_opacity' \
        "{t: $q.wifi.toggle, accent: .topBar.accent}" '.accent as $a | (.t.background | colour_is($a)) and (.t.foreground | colour_is("#ffffff"))
            and (.t.subtitle.foreground | colour_is("rgba(255, 255, 255, \($t.apex_quick_toggle_subtitle_opacity))"))'
    "${metric[@]}" 'a toggle is padded $apex_quick_toggle_padding ($apex_quick_toggle_menu_padding before a menu arrow), $apex_quick_toggle_gap between glyph and text, its glyph $apex_quick_settings_icon_size' \
        "[$q.wifi.toggle, $q.unchecked]" 'all((.box.padding.left | px_is($t.apex_quick_toggle_padding)) and (.box.spacing | px_is($t.apex_quick_toggle_gap)) and (.icon | px_is($t.apex_quick_settings_icon_size)))
            and (.[0].box.padding.right | px_is($t.apex_quick_toggle_menu_padding)) and (.[1].box.padding.right | px_is($t.apex_quick_toggle_padding))'
    "${metric[@]}" 'its title is $apex_font_quick_toggle_title_size at $apex_font_heading_weight, its subtitle $apex_font_quick_toggle_subtitle_size' \
        "$q.wifi.toggle" '(.title.font.size | px_is($t.apex_font_quick_toggle_title_size)) and .title.font.weight == ($t.apex_font_heading_weight | tonumber)
            and (.subtitle.font.size | px_is($t.apex_font_quick_toggle_subtitle_size))'
    "${metric[@]}" 'the menu arrow is $apex_quick_toggle_menu_button_width wide, the checked fill shaded $apex_quick_toggle_menu_button_shade with black, with no separator' \
        "{w: $q.wifi, accent: .topBar.accent}" "(.accent | rgba) as \$a | (.w.menuButton.background | rgba) as \$m
            | (.w.menuButton.width | px_is(\$t.apex_quick_toggle_menu_button_width)) and (.w.separator.width == 0)
            and ([range(3)] | all((\$m[.] - \$a[.] * $shade) | fabs <= 1))"
    "${metric[@]}" 'a slider has $apex_quick_slider_gap beside its glyph, a $apex_quick_slider_track_height track in $apex_button_hover filled with the accent, a $apex_quick_slider_handle_size $apex_slider_handle handle' \
        "{s: $q.slider, accent: .topBar.accent}" '.accent as $a | .s | (.spacing | px_is($t.apex_quick_slider_gap)) and (.trackHeight | px_is($t.apex_quick_slider_track_height))
            and (.track | colour_is($t.apex_button_hover)) and (.fill | colour_is($a)) and (.handleRadius * 2 | px_is($t.apex_quick_slider_handle_size)) and (.handle | colour_is($t.apex_slider_handle))'
    "${metric[@]}" 'the Wi-Fi menu is a $apex_card card ringed in $apex_card_border, radius $apex_radius_quick_menu, inset $apex_quick_menu_padding, $apex_quick_settings_grid_gap under its toggle, without a shadow' \
        "$q" '(.wifiMenu.box | (.background | colour_is($t.apex_card)) and (.borderColor | colour_is($t.apex_card_border)) and (.border.top | px_is($t.apex_surface_border))
            and (.radius | px_is($t.apex_radius_quick_menu)) and (.padding.left + .border.left | px_is($t.apex_quick_menu_padding)) and .boxShadow == null)
            and (.wifiMenu.box.y - .wifi.y - .wifi.height | px_is($t.apex_quick_settings_grid_gap))'
    "${metric[@]}" 'its header glyph sits in a $apex_quick_menu_header_icon_size accent circle; its title is $apex_font_quick_menu_title_size at $apex_font_heading_weight' \
        "{m: $q.wifiMenu, accent: .topBar.accent}" '.accent as $a | .m | (.headerIcon | (.width | px_is($t.apex_quick_menu_header_icon_size)) and (.height | px_is($t.apex_quick_menu_header_icon_size))
            and (.background | colour_is($a)) and (.iconSize | px_is($t.apex_quick_settings_icon_size)))
            and (.title.font.size | px_is($t.apex_font_quick_menu_title_size)) and .title.font.weight == ($t.apex_font_heading_weight | tonumber)'
    "${metric[@]}" 'its rows are $apex_quick_menu_row_height high, padded $apex_menu_row_padding, radius $apex_radius_menu_row' \
        "$q.wifiMenu.rows" 'length > 0 and all((.height | px_is($t.apex_quick_menu_row_height)) and (.padding.left | px_is($t.apex_menu_row_padding)) and (.radius | px_is($t.apex_radius_menu_row)))'
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
window_switcher() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label window switcher" "$scenes" "$tokens")
    local w=.surfaces.switcher

    "${metric[@]}" 'the list is tinted $apex_panel, radius $apex_radius_switcher, inset $apex_switcher_padding' \
        "$w.list" '(.background | colour_is($t.apex_panel)) and (.radius | px_is($t.apex_radius_switcher))
            and ([.padding, .border] | [.[0].top + .[1].top, .[0].right + .[1].right, .[0].bottom + .[1].bottom, .[0].left + .[1].left] | all(px_is($t.apex_switcher_padding)))'
    "${metric[@]}" 'its ring is a $apex_surface_border border in $apex_panel_border, its shadow 0 $apex_shadow_y $apex_shadow_blur $apex_shadow' \
        "$w.list" '(.border.top | px_is($t.apex_surface_border)) and (.borderColor | colour_is($t.apex_panel_border))
            and (.boxShadow | .y == ($t.apex_shadow_y | px) and .blur == ($t.apex_shadow_blur | px) and (.color | colour_is($t.apex_shadow)))'
    "${metric[@]}" 'its tiles are $apex_switcher_gap apart, radius $apex_radius_switcher_item, padded $apex_switcher_item_vpadding $apex_switcher_item_hpadding, $apex_switcher_item_spacing above the name' \
        "$w" '(.spacing | px_is($t.apex_switcher_gap)) and (.app.spacing | px_is($t.apex_switcher_item_spacing))
            and (.items | length > 1 and all((.radius | px_is($t.apex_radius_switcher_item)) and (.padding.top | px_is($t.apex_switcher_item_vpadding)) and (.padding.left | px_is($t.apex_switcher_item_hpadding))))'
    "${metric[@]}" 'the selected tile alone is filled with $apex_button_hover, its name in $apex_fg' \
        "$w.items" 'map(select(.pseudoClass // "" | test("selected"))) as $sel | map(select(.pseudoClass // "" | test("selected") | not)) as $rest
            | ($sel | length == 1) and ($sel[0] | (.background | colour_is($t.apex_button_hover)) and (.foreground | colour_is($t.apex_fg))) and ($rest | all(.background | rgba | .[3] == 0))'
    "${metric[@]}" 'the names are $apex_font_size at $apex_font_label_weight' \
        "$w.app.label" '(.size | px_is($t.apex_font_size)) and .weight == ($t.apex_font_label_weight | tonumber)'
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
modal_dialog() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label modal dialog" "$scenes" "$tokens")
    local d=.surfaces.dialog

    "${metric[@]}" 'a dialog is solid $apex_panel_solid, radius $apex_radius_dialog, $apex_dialog_width wide (polkit), $apex_end_session_dialog_width (end session)' \
        "$d" '(.box | (.background | colour_is($t.apex_panel_solid)) and (.radius | px_is($t.apex_radius_dialog)) and (.width | px_is($t.apex_dialog_width)))
            and (.endSessionWidth + 2 * ($t.apex_dialog_padding | px) | px_is($t.apex_end_session_dialog_width))'
    "${metric[@]}" 'its ring is a $apex_surface_border border in $apex_panel_border, its shadow 0 $apex_shadow_y $apex_shadow_blur $apex_shadow' \
        "$d.box" '(.border.top | px_is($t.apex_surface_border)) and (.borderColor | colour_is($t.apex_panel_border))
            and (.boxShadow | .y == ($t.apex_shadow_y | px) and .blur == ($t.apex_shadow_blur | px) and (.color | colour_is($t.apex_shadow)))'
    "${metric[@]}" 'it is inset $apex_dialog_padding, $apex_dialog_padding_bottom at the bottom, with $apex_dialog_gap between its parts and $apex_dialog_text_gap between title and text' \
        "$d" '(.box | (.padding.top + .border.top | px_is($t.apex_dialog_padding)) and (.padding.left + .border.left | px_is($t.apex_dialog_padding))
            and (.padding.right + .border.right | px_is($t.apex_dialog_padding)) and (.padding.bottom + .border.bottom | px_is($t.apex_dialog_padding_bottom)) and (.spacing | px_is($t.apex_dialog_gap)))
            and (.contentSpacing | px_is($t.apex_dialog_gap)) and (.textSpacing | px_is($t.apex_dialog_text_gap))'
    "${metric[@]}" 'its title is $apex_font_dialog_title_size at $apex_font_heading_weight, its text $apex_font_size in $apex_fg_dim' \
        "$d" '(.title.font.size | px_is($t.apex_font_dialog_title_size)) and .title.font.weight == ($t.apex_font_heading_weight | tonumber)
            and (.description.font.size | px_is($t.apex_font_size)) and (.description.foreground | colour_is($t.apex_fg_dim))'
    "${metric[@]}" 'the password entry is $apex_entry_height high, fully round, $apex_button, padded $apex_entry_padding, $apex_font_entry_size at $apex_font_entry_weight' \
        "$d.entry" '(.height | px_is($t.apex_entry_height)) and .radius >= ($t.apex_entry_height | px) / 2 and (.background | colour_is($t.apex_button)) and .boxShadow == null
            and (.padding.left | px_is($t.apex_entry_padding)) and (.padding.right | px_is($t.apex_entry_padding))
            and (.font.size | px_is($t.apex_font_entry_size)) and .font.weight == ($t.apex_font_entry_weight | tonumber)'
    "${metric[@]}" 'focused, it draws a $apex_entry_focus_ring ring in the raw accent' \
        "{e: $d.entry, accent: .topBar.accent}" '.accent as $a | .e.focus.boxShadow | .inset and (.spread | px_is($t.apex_entry_focus_ring)) and (.color | colour_is($a))'
    "${metric[@]}" 'its buttons are $apex_dialog_button_height high, fully round, $apex_font_dialog_button_size at $apex_font_label_weight' \
        "$d.buttons" 'length == 2 and all((.height | px_is($t.apex_dialog_button_height)) and .radius >= ($t.apex_dialog_button_height | px) / 2
            and (.font.size | px_is($t.apex_font_dialog_button_size)) and .font.weight == ($t.apex_font_label_weight | tonumber))'
    "${metric[@]}" 'a button is $apex_button ($apex_button_hover hovered); the default one the accent with its foreground' \
        "{b: $d.buttons, accent: .topBar.accent}" '.accent as $a | (.b | map(select(.default | not)) | length == 1 and all((.background | colour_is($t.apex_button)) and (.foreground | colour_is($t.apex_fg)) and (.hover.background | colour_is($t.apex_button_hover))))
            and (.b | map(select(.default)) | length == 1 and all((.background | colour_is($a)) and (.foreground | colour_is("#ffffff"))))'
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
date_menu() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label calendar" "$scenes" "$tokens")
    local d=.surfaces.dateMenu
    local inset='[.padding, .border] | [.[0].top + .[1].top, .[0].right + .[1].right, .[0].bottom + .[1].bottom, .[0].left + .[1].left]'

    "${metric[@]}" 'the popover is $apex_date_menu_list_width + $apex_date_menu_gap + $apex_date_menu_column_width inside a $apex_quick_settings_padding glass inset, radius $apex_radius_quick_settings' \
        "$d" "(.box | (.background | colour_is(\$t.apex_panel)) and (.radius | px_is(\$t.apex_radius_quick_settings)) and ($inset | all(px_is(\$t.apex_quick_settings_padding))))
            and (.area.spacing | px_is(\$t.apex_date_menu_gap)) and (.list.width | px_is(\$t.apex_date_menu_list_width)) and (.column.width | px_is(\$t.apex_date_menu_column_width))
            and (.list.border.right == 0) and (.column.spacing | px_is(\$t.apex_date_menu_column_gap))"
    "${metric[@]}" 'a notification card is opaque $apex_message_card ringed in $apex_glass_card_border, radius $apex_radius_message, $apex_message_gap apart' \
        "$d.message" '(.background | colour_is($t.apex_message_card)) and (.borderColor | colour_is($t.apex_glass_card_border)) and (.border.top | px_is($t.apex_surface_border))
            and (.radius | px_is($t.apex_radius_message)) and (.marginBottom | px_is($t.apex_message_gap)) and .boxShadow == null'
    "${metric[@]}" 'it is inset $apex_message_padding, $apex_message_padding_start at the start and $apex_message_padding_end at the end' \
        "$d.message" "$inset"' | (.[0] | px_is($t.apex_message_padding)) and (.[2] | px_is($t.apex_message_padding)) and (.[3] | px_is($t.apex_message_padding_start)) and (.[1] | px_is($t.apex_message_padding_end))'
    "${metric[@]}" 'its header is $apex_font_banner_header_size in $apex_fg_dim, its title $apex_font_size at $apex_font_heading_weight, its body $apex_font_message_body_size in $apex_fg_dim, its icon $apex_message_icon_size' \
        "$d.message" '(.header.font.size | px_is($t.apex_font_banner_header_size)) and (.header.foreground | colour_is($t.apex_fg_dim))
            and (.title.font.size | px_is($t.apex_font_size)) and .title.font.weight == ($t.apex_font_heading_weight | tonumber)
            and (.body.font.size | px_is($t.apex_font_message_body_size)) and (.body.foreground | colour_is($t.apex_fg_dim)) and (.icon | px_is($t.apex_message_icon_size))'
    "${metric[@]}" 'its close button is a $apex_banner_close_size circle in $apex_button' \
        "$d.message.close" '(.width | px_is($t.apex_banner_close_size)) and (.height | px_is($t.apex_banner_close_size)) and (.background | colour_is($t.apex_button))'
    "${metric[@]}" 'the footer is $apex_date_menu_footer_height high; Clear is a $apex_clear_button_height pill in $apex_button, padded $apex_clear_button_padding' \
        "$d" '(.controls.height | px_is($t.apex_date_menu_footer_height)) and (.clear | (.height | px_is($t.apex_clear_button_height)) and .radius >= ($t.apex_clear_button_height | px) / 2
            and (.background | colour_is($t.apex_button)) and (.padding.left | px_is($t.apex_clear_button_padding)))'
    "${metric[@]}" 'the weekday is $apex_font_date_menu_weekday_size $apex_font_heading_weight in $apex_fg_dim over the date at $apex_font_date_menu_date_size $apex_font_date_menu_date_weight' \
        "$d" '(.dayLabel | (.font.size | px_is($t.apex_font_date_menu_weekday_size)) and .font.weight == ($t.apex_font_heading_weight | tonumber) and (.foreground | colour_is($t.apex_fg_dim)))
            and (.dateLabel.font | (.size | px_is($t.apex_font_date_menu_date_size)) and .weight == ($t.apex_font_date_menu_date_weight | tonumber))'
    "${metric[@]}" 'the month is a $apex_glass_card card ringed in $apex_glass_card_border, radius $apex_radius_calendar, inset $apex_calendar_padding, its name $apex_font_calendar_month_size $apex_font_heading_weight' \
        "$d" "(.calendar | (.background | colour_is(\$t.apex_glass_card)) and (.borderColor | colour_is(\$t.apex_glass_card_border)) and (.radius | px_is(\$t.apex_radius_calendar))
            and ($inset | all(px_is(\$t.apex_calendar_padding)))) and (.monthLabel.font | (.size | px_is(\$t.apex_font_calendar_month_size)) and .weight == (\$t.apex_font_heading_weight | tonumber))
            and (.monthLabel.background | rgba | .[3] == 0) and (.pager.width | px_is(\$t.apex_calendar_pager_size))"
    "${metric[@]}" 'weekday headings are $apex_calendar_heading_height high, $apex_font_calendar_heading_size $apex_font_heading_weight in $apex_fg_dim, unfilled' \
        "$d.heading" '(.height | px_is($t.apex_calendar_heading_height)) and (.font.size | px_is($t.apex_font_calendar_heading_size)) and .font.weight == ($t.apex_font_heading_weight | tonumber)
            and (.foreground | colour_is($t.apex_fg_dim)) and (.background | rgba | .[3] == 0)'
    "${metric[@]}" 'days fill the card'"'"'s seven columns $apex_calendar_day_gap apart, $apex_calendar_day_height high and fully round, $apex_font_calendar_day_size in $apex_fg, unfilled, weekends too' \
        "$d" "((.day.width * 7 + 7 * (\$t.apex_calendar_day_gap | px) + 2 * (\$t.apex_calendar_padding | px)) - (\$t.apex_date_menu_column_width | px) | fabs < 7)
            and (.day | (.height | px_is(\$t.apex_calendar_day_height)) and .radius >= (\$t.apex_calendar_day_height | px) / 2 and (.font.size | px_is(\$t.apex_font_calendar_day_size))
            and (.foreground | colour_is(\$t.apex_fg)) and (.background | rgba | .[3] == 0)) and (.weekend.foreground | colour_is(\$t.apex_fg))"
    "${metric[@]}" 'days of other months are $apex_fg_faint; today is the accent at $apex_font_heading_weight' \
        "{d: $d, accent: .topBar.accent}" '.accent as $a | (.d.otherMonth.foreground | colour_is($t.apex_fg_faint))
            and (.d.today | (.background | colour_is($a)) and (.foreground | colour_is("#ffffff")) and .font.weight == ($t.apex_font_heading_weight | tonumber))'
    "${metric[@]}" 'the events card is inset $apex_events_padding_top $apex_events_padding $apex_events_padding_bottom, its title $apex_font_events_title_size $apex_font_heading_weight in $apex_fg_dim' \
        "$d" "(.events | (.background | colour_is(\$t.apex_glass_card)) and (.radius | px_is(\$t.apex_radius_calendar))
            and ($inset | (.[0] | px_is(\$t.apex_events_padding_top)) and (.[1] | px_is(\$t.apex_events_padding)) and (.[2] | px_is(\$t.apex_events_padding_bottom))))
            and (.eventsTitle | (.font.size | px_is(\$t.apex_font_events_title_size)) and .font.weight == (\$t.apex_font_heading_weight | tonumber) and (.foreground | colour_is(\$t.apex_fg_dim)))"
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
overview_style() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label overview" "$scenes" "$tokens")
    local o=.surfaces.overview

    "${metric[@]}" 'the overview is tinted with the $apex_scrim scrim' \
        "$o.group" '(.background | colour_is($t.apex_scrim)) and .boxShadow == null'
    "${metric[@]}" 'the search field is a $apex_search_width x $apex_search_height $apex_pill pill ringed in $apex_pill_border, padded $apex_search_padding, $apex_search_top below the bar' \
        "{o: $o, bar: .topBar.panel.height}" '.bar as $bar | .o.search | (.width | px_is($t.apex_search_width)) and (.height | px_is($t.apex_search_height)) and .radius >= ($t.apex_search_height | px) / 2
            and (.background | colour_is($t.apex_pill)) and (.borderColor | colour_is($t.apex_pill_border)) and (.border.top | px_is($t.apex_surface_border))
            and (.padding.left + .border.left | px_is($t.apex_search_padding)) and (.y - $bar | px_is($t.apex_search_top))'
    "${metric[@]}" 'its text is $apex_font_search_size in $apex_fg, its glyph $apex_quick_settings_icon_size; focused, it draws a $apex_entry_focus_ring ring in the raw accent' \
        "{s: $o.search, accent: .topBar.accent}" '.accent as $a | .s | (.font.size | px_is($t.apex_font_search_size)) and (.foreground | colour_is($t.apex_fg)) and (.icon | px_is($t.apex_quick_settings_icon_size))
            and (.focus.boxShadow | .inset and (.spread | px_is($t.apex_entry_focus_ring)) and (.color | colour_is($a)))'
    "${metric[@]}" 'workspace thumbnails are $apex_thumbnail_gap apart, radius $apex_radius_thumbnail, ringed in $apex_pill_border; the current one in a $apex_thumbnail_indicator accent ring' \
        "{o: $o, accent: .topBar.accent}" '.accent as $a | .o | (.thumbnailsSpacing | px_is($t.apex_thumbnail_gap))
            and (.thumbnail | (.radius | px_is($t.apex_radius_thumbnail)) and (.borderColor | colour_is($t.apex_pill_border)) and (.border.top | px_is($t.apex_surface_border)))
            and (.indicator | (.radius | px_is($t.apex_radius_thumbnail)) and (.border.top | px_is($t.apex_thumbnail_indicator)) and (.borderColor | colour_is($a)))'
    "${metric[@]}" 'a window title is a $apex_caption_height $apex_pill pill ringed in $apex_pill_border, padded $apex_caption_padding, $apex_font_caption_size $apex_font_heading_weight in $apex_fg' \
        "$o.caption" '(.minHeight + 2 * .border.top | px_is($t.apex_caption_height)) and .radius >= ($t.apex_caption_height | px) / 2 and (.background | colour_is($t.apex_pill))
            and (.borderColor | colour_is($t.apex_pill_border)) and (.padding.left + .border.left | px_is($t.apex_caption_padding))
            and (.font.size | px_is($t.apex_font_caption_size)) and .font.weight == ($t.apex_font_heading_weight | tonumber) and (.foreground | colour_is($t.apex_fg))'
    "${metric[@]}" 'a search section is a $apex_glass_card card ringed in $apex_glass_card_border, radius $apex_radius_message, its text $apex_fg' \
        "$o.section" '(.background | colour_is($t.apex_glass_card)) and (.borderColor | colour_is($t.apex_glass_card_border)) and (.radius | px_is($t.apex_radius_message)) and (.foreground | colour_is($t.apex_fg))'
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
app_grid() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label launcher" "$scenes" "$tokens")
    local g=.surfaces.appGrid

    "${metric[@]}" 'an app tile is unfilled, radius $apex_radius_app_tile, padded $apex_app_tile_padding, $apex_app_tile_gap above its name at $apex_font_app_label_size $apex_font_label_weight in $apex_fg' \
        "$g.app" '(.background | rgba | .[3] == 0) and (.radius | px_is($t.apex_radius_app_tile)) and (.padding.top | px_is($t.apex_app_tile_padding))
            and (.spacing | px_is($t.apex_app_tile_gap)) and (.labelFont.size | px_is($t.apex_font_app_label_size)) and .labelFont.weight == ($t.apex_font_label_weight | tonumber)
            and (.foreground | colour_is($t.apex_fg))'
    "${metric[@]}" 'hovered it is $apex_button; focused, $apex_button in a $apex_entry_focus_ring raw-accent ring' \
        "{a: $g.app, accent: .topBar.accent}" '.accent as $c | .a | (.hover.background | colour_is($t.apex_button)) and (.focus.background | colour_is($t.apex_button))
            and (.focus.boxShadow | .inset and (.spread | px_is($t.apex_entry_focus_ring)) and (.color | colour_is($c)))'
    "${metric[@]}" 'a folder tile is $apex_folder ringed in $apex_pill_border' \
        "$g.folder" '(.background | colour_is($t.apex_folder)) and (.borderColor | colour_is($t.apex_pill_border)) and (.border.top | px_is($t.apex_surface_border))'
    "${metric[@]}" 'the folder dialog is $apex_folder_dialog_width of $apex_folder_panel glass ringed in $apex_panel_border, radius $apex_radius_folder_dialog, inset $apex_folder_dialog_padding ($apex_folder_dialog_padding_bottom at the bottom)' \
        "$g.dialog" '(.width | px_is($t.apex_folder_dialog_width)) and (.background | colour_is($t.apex_folder_panel)) and (.borderColor | colour_is($t.apex_panel_border))
            and (.radius | px_is($t.apex_radius_folder_dialog)) and (.padding.left + .border.left | px_is($t.apex_folder_dialog_padding))
            and (.padding.bottom + .border.bottom | px_is($t.apex_folder_dialog_padding_bottom))
            and (.boxShadow | .y == ($t.apex_shadow_y | px) and .blur == ($t.apex_shadow_blur | px) and (.color | colour_is($t.apex_shadow)))'
    "${metric[@]}" 'its title is $apex_font_folder_title_size $apex_font_heading_weight in $apex_fg; its button a $apex_folder_close_size circle in $apex_button' \
        "$g.dialog" '(.title.font.size | px_is($t.apex_font_folder_title_size)) and .title.font.weight == ($t.apex_font_heading_weight | tonumber) and (.title.foreground | colour_is($t.apex_fg))
            and (.button | (.width | px_is($t.apex_folder_close_size)) and (.height | px_is($t.apex_folder_close_size)) and (.background | colour_is($t.apex_button)))'
    "${metric[@]}" 'running dots are $apex_running_dot_size round in $apex_fg at $apex_running_dot_opacity; page indicators $apex_fg; page hints flat, no gradient' \
        "$g" '(.runningDot | (.width | px_is($t.apex_running_dot_size)) and (.height | px_is($t.apex_running_dot_size)) and (.radius * 2 | px_is($t.apex_running_dot_size))
            and (.background | rgba | .[3] - (($t.apex_running_dot_opacity | num) * 255) | fabs <= 1))
            and (.pageIndicator.background | colour_is($t.apex_fg)) and .pageHint.gradient == 0'
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
derived_surfaces() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label derived surfaces" "$scenes" "$tokens")
    local d=.surfaces.derived
    local ring='(.border.top | px_is($t.apex_surface_border)) and (.borderColor | colour_is($t.apex_panel_border))
        and (.boxShadow | .y == ($t.apex_shadow_y | px) and .blur == ($t.apex_shadow_blur | px) and (.color | colour_is($t.apex_shadow)))'

    "${metric[@]}" 'the workspace switcher and the resize popup take the OSD'"'"'s $apex_panel tint, ring and shadow, radius $apex_radius_osd' \
        "[$d.workspaceSwitcher, $d.resizePopup]" "all((.background | colour_is(\$t.apex_panel)) and (.radius | px_is(\$t.apex_radius_osd)) and $ring)"
    "${metric[@]}" 'the workspace dots are $apex_fg_faint, the current one $apex_fg' \
        "$d.wsIndicator" '(.background | colour_is($t.apex_fg_faint)) and (.active.background | colour_is($t.apex_fg))'
    "${metric[@]}" 'the input method'"'"'s candidates take the popup menu: $apex_panel_solid, ring and shadow, radius $apex_radius_menu; rows radius $apex_radius_menu_row, $apex_button_hover when hovered' \
        "$d" "(.candidatePopup | (.background | colour_is(\$t.apex_panel_solid)) and (.radius | px_is(\$t.apex_radius_menu)) and $ring)
            and (.candidateBox | (.radius | px_is(\$t.apex_radius_menu_row)) and (.hover.background | colour_is(\$t.apex_button_hover)))"
    "${metric[@]}" 'the run dialog'"'"'s entry is the password entry: $apex_entry_height, $apex_button, a $apex_entry_focus_ring raw-accent ring when focused' \
        "{e: $d.runEntry, accent: .topBar.accent}" '.accent as $a | .e | (.minHeight | px_is($t.apex_entry_height)) and (.background | colour_is($t.apex_button)) and .boxShadow == null
            and (.focus.boxShadow | .inset and (.spread | px_is($t.apex_entry_focus_ring)) and (.color | colour_is($a)))'
    "${metric[@]}" 'an audio device tile takes the switcher'"'"'s: radius $apex_radius_switcher_item, unfilled, $apex_button_hover when hovered, $apex_fg' \
        "$d.audioDevice" '(.radius | px_is($t.apex_radius_switcher_item)) and (.background | rgba | .[3] == 0) and (.hover.background | colour_is($t.apex_button_hover)) and (.foreground | colour_is($t.apex_fg))'
    "${metric[@]}" 'the monitor number takes the OSD'"'"'s radius $apex_radius_osd' \
        "$d.monitorLabel.radius" 'px_is($t.apex_radius_osd)'
}

scenes_captured() {
    local run=$1 case_name=$2
    local log=$run/$case_name.log scene
    expect_report "$case_name" "$log" '.error == null' "the probe measured and captured its scenes" APEXG2-SCENES
    expect_report "$case_name" "$log" '[.scenes[] | .idle] | all' "each scene went idle before its capture" APEXG2-SCENES
    for scene in "${SCENES[@]}"; do
        check "$case_name: $scene captured ($case_name-$scene.png)" test -s "$run/captures/$case_name-$scene.png"
    done
}

compare_with_fedora() {
    local run=$1 scene plan=$1/compare/fedora-plan.json results=$1/compare/fedora-results.json
    mkdir -p "$run/compare"
    {
        # The Apex bar is $apex_bar_height, upstream's 2.2em: the overview below it lays out on
        # another work area, so overview_below_bar checks its layout instead.
        plan_entry apex-light-vs-fedora-desktop "$run" fedora-light "$run" default desktop "$run/compare" panel dock
        plan_entry apex-dark-vs-fedora-desktop "$run" fedora-dark "$run" dark-style desktop "$run/compare" panel dock
        for scene in "${SCENES[@]}"; do
            plan_entry "safe-light-vs-fedora-$scene" "$run" fedora-light "$run" stock-light "$scene" "$run/compare"
            plan_entry "safe-dark-vs-fedora-$scene" "$run" fedora-dark "$run" stock-dark "$scene" "$run/compare"
        done
    } | jq -s . >"$plan"
    compare_and_expect_equal "$plan" "$results"
}

overview_below_bar() {
    local label=$1 log=$2
    expect_report "$label" "$log" '(.scenes.overview.workArea.y - .topBar.panel.height) | fabs <= 0.5' \
        "the overview lays out below the bar: its work area starts at the bar's height" APEXG2-SCENES
}

high_contrast_is_fedoras() {
    local run=$1 fedora
    fedora=$(report_of "$run/fedora-light.log" | jq -r '.highContrastSheet.sha256WithoutStructureMarker // empty')
    expect_report fedora-light "$run/fedora-light.log" '.highContrastSheet.structure == false' \
        "Fedora's high-contrast sheet has no Apex structure marker"
    expect_report stock-light "$run/stock-light.log" \
        ".highContrastSheet | .structure and .sha256WithoutStructureMarker == \"${fedora:-none}\"" \
        "the rebuilt high-contrast sheet, which safe mode keeps (it has no stock copy), is Fedora's apart from the structure marker"
}

fedora_baseline() {
    local run=$1 v f safe
    echo "# Fedora's own build: $(grep -m1 '^gnome-shell-[0-9]' "$run/fedora-image.txt" 2>/dev/null)"
    check "the baseline's gnome-shell and gnome-shell-common are Fedora's build of the tested NVR, signed with Fedora's key alone" \
        grep -qx 'baseline: Fedora-signed' "$run/fedora-image.txt"
    for v in light dark; do
        f=$run/fedora-$v.log
        exits "$run" "fedora-$v" 0
        expect_report "fedora-$v" "$f" ".apexHooks == false and .stylesheet == \"$FEDORA_SHEETS/gnome-shell-$v.css\" and .variant == \"$v\"" \
            "Fedora's shell: no Apex module, upstream's $v sheet at its own path"
        safe=$(report_of "$run/stock-$v.log" | jq -r '.sheet.sha256 // empty')
        expect_report "fedora-$v" "$f" ".sheet.sha256 == \"${safe:-none}\"" \
            "the same bytes as safe mode's theme/stock/gnome-shell-$v.css (sha256 ${safe:0:12}...)"
    done
}

stock_thumbnails() {
    local run=$1 c fedora
    fedora=$(report_of "$run/fedora-light.log" APEXG2-SCENES | jq -c '.scenes.overview.thumbnails // empty')
    for c in stock-light stock-dark; do
        expect_report "$c" "$run/$c.log" ".scenes.overview.thumbnails | .shown and .maxScale == $STOCK_MAX_THUMBNAIL_SCALE" \
            "the overview's workspace thumbnails at upstream's maximum scale, $STOCK_MAX_THUMBNAIL_SCALE" APEXG2-SCENES
        expect_report "$c" "$run/$c.log" ".scenes.overview.thumbnails == ${fedora:-null}" \
            "and the effective scale of Fedora's build ($(jq -r '.scale // "none"' <<<"${fedora:-null}"))" APEXG2-SCENES
    done
}

dark_style_off() {
    local label=$1 log=$2 toggled
    toggled=$(report_of "$log" APEXG2-TOGGLED)
    expect "$label" "$toggled" '.toggle.checkedBefore == true and .toggle.checkedAfter == false' \
        "Quick Settings' Dark Style toggle, on with prefer-dark, turns off when clicked"
    expect "$label" "$toggled" '.colorSchemeSetting == "default"' "the toggle writes color-scheme 'default'"
    expect "$label" "$toggled" ".stylesheet == \"$APEX_LIGHT_SHEET\" and .sheet.markers == [\"light\"] and .variant == \"light\" and (.markerColor | colour_is(\"#16161a\"))" \
        "the running shell turns light: the Apex light sheet, the light variant, the light bar token (#16161a)"
}

same_stock_sheet() {
    local run=$1 shas f report
    shas=$(for f in "$run"/safe-env.log "$run"/layer-disabled.log "$run"/kernel-safe.log "$run"/stock-dark.log "$run"/guard-next.journal; do
        report=$(report_of "$f")
        jq -r '.sheet.sha256 // "none"' <<<"${report:-null}"
    done | sort -u)
    if [[ $(wc -l <<<"$shas") == 1 && $shas != none ]]; then
        pass "every kill switch, the stock-dark case and the guarded next login load the same stock dark sheet (sha256 ${shas:0:12}...)"
    else
        fail "the kill switches load different dark sheets: $(paste -sd' ' <<<"$shas")"
    fi
}

fixtures_on_the_bus() {
    local run=$1 part fixtures
    local -a parts=("${@:2}")
    ((${#parts[@]})) || parts=("${DIRECT_PARTS[@]}")
    for part in "${parts[@]}"; do
        fixtures=$(report_of "$run/fixtures-$part.txt" G2-FIXTURES)
        expect "fixtures ($part)" "$fixtures" ".battery | .present and .onBattery and .percentage == $BATTERY_PERCENT" \
            "UPower's display device: a battery at $BATTERY_PERCENT %, discharging"
        expect "fixtures ($part)" "$fixtures" '.wifi | .primary == "Apex-5G" and .ssid == "Apex-5G" and .strength >= 80 and .state == 70 and .connectivity == 4' \
            "NetworkManager: the primary connection is Wi-Fi \"Apex-5G\" at full signal, connected globally"
        expect "fixtures ($part)" "$fixtures" '.wifi.inRange == ["Apex-5G", "Apex-2.4G", "Library Guest"]' \
            "NetworkManager: \"Apex-2.4G\" and the open \"Library Guest\" are in range too"
        expect "fixtures ($part)" "$fixtures" '.keyboard | .alias == "Keychron K3" and .connected and .icon == "input-keyboard"' \
            "BlueZ: the keyboard \"Keychron K3\" is connected"
    done
}

fixed_clock() {
    local label=$1 log=$2
    expect_report "$label" "$log" ".clock.now == \"$FIXED_CLOCK\"" "the wall clock stands at $FIXED_CLOCK (clock.c)"
    expect_report "$label" "$log" ".clock.text == \"$FIXED_CLOCK_TEXT\"" "and the top bar's clock shows it"
}

# shellcheck disable=SC2016 # jq programs
layer_cycles() {
    local run=$1 f=$1/layer-cycles.log cycles turns
    exits "$run" layer-cycles 0
    apex_light layer-cycles "$f"
    no_apex_failure layer-cycles "$f"
    cycles=$(report_of "$f" APEXG2-CYCLES)
    turns=$(jq -nc --argjson n "$LAYER_CYCLES" '[true] + ([range($n) | false, true])')
    expect layer-cycles "$cycles" ".error == null and [.states[].layerEnabled] == $turns" \
        "layer-enabled turned off and on $LAYER_CYCLES times in one shell, each state measured"
    expect layer-cycles "$cycles" "[.states[] | select(.layerEnabled | not)] | length == $LAYER_CYCLES and all(.stylesheet == \"$STOCK_SHEETS/gnome-shell-dark.css\" and .markers == [] and .safe and .sessionColorScheme == \"prefer-dark\" and .variant == \"dark\" and (.markerColor | (colour_is(\"#16161a\") or colour_is(\"#f6f6f8\")) | not))" \
        "while it is off: upstream's dark sheet from theme/stock/, the stock colour scheme, every hook stock"
    expect layer-cycles "$cycles" "[.states[] | select(.layerEnabled)] | length == $LAYER_CYCLES + 1 and all(.stylesheet == \"$APEX_LIGHT_SHEET\" and .markers == [\"light\"] and (.safe | not) and .sessionColorScheme == \"prefer-light\" and .variant == \"light\" and (.markerColor | colour_is(\"#16161a\")))" \
        "while it is on: the Apex light sheet, prefer-light, the light bar token (#16161a)"
    expect layer-cycles "$cycles" '[.states[] | select(.layerEnabled | not) | .spotlightKey.modes] | length > 0 and all(. == [])' \
        "while it is off: no Super+Space binding"
    expect layer-cycles "$cycles" "[.states[] | select(.layerEnabled) | .spotlightKey.modes] | length > 0 and all(. == $SPOTLIGHT_MODES)" \
        "while it is on: Super+Space in the normal and overview modes"
    expect layer-cycles "$cycles" '[.states[] | select(.layerEnabled) | .actors] | length > 1 and (unique | length) == 1' \
        "nothing left behind: each time it is on, the stage holds the same actors, type by type, as at startup"
    expect layer-cycles "$cycles" '[.states[] | select(.layerEnabled | not) | .actors] | length > 1 and (unique | length) == 1' \
        "and each time it is off, the same as the first time"
    check "layer-cycles: the layer logs each switch ($LAYER_CYCLES x off, $LAYER_CYCLES x on)" bash -c \
        "[[ \$(grep -c 'Apex: layer-enabled is false: the stock shell' '$f') == $LAYER_CYCLES && \$(grep -c 'Apex: layer-enabled is true: the Apex shell' '$f') == $LAYER_CYCLES ]]"
    check "layer-cycles: the marker is removed at shutdown" grep -q '^layer-cycles .*marker-after-exit=no' "$run/results-main.txt"
}

direct_cases() {
    local run=$1 c f
    echo "# the direct cases: $(grep -m1 -E '^gnome-shell-[0-9]' "$run/rpm.txt" 2>/dev/null)"
    check "the bus image's gnome-shell, mutter and apex-desktop verify unmodified (rpm -V), before and after dbus-daemon joined them" \
        test "$(grep -cx 'rpm -V rc=0' "$run/rpm.txt")" = 2
    for c in "${DIRECT_CASES[@]}"; do
        f=$run/$c.log
        if [[ ! -s $f ]]; then
            fail "$c: no log"
            continue
        fi
        no_js_error "$c" "$f"
        no_late_start "$c" "$f"
        # fault-abort may abort before its report; its exit status says the shell ran.
        [[ $c == fault-abort ]] && continue
        expect_report "$c" "$f" '.mode == "user"' "the probe ran: the static import graph loaded"
        fixed_clock "$c" "$f"
    done
    fixtures_on_the_bus "$run"

    f=$run/default.log
    exits "$run" default 0
    apex_light default "$f"
    no_apex_failure default "$f"
    spotlight_key default "$f"
    search_hint default "$f" true
    virtual_monitor default "$f"
    expect_report default "$f" '.testFault == "stock" and .env.APEX_SHELL_TEST_FAULT == null' \
        "no fault feature without APEX_SHELL_TEST_FAULT"
    expect_report default "$f" '.startingMarker == true' "the layer created %t/apex-shell-starting at enable"
    check "default: the marker is removed at shutdown" grep -q '^default .*marker-after-exit=no' "$run/results-main.txt"
    top_bar default "$f" light
    top_bar_today default "$f" light
    top_bar_gaps default "$f" light
    dock_metrics default "$f" light
    shell_surfaces default "$f" light
    quick_settings default "$f" light
    window_switcher default "$f" light
    modal_dialog default "$f" light
    date_menu default "$f" light
    overview_style default "$f" light
    app_grid default "$f" light
    derived_surfaces default "$f" light

    f=$run/default-scale1.log
    exits "$run" default-scale1 0
    apex_light default-scale1 "$f"
    no_apex_failure default-scale1 "$f"
    spotlight_key default-scale1 "$f"
    virtual_monitor default-scale1 "$f" 1
    top_bar default-scale1 "$f" light
    top_bar_today default-scale1 "$f" light
    dock_metrics default-scale1 "$f" light
    shell_surfaces default-scale1 "$f" light
    quick_settings default-scale1 "$f" light
    window_switcher default-scale1 "$f" light
    modal_dialog default-scale1 "$f" light
    date_menu default-scale1 "$f" light
    overview_style default-scale1 "$f" light
    app_grid default-scale1 "$f" light
    derived_surfaces default-scale1 "$f" light

    f=$run/dark-style.log
    exits "$run" dark-style 0
    expect_report dark-style "$f" ".stylesheet == \"$APEX_DARK_SHEET\" and .sheet.markers == [\"dark\"]" \
        "color-scheme prefer-dark loads the Apex dark sheet with its marker"
    expect_report dark-style "$f" '(.markerColor | colour_is("#f6f6f8")) and .safe == false' \
        "the marker actor takes the dark bar token (#f6f6f8)"
    no_apex_failure dark-style "$f"
    spotlight_key dark-style "$f"
    top_bar dark-style "$f" dark
    top_bar_today dark-style "$f" dark
    top_bar_gaps dark-style "$f" dark
    dock_metrics dark-style "$f" dark
    shell_surfaces dark-style "$f" dark
    quick_settings dark-style "$f" dark
    window_switcher dark-style "$f" dark
    modal_dialog dark-style "$f" dark
    date_menu dark-style "$f" dark
    overview_style dark-style "$f" dark
    app_grid dark-style "$f" dark
    derived_surfaces dark-style "$f" dark
    dark_style_off dark-style "$f"

    for c in dock-intellihide dock-intellihide-dark; do
        exits "$run" "$c" 0
        no_apex_failure "$c" "$run/$c.log"
        dock_intellihide "$c" "$run/$c.log" "$run"
    done

    for c in stock-light stock-dark; do
        exits "$run" "$c" 0
        stock_view "$c" "$run/$c.log" "${c#stock-}"
        no_dock "$c" "$run/$c.log"
        no_apex_failure "$c" "$run/$c.log"
    done
    stock_thumbnails "$run"

    f=$run/safe-env.log
    exits "$run" safe-env 0
    logs safe-env "$f" 'Apex: safe mode \(APEX_SHELL_SAFE=1\)' "logs 'Apex: safe mode (APEX_SHELL_SAFE=1)'"
    stock_view safe-env "$f" dark
    stock_scheme safe-env "$f"
    search_hint safe-env "$f" false
    virtual_monitor safe-env "$f"

    f=$run/layer-disabled.log
    exits "$run" layer-disabled 0
    logs layer-disabled "$f" 'Apex: safe mode \(layer-enabled is false\)' "logs 'Apex: safe mode (layer-enabled is false)'"
    expect_report layer-disabled "$f" '.layerEnabled == false' "the user's layer-enabled is false"
    stock_view layer-disabled "$f" dark
    stock_scheme layer-disabled "$f"

    layer_cycles "$run"

    f=$run/kernel-safe.log
    check "kernel-safe: /proc/cmdline carries apex.safe=1" grep -qw 'apex.safe=1' "$run/cmdline-kernel.txt"
    check "the other cases: the VM's /proc/cmdline has no apex.safe=1" bash -c "! grep -qw apex.safe=1 '$run/cmdline-main.txt'"
    exits "$run" kernel-safe 0
    logs kernel-safe "$f" 'Apex: safe mode \(apex\.safe=1\)' "logs 'Apex: safe mode (apex.safe=1)'"
    stock_view kernel-safe "$f" dark
    stock_scheme kernel-safe "$f"
    same_stock_sheet "$run"

    f=$run/fault-configure.log
    exits "$run" fault-configure 0
    logs fault-configure "$f" 'Apex: feature fault off for this session \(configure: Error: injected fault in configure' \
        "the fault feature is off for the session (configure)"
    logs fault-configure "$f" 'Apex: feature witness enabled' "the feature after it still enables"
    expect_report fault-configure "$f" '.testFault == "stock"' "the fault feature's hook gives stock"
    apex_light fault-configure "$f"
    spotlight_key fault-configure "$f"

    f=$run/fault-enable.log
    exits "$run" fault-enable 0
    logs fault-enable "$f" 'Apex: feature fault off for this session \(enable: Error: injected fault in enable' \
        "only the fault feature is off for the session (enable)"
    logs fault-enable "$f" 'Apex: feature witness enabled' "the feature after it still enables"
    expect_report fault-enable "$f" '.testFault == "stock"' "the fault feature's hook gives stock"
    apex_light fault-enable "$f"
    spotlight_key fault-enable "$f"
    logs fault-enable "$f" 'APEXG2-SURVIVED 10s' "the rest of the layer runs: the shell is still up 10 s later"

    f=$run/fault-abort.log
    exits "$run" fault-abort 134
    logs fault-abort "$f" 'Apex: feature fault enabled' "the fault feature enabled"
    logs fault-abort "$f" 'Apex-ERROR \*\*: .*aborting the shell' "then aborted the shell (SIGABRT)"
    check "fault-abort: %t/apex-shell-starting is left behind" grep -q '^fault-abort .*marker-after-exit=yes' "$run/results-main.txt"

    fedora_baseline "$run"
    high_contrast_is_fedoras "$run"
    for c in "${CAPTURE_CASES[@]}"; do
        scenes_captured "$run" "$c"
        overview_below_bar "$c" "$run/$c.log"
    done
    compare_with_fedora "$run"
}

g1_on_the_image() {
    local run=$1
    if [[ $(cat "$run/g1-desktop.rc" 2>/dev/null) == 0 ]]; then
        pass "G1's desktop checks pass on the tested image: no text file under /usr or /etc names APEX_SHELL_TEST_FAULT"
    else
        fail "G1's desktop checks fail on the tested image (exit $(cat "$run/g1-desktop.rc" 2>/dev/null)): $(grep -m3 '^FAIL' "$run/g1-desktop.txt" | paste -sd'|' -)"
    fi
    if grep -q 'APEX_SHELL_TEST_FAULT' "$run/guard-env.txt" 2>/dev/null; then
        fail "the image's user manager or shell unit sets APEX_SHELL_TEST_FAULT: $(grep -m1 APEX_SHELL_TEST_FAULT "$run/guard-env.txt")"
    elif grep -q '^# end$' "$run/guard-env.txt" 2>/dev/null; then
        pass "neither the image's user manager nor the shell's unit sets APEX_SHELL_TEST_FAULT"
    else
        fail "the image's shell environment was not recorded (guard-env.txt)"
    fi
}

crash_guard() {
    local run=$1 guard_log=$1/guard.log f t
    echo "# the crash guard"
    if grep -q 'G2-GUARD-ABORT' "$guard_log" || [[ ! -s $run/guard-trip.state ]]; then
        fail "guard: the user manager did not come up: $(grep -m1 'G2-GUARD-ABORT' "$guard_log")"
        return
    fi
    check "guard: org.gnome.Shell@user.service carries OnFailure=... apex-shell-safe.service from the image's drop-in" \
        grep -q '^OnFailure=.*apex-shell-safe.service' "$guard_log"
    check "guard: the image's 50-apex.conf is among the unit's drop-ins" \
        grep -q '^DropInPaths=.*/usr/lib/systemd/user/org.gnome.Shell@.service.d/50-apex.conf' "$guard_log"

    f=$run/guard-window.journal
    expect_report window "$f" '.safe == false and .sheet.markers == ["light"]' "the systemd-started shell runs the Apex layer (light sheet)"
    check "window: the layer removed its marker by 65 s" grep -q 'starting marker gone' "$run/guard-window.marker65"
    check "window: SIGABRT after 65 s fails the unit (core-dump) and triggers OnFailure=" \
        bash -c "grep -q 'Failed with result .core-dump.' '$f' && grep -q 'Triggering OnFailure= dependencies' '$f'"
    check "window: apex-shell-safe.service is skipped (ConditionPathExists=%t/apex-shell-starting unmet)" \
        grep -q 'apex-shell-safe.service .*skipped, unmet condition check ConditionPathExists=/run/user/1000/apex-shell-starting' "$f"
    check "window: layer-enabled stays true" grep -q '^layer-enabled=true$' "$run/guard-window.state"
    check "window: no guard marker" grep -q 'guard marker: .*No such file' "$run/guard-window.state"

    for t in trip trip-warm; do
        f=$run/guard-$t.journal
        echo "# $t: $(cat "$run/guard-$t.dconf")"
        check "$t: abort-after-enable aborts the shell (code=dumped, status=6/ABRT) and triggers OnFailure=" \
            bash -c "grep -q 'aborting the shell' '$f' && grep -q 'Main process exited, code=dumped, status=6/ABRT' '$f' && grep -q 'Triggering OnFailure= dependencies' '$f'"
        check "$t: apex-shell-safe.service ran (Starting ... Finished)" \
            bash -c "grep -q 'Starting apex-shell-safe.service' '$f' && grep -q 'Finished apex-shell-safe.service' '$f'"
        check "$t: its gsettings write reached dconf (no 'failed to commit changes to dconf')" \
            bash -c "! grep -q 'failed to commit changes to dconf' '$f'"
        check "$t: layer-enabled is false afterwards" grep -q '^layer-enabled=false$' "$run/guard-$t.state"
        check "$t: ~/.local/state/apex/shell-guard-tripped exists" grep -q 'guard marker: -rw' "$run/guard-$t.state"
        check "$t: %t/apex-shell-starting is removed" grep -q 'starting marker: .*No such file' "$run/guard-$t.state"
    done

    f=$run/guard-next.journal
    logs next "$f" 'Apex: safe mode \(layer-enabled is false\)' "the next login logs 'Apex: safe mode (layer-enabled is false)'"
    no_apex_failure next "$f"
    stock_view next "$f" dark
    stock_scheme next "$f"
    check "next: the shell ends cleanly (no OnFailure=)" bash -c "! grep -q 'Triggering OnFailure' '$f'"

    f=$run/guard-back-on.journal
    expect_report back-on "$f" '.safe == false and .sheet.markers == ["light"] and (.markerColor | colour_is("#16161a"))' \
        "layer-enabled=true brings the Apex light shell back"
    no_apex_failure back-on "$f"

    f=$run/guard-dark-off.journal
    dark_style_off dark-off "$f"
    check "dark-off: after the toggle the user manager lists its loaded units ($ALWAYS_LOADED_USER_UNIT among them), and no Apex unit is active or activating" \
        no_apex_unit_active "$run/guard-dark-off.units"
    check "dark-off: no Apex unit or D-Bus service started during the phase" no_line_matches "$APEX_UNIT_STARTED" "$f"
    check "guard: no 'JS ERROR' in the user's whole journal" grep -q '^JS ERROR lines: 0$' "$guard_log"
    local late
    late=$(grep -l 'APEXG2-LATE' "$run"/guard-*.journal 2>/dev/null | sed 's|.*/guard-||; s|\.journal$||' | paste -sd' ' -)
    echo "# guard phases whose probe started late (main.js's startup-complete handler did not run there): ${late:-none}"
}

main() {
    case ${1:-} in
        -h | --help) usage; exit 0 ;;
        '') usage >&2; exit 2 ;;
    esac
    local run=$1
    echo "# G2 run $run: $(head -n 3 "$run/image.txt" 2>/dev/null | paste -sd' ' -)"
    g1_on_the_image "$run"
    direct_cases "$run"
    crash_guard "$run"
    summary
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
