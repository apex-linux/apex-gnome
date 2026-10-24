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
readonly DIRECT_CASES=(default default-scale1 dark-style dock-intellihide dock-intellihide-dark stock-light stock-dark safe-env
    layer-disabled layer-cycles motion idle fault-configure fault-enable fault-abort kernel-safe fedora-light fedora-dark glass fedora-glass
    indicators indicators-scale1 indicators-dark)
readonly DIRECT_PARTS=(main kernel fedora)
readonly CAPTURE_CASES=(default default-scale1 dark-style stock-light stock-dark fedora-light fedora-dark)
readonly SCENES=(desktop overview)
readonly STOCK_MAX_THUMBNAIL_SCALE=0.05
readonly OVERVIEW_THUMBNAIL_SCALE=0.081
readonly OVERVIEW_THUMBNAILS_THRESHOLD=1
readonly EMPTY_WORKSPACE_TEXT='No open windows'
readonly LAUNCHER_COLUMNS=7
readonly LAUNCHER_ROWS=4
readonly LAUNCHER_ICON_SIZE=88
readonly LAUNCHER_GRID_TOP=132
# overviewControls.js: spacing is 2 % of the work area, the stock .search-entry keeps 6 px below it.
readonly OVERVIEW_SPACING_RATIO=0.02
readonly STOCK_SEARCH_MARGIN_BOTTOM=6
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
readonly TILES_FILE=${G2_TILES_FILE:-$SHOTS_DIR/../../desktop/shell/js/ui/apex/spotlight/settings-tiles.json}
readonly SPOTLIGHT_ACCELERATORS='["<Super>space"]'
readonly SPOTLIGHT_MODES='["NORMAL", "OVERVIEW"]'
# DESIGN's motion: cubic-bezier(.2,.8,.2,1); window geometry .3 s, the overview .2 s.
readonly MOTION_CURVE='[0.2, 0.8, 0.2, 1]'
readonly MOTION_WINDOW_MS=300
readonly MOTION_OVERVIEW_MS=200
readonly LOCATE_POINTER_RIPPLE_MS=830
# ROADMAP S3c: an idle desktop shows no extra repaints, with every feature of the layer on.
readonly APEX_JS_DIR=${G2_APEX_JS_DIR:-$SHOTS_DIR/../../desktop/shell/js/ui/apex}
readonly IDLE_WINDOW_MS=10000
# direct.sh's G2_CLOCK, in UTC; the clock shows it as weekday, date, EN SPACE, 24-hour time.
readonly FIXED_CLOCK=2026-09-28T09:41:00Z
readonly FIXED_CLOCK_TEXT='Mon Sep 28\u200209:41'
readonly BATTERY_PERCENT=87
readonly WIFI_GLYPH=network-wireless-signal-excellent-symbolic
readonly BATTERY_GLYPH=battery-level-80-symbolic
readonly BLUETOOTH_GLYPH=bluetooth-active-symbolic
readonly ALWAYS_LOADED_USER_UNIT=default.target
# ROADMAP S2b: glass against blur-ref.js after partial damage, per channel out of 255, as the
# first run fixed them (lead, 2026-10-24). The edge band is ds/2 px wide, ds the effect's own.
readonly GLASS_INTERIOR_MAX=4
readonly GLASS_EDGE_MAX=12
readonly GLASS_MEAN_ERROR=1
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
    "${metric[@]}" "the search button starts the right box, the status pill ends it: a \$apex_bar_search_width x \$apex_bar_pill_height pill, radius \$apex_radius_bar_pill, named \"$SEARCH_BUTTON_NAME\"" \
        '.topBar.rightItems' \
        "length >= 2 and .[-1].accessibleName == \"$STATUS_BUTTON_NAME\" and .[0].accessibleName == \"$SEARCH_BUTTON_NAME\"
            and (.[0].pill | (.width | px_is(\$t.apex_bar_search_width)) and (.height | px_is(\$t.apex_bar_pill_height)) and (.radius | px_is(\$t.apex_radius_bar_pill)))"
    "${metric[@]}" 'the clock pill is centred on the bar' \
        '.topBar | .clock.pill.x + .clock.pill.width / 2 - .panel.width / 2' 'fabs <= 0.5'
    "${metric[@]}" 'the bar changes over $apex_bar_transition' \
        '.topBar.panel.transition' '. == ($t.apex_bar_transition | rtrimstr("ms") | tonumber)'
    "${metric[@]}" 'the bar is glass: a Shell.BlurEffect of radius 2 x $apex_bar_blur x the monitor scale at $apex_bar_saturation' \
        '{glass: .topBar.glass, scale: .monitorScale}' \
        '.scale as $s | .glass | any((.radius - 2 * ($t.apex_bar_blur | px) * $s | fabs < 0.01) and .saturation != null and ((.saturation - ($t.apex_bar_saturation | rtrimstr("%") | tonumber / 100)) | fabs < 0.01))'
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
    "${metric[@]}" "its apps' menu offers Launch Using Discrete Graphics Card while switcheroo-control reports two GPUs" \
        '.dock.appMenu' '.hasDualGpu == true and (.items | any(. == "Launch Using Discrete Graphics Card"))'
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

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
indicator_metrics() {
    local label=$1 log=$2 variant=$3 report tokens
    report=$(report_of "$log" APEXG2-INDICATORS)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label indicators" "$report" "$tokens")
    local four='["File sync", "Chat", "Game launcher", "Password manager"]'

    "${metric[@]}" 'with no items there are no indicators and no divider' \
        '.empty' '.visible == false and .divider == null'
    "${metric[@]}" 'sni-items.js'"'"'s four items show in the order they registered, then the divider, then the search button' \
        '.four | {names: [.items[].name], order}' \
        ".names == $four and ((.order | index(\"indicators\")) as \$i | \$i != null and .order[\$i + 1] == \"divider\" and .order[\$i + 2] == \"apex-search\")"
    "${metric[@]}" 'each is a $apex_indicator_width x $apex_bar_pill_height pill, radius $apex_radius_bar_pill, $apex_bar_gap apart' \
        '.four.items | map(.pill)' \
        'length == 4 and all((.width | px_is($t.apex_indicator_width)) and (.height | px_is($t.apex_bar_pill_height)) and (.radius | px_is($t.apex_radius_bar_pill)))
            and ([range(1; length) as $i | .[$i].x - .[$i - 1].x - .[$i - 1].width] | all(px_is($t.apex_bar_gap)))'
    "${metric[@]}" 'each glyph is $apex_bar_icon_size in $apex_bar_fg, centred in its pill' \
        '.four.items' 'all(.glyph | (.width | px_is($t.apex_bar_icon_size)) and (.height | px_is($t.apex_bar_icon_size)) and (.colour | colour_is($t.apex_bar_fg)))
            and all((.glyph.x + .glyph.width / 2 - .pill.x - .pill.width / 2 | fabs < 0.51) and (.glyph.y + .glyph.height / 2 - .pill.y - .pill.height / 2 | fabs < 0.51))'
    "${metric[@]}" 'a named icon becomes the theme'"'"'s -symbolic icon, which St recolours: no mask' \
        '.four.items | map(select(.name != "Password manager") | .glyph)' 'length == 3 and all((.iconName | endswith("-symbolic")) and (.mask | not))'
    "${metric[@]}" 'a pixmap is drawn as a one-colour mask in $apex_bar_fg: no red is left of it' \
        '.four.mask' '(.colour | colour_is($t.apex_bar_fg)) and .inkPixels > 0 and .redPixels == 0'
    "${metric[@]}" 'NeedsAttention adds a $apex_indicator_dot_size accent dot, $apex_indicator_dot_top from the top and $apex_indicator_dot_right from the right of the pill' \
        '{i: .four.items, accent}' '.accent as $a | (.i | map(select(.dot != null)) | length == 1 and (.[0] | .name == "Chat"
            and (.dot | (.width | px_is($t.apex_indicator_dot_size)) and (.height | px_is($t.apex_indicator_dot_size)) and (.radius * 2 | px_is($t.apex_indicator_dot_size)) and (.colour | colour_is($a)))
            and (.dot.y - .pill.y | px_is($t.apex_indicator_dot_top)) and (.pill.x + .pill.width - .dot.x - .dot.width | px_is($t.apex_indicator_dot_right))))'
    "${metric[@]}" 'the divider is $apex_indicators_divider_width x $apex_indicators_divider_height in $apex_bar_fg at $apex_indicators_divider_opacity, $apex_indicators_divider_margin + $apex_bar_gap from the indicators and the search button' \
        '.four | {d: .divider, last: .items[-1].pill, search}' \
        '($t.apex_bar_fg | rgba) as $fg | (.d | (.width | px_is($t.apex_indicators_divider_width)) and (.height | px_is($t.apex_indicators_divider_height))
            and ((.colour | rgba) as $c | ($c[0:3] == $fg[0:3]) and ($c[3] - 255 * ($t.apex_indicators_divider_opacity | num) | fabs <= 1)))
            and (.d.x - .last.x - .last.width | px_is(($t.apex_indicators_divider_margin | px) + ($t.apex_bar_gap | px)))
            and (.search.x - .d.x - .d.width | px_is(($t.apex_indicators_divider_margin | px) + ($t.apex_bar_gap | px)))'
    "${metric[@]}" 'the search button starts the stock items, before the recording pill, the input chip, the sharing pill and the status pill' \
        '.everything.order' 'index("apex-search") as $s | $s >= 2 and .[$s - 2:$s] == ["indicators", "divider"] and .[$s + 1:] == ["screenRecording", "keyboard", "screenSharing", "quickSettings"]'
    "${metric[@]}" 'the camera and microphone in use: a $apex_privacy_height $apex_privacy group, radius $apex_radius_privacy, $apex_bar_pill_padding_privacy into the status pill' \
        '.everything | {g: .privacy, pill}' '(.g | (.height | px_is($t.apex_privacy_height)) and (.radius | px_is($t.apex_radius_privacy)) and (.colour | colour_is($t.apex_privacy)))
            and (.g.x - .pill.x | px_is($t.apex_bar_pill_padding_privacy)) and (.pill.paddingLeft | px_is($t.apex_bar_pill_padding_privacy))
            and (.g.y + .g.height / 2 - .pill.y - .pill.height / 2 | fabs < 0.51)'
    "${metric[@]}" 'its glyphs are $apex_privacy_icon_size in $apex_privacy_fg, padded $apex_privacy_padding and $apex_privacy_gap apart' \
        '.everything.privacy' '(.glyphs | length == 2 and all((.width | px_is($t.apex_privacy_icon_size)) and (.colour | colour_is($t.apex_privacy_fg))))
            and (.glyphs[0].x - .x | px_is($t.apex_privacy_padding)) and (.x + .width - .glyphs[-1].x - .glyphs[-1].width | px_is($t.apex_privacy_padding))
            and (.glyphs[1].x - .glyphs[0].x - .glyphs[0].width | px_is($t.apex_privacy_gap))'
    "${metric[@]}" 'the next status glyph follows it after $apex_privacy_margin + $apex_bar_status_gap' \
        '.everything.privacy' '.next.x - .x - .width | px_is(($t.apex_privacy_margin | px) + ($t.apex_bar_status_gap | px))'
    "${metric[@]}" 'with nothing in use the group goes and the pill starts $apex_bar_pill_padding in again' \
        '.everything.after' '.privacy == false and (.paddingLeft | px_is($t.apex_bar_pill_padding))'
    "${metric[@]}" 'a recording is a $apex_bar_pill_height $apex_recording pill, radius $apex_radius_bar_pill' \
        '.everything.recording' '(.height | px_is($t.apex_bar_pill_height)) and (.radius | px_is($t.apex_radius_bar_pill)) and (.colour | colour_is($t.apex_recording))'
    "${metric[@]}" 'its stop square is $apex_screen_stop_size in $apex_recording_fg, radius $apex_radius_screen_stop, $apex_recording_padding_start in and $apex_recording_gap before the timer' \
        '.everything.recording' '(.stop | (.width | px_is($t.apex_screen_stop_size)) and (.height | px_is($t.apex_screen_stop_size)) and (.radius | px_is($t.apex_radius_screen_stop)) and (.colour | colour_is($t.apex_recording_fg)))
            and (.stop.x - .x | px_is($t.apex_recording_padding_start)) and (.timer.x - .stop.x - .stop.width | px_is($t.apex_recording_gap))
            and (.x + .width - .timer.x - .timer.width | px_is($t.apex_recording_padding_end))'
    "${metric[@]}" 'its timer is $apex_font_recording_size at weight $apex_font_recording_weight in $apex_recording_fg, in tabular figures' \
        '.everything.recording.timer' '.text == "0:42" and (.size | px_is($t.apex_font_recording_size)) and .weight == ($t.apex_font_recording_weight | tonumber)
            and (.colour | colour_is($t.apex_recording_fg)) and (.features | test("tnum"))'
    "${metric[@]}" 'two input sources show the chip: "EN" at $apex_font_input_chip_size, weight $apex_font_input_chip_weight, tracked $apex_font_input_chip_tracking' \
        '.everything.input' '.text == "EN" and (.size | px_is($t.apex_font_input_chip_size)) and .weight == ($t.apex_font_input_chip_weight | tonumber)
            and (.tracking - ($t.apex_font_input_chip_tracking | rtrimstr("em") | num) * ($t.apex_font_input_chip_size | px) | fabs < 0.05)'
    "${metric[@]}" 'the chip is a $apex_bar_pill_height pill, radius $apex_radius_bar_pill, at least $apex_input_chip_min_width wide' \
        '.everything.input.pill' '(.height | px_is($t.apex_bar_pill_height)) and (.radius | px_is($t.apex_radius_bar_pill)) and .width >= ($t.apex_input_chip_min_width | px) - 0.01'
    "${metric[@]}" 'a share is a $apex_bar_pill_height $apex_privacy pill, radius $apex_radius_bar_pill, named "Stop screen sharing", $apex_sharing_margin + $apex_bar_gap before the status pill' \
        '.everything.sharing' '(.height | px_is($t.apex_bar_pill_height)) and (.radius | px_is($t.apex_radius_bar_pill)) and (.colour | colour_is($t.apex_privacy))
            and .name == "Stop screen sharing" and (.next.x - .x - .width | px_is(($t.apex_sharing_margin | px) + ($t.apex_bar_gap | px)))'
    "${metric[@]}" 'its glyph is $apex_sharing_icon_size in $apex_privacy_fg, $apex_sharing_padding_start in and $apex_sharing_gap before a $apex_screen_stop_size stop square, $apex_sharing_padding_end from the end' \
        '.everything.sharing' '(.glyph | (.width | px_is($t.apex_sharing_icon_size)) and (.colour | colour_is($t.apex_privacy_fg))) and (.glyph.x - .x | px_is($t.apex_sharing_padding_start))
            and (.stop.x - .glyph.x - .glyph.width | px_is($t.apex_sharing_gap)) and (.stop | (.width | px_is($t.apex_screen_stop_size)) and (.radius | px_is($t.apex_radius_screen_stop)))
            and (.x + .width - .stop.x - .stop.width | px_is($t.apex_sharing_padding_end))'
    "${metric[@]}" 'a secondary click opens its menu: solid, radius $apex_radius_menu, at least $apex_indicator_menu_width wide' \
        '.menu' '.open and (.content.radius | px_is($t.apex_radius_menu)) and (.content.width >= ($t.apex_indicator_menu_width | px) - 0.01)'
    "${metric[@]}" 'its first row is the item'"'"'s title, $apex_indicator_menu_header_height high, in $apex_fg_dim' \
        '.menu.rows[0]' '.header and .label == "Chat" and (.height | px_is($t.apex_indicator_menu_header_height)) and (.colour | colour_is($t.apex_fg_dim))'
    "${metric[@]}" 'its rows are $apex_menu_row_height high' \
        '.menu.rows[1:] | map(select(.kind != "PopupSeparatorMenuItem"))' 'length == 5 and all(.height | px_is($t.apex_menu_row_height))'
    "${metric[@]}" 'toggles are $apex_indicator_switch_width x $apex_indicator_switch_height switches, in the state the app gave' \
        '.menu.rows | map(select(.switch) | {label, switch})' \
        'map(.label) == ["Do Not Disturb", "Start at Login"] and (map(.switch.checked) == [false, true])
            and all(.switch | (.width | px_is($t.apex_indicator_switch_width)) and (.height | px_is($t.apex_indicator_switch_height)))'
    "${metric[@]}" 'a shortcut is dimmed on the right: $apex_fg_dim' \
        '.menu.rows | map(select(.shortcut)) | map(.shortcut)' 'length == 1 and .[0].text == "Ctrl+Shift+C" and (.[0].colour | colour_is($t.apex_fg_dim))'
    "${metric[@]}" 'opening the menu, a row and closing it send their events, and the menu closes' \
        '{log, closed: .menu.closed}' '.closed and (.log | index("Chat Event 0 opened") != null and index("Chat Event 5 clicked") != null and index("Chat Event 0 closed") != null)'
    "${metric[@]}" 'a primary click activates the item' \
        '.log' 'any(startswith("File sync Activate "))'
    "${metric[@]}" 'a fifth item: three show and "+2", a $apex_bar_pill_height pill' \
        '.five | {names: [.items[].name], overflow}' \
        '.names == ["File sync", "Chat", "Game launcher"] and .overflow.text == "+2" and (.overflow.pill | (.height | px_is($t.apex_bar_pill_height)) and (.radius | px_is($t.apex_radius_bar_pill)))'
    "${metric[@]}" 'it lists the other two: glyph, title and chevron, rows $apex_menu_row_height, at least $apex_indicators_overflow_menu_width wide' \
        '.overflowMenu' '(.rows | map(.label) == ["Password manager", "Media player"] and all((.height | px_is($t.apex_menu_row_height)) and (.glyph | px_is($t.apex_bar_icon_size)) and .chevron == "go-next-symbolic"))
            and (.content.width >= ($t.apex_indicators_overflow_menu_width | px) - 0.01)'
    "${metric[@]}" 'when the apps quit, the indicators and the divider go' \
        '.gone' '.visible == false and .divider == null'
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
shadow_layers() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label shadows" "$scenes" "$tokens")
    local layer='length == 1 and (.[0] | .shown and .sameBox and (.boxShadow | .inset == false and .x == 0
        and (.y | px_is($t.apex_shadow_2_y)) and (.blur | px_is($t.apex_shadow_2_blur)) and (.color | colour_is($t.apex_shadow_2))))'
    "${metric[@]}" 'Quick Settings draws its second layer, 0 $apex_shadow_2_y $apex_shadow_2_blur $apex_shadow_2, on its own box' \
        '.surfaces.shadowLayers.quickSettings' "$layer and .[0].radius == (\$t.apex_radius_quick_settings | px)"
    "${metric[@]}" 'the calendar draws its second layer, 0 $apex_shadow_2_y $apex_shadow_2_blur $apex_shadow_2, on its own box' \
        '.surfaces.shadowLayers.dateMenu' "$layer"
    "${metric[@]}" "a dialog's second layer sits beside its box, above the lightbox under the dialog" \
        '.surfaces.shadowLayers.dialog' "$layer and .[0].besideBox"
    expect "$label shadows" "$scenes" '.surfaces.idleRepaints | .withShadows <= .withoutShadows' \
        "an idle desktop repaints no more with the shadow layers than with shadows in disabled-features"
}

# shellcheck disable=SC2016 # jq programs
quick_settings_layer() {
    local label=$1 log=$2 mode=$3 scenes q=.surfaces.quickSettingsLayer variant=light
    [[ $label == *dark* ]] && variant=dark
    scenes=$(report_of "$log" APEXG2-SCENES)
    local order='([.order[].title]) as $t | ($t | index("VPN")) as $vpn | ($t | index("Airplane Mode")) as $airplane'
    if [[ $mode == apex ]]; then
        expect "$label Quick Settings" "$scenes" "$q | $order | \$vpn != null and \$airplane != null and \$vpn == \$airplane + 1" \
            "the quick-settings feature puts VPN right after Airplane Mode (DESIGN's order)"
        expect "$label Quick Settings" "$scenes" "$q.power | .visible and .lit and (.checked | not) and .subtitle == \"Balanced\"" \
            "Power Mode at Balanced is lit through apex-lit, its checked state stock (unchecked)"
        expect "$label Quick Settings" "$scenes" "$q.pillShowsPower == false" "the power-profile indicator stays out of the status pill"
        expect "$label Quick Settings" "$scenes" "$q.dndSubtitle == \"Off\"" "a toggle without a subtitle of its own says Off"
        expect "$label Quick Settings" "$scenes" "$q.switched | .checked and .lit and .subtitle != \"Balanced\"" \
            "a click switches Power Mode from Balanced to the last profile, still lit"
        expect "$label Quick Settings" "$scenes" "$q.back | (.checked | not) and .lit and .subtitle == \"Balanced\"" \
            "and a second click back to Balanced"
        expect "$label Quick Settings" "$scenes" "$q.wifiMenu.subtitle | .column == 3 and .row == 0 and .xAlign == .end" \
            "the Wi-Fi menu's header subtitle ends the title's row, at its end (board 17)"
        expect "$label Quick Settings" "$scenes" "$q.wifiMenu.rows | length > 1 and any(.active) and all(.checked == .active)" \
            "the active network's row, and only it, is :checked"
        top_bar_metric "$label Quick Settings" "$scenes" "$(tokens_for "$variant")" \
            'a secure network'"'"'s lock follows its name, $apex_quick_menu_lock_size in $apex_fg at $apex_quick_menu_lock_opacity' \
            "$q.wifiMenu.rows" '[.[] | select(.secure)] | length > 0 and all(.lockAfterName and (.lockSize | px_is($t.apex_quick_menu_lock_size))
                and (.lockColor | colour_is(($t.apex_fg | rgba) as $f | "rgba(\($f[0]), \($f[1]), \($f[2]), \($t.apex_quick_menu_lock_opacity))")))'
    else
        expect "$label Quick Settings" "$scenes" "$q | $order | \$vpn != null and \$airplane != null and \$vpn < \$airplane" \
            "stock's order: VPN with the network toggles, before Airplane Mode"
        expect "$label Quick Settings" "$scenes" "($q.power | .visible and (.lit | not) and (.checked | not)) and $q.dndSubtitle == null" \
            "stock: Power Mode unlit at Balanced, no On/Off subtitles"
        expect "$label Quick Settings" "$scenes" "$q.switched.checked and ($q.back.checked | not)" \
            "stock: a click switches Power Mode to the last profile and back"
        expect "$label Quick Settings" "$scenes" "$q.wifiMenu | (.subtitle | .column == 1 and .row == 1) and (.rows | length > 1 and all((.checked | not) and (.lockAfterName | not)))" \
            "stock: the Wi-Fi menu's subtitle under its title, no row :checked, each lock by its signal icon"
    fi
}

# shellcheck disable=SC2016 # jq programs
notifications_layer() {
    local label=$1 log=$2 mode=$3 scenes q=.surfaces.notificationsLayer
    scenes=$(report_of "$log" APEXG2-SCENES)
    local flat='[.messages as $m | range(1; $m | length) | $m[.].y >= $m[. - 1].y + $m[. - 1].height] | all'
    if [[ $mode == apex ]]; then
        expect "$label notifications" "$scenes" "$q | (.messages | length == 3) and (.header | not) and ($flat)" \
            "the notifications feature lays an app's three notifications out flat, one under another, without a group header"
        expect "$label notifications" "$scenes" "$q | (.cardHeader.sourceIcon | not) and (.cardHeader.line | startswith(\"G2 Chat · \"))
            and .icon == \"mail-unread-symbolic\"" \
            "a card's header reads app · time without the source glyph, and a card without an icon shows the app's"
        expect "$label notifications" "$scenes" "$q | .dnd.label == \"Do Not Disturb\" and .dnd.x < .clear.x
            and (.clear.x + .clear.width) >= (.footer.x + .footer.width - 6)" \
            "the footer: Do Not Disturb on the left, Clear on the right"
        expect "$label notifications" "$scenes" "$q.dndClick | .showBanners == false and .checked" \
            "a click on Do Not Disturb turns banners off and checks it"
        expect "$label notifications" "$scenes" "$q.empty | .placeholder and .clearVisible and (.clearReactive | not)" \
            "with nothing to clear, Clear stays shown, insensitive"
        expect "$label notifications" "$scenes" "$q.calendar | .label.x < .back.x and .back.x < .forward.x
            and (.dots | length) == .days and all(.dots[]; .width == 4 and .height == 4)" \
            "the calendar: the month on the left, both chevrons on the right, a 4 px dot laid out under every day"
    else
        expect "$label notifications" "$scenes" "$q | (.messages | length == 3) and ($flat | not) and .dnd == null
            and .cardHeader.sourceIcon and .icon == null" \
            "stock: an app's notifications stack, each header keeps its glyph, and the footer has Clear alone"
        expect "$label notifications" "$scenes" "$q.empty | .placeholder and (.clearVisible | not)" \
            "stock: with nothing to clear, Clear hides"
        expect "$label notifications" "$scenes" "$q.calendar | .back.x < .label.x and .label.x < .forward.x and (.dots | length) == 0" \
            "stock: the month between its chevrons, no dot widgets"
    fi
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
    "${metric[@]}" 'its rows hover in $apex_quick_menu_row_hover, lighter than popup menus' \
        "$q.wifiMenu" '.rowHover.background | colour_is($t.apex_quick_menu_row_hover)'
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
            and (.endSession.box.width | px_is($t.apex_end_session_dialog_width))'
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
    "${metric[@]}" 'the end-session dialog has $apex_end_session_gap between its parts, its title tracked $apex_dialog_title_tracking, its countdown in tabular figures' \
        "$d.endSession" '(.box.spacing | px_is($t.apex_end_session_gap)) and (.contentSpacing | px_is($t.apex_end_session_gap))
            and (.title.tracking - ($t.apex_dialog_title_tracking | px) | fabs < 0.05) and (.description.font.features | test("tnum"))'
    "${metric[@]}" 'above its title, stock'"'"'s system-shutdown-symbolic at $apex_end_session_icon_glyph_size in a $apex_end_session_icon_size circle of $apex_button' \
        "$d.endSession.icon" '.iconName == "system-shutdown-symbolic" and .above and (.glyph | px_is($t.apex_end_session_icon_glyph_size))
            and (.width | px_is($t.apex_end_session_icon_size)) and (.height | px_is($t.apex_end_session_icon_size))
            and (.radius * 2 | px_is($t.apex_end_session_icon_size)) and (.background | colour_is($t.apex_button))'
    "${metric[@]}" 'its row is Cancel, Restart, Power Off, $apex_end_session_button_gap apart, sharing it $apex_end_session_cancel_share : $apex_end_session_restart_share : $apex_end_session_confirm_share' \
        "$d.endSession" '((($t.apex_end_session_dialog_width | px) - 2 * ($t.apex_dialog_padding | px) - 2 * ($t.apex_end_session_button_gap | px))
            / (($t.apex_end_session_cancel_share | num) + ($t.apex_end_session_restart_share | num) + ($t.apex_end_session_confirm_share | num))) as $share
            | (.buttons | map(.text)) == ["Cancel", "Restart", "Power Off"] and (.rowSpacing | px_is($t.apex_end_session_button_gap))
            and ([.buttons[].width] | [.[0] / ($t.apex_end_session_cancel_share | num), .[1] / ($t.apex_end_session_restart_share | num), .[2] / ($t.apex_end_session_confirm_share | num)]
                | all(. - $share | fabs <= 1))'
    "${metric[@]}" 'Cancel and Restart are $apex_button ($apex_button_hover hovered); Power Off, which ends the session, $apex_destructive ($apex_destructive_hover hovered) with $apex_destructive_fg' \
        "$d.endSession.buttons" '(.[:-1] | all((.background | colour_is($t.apex_button)) and (.hover.background | colour_is($t.apex_button_hover))))
            and (.[-1] | (.background | colour_is($t.apex_destructive)) and (.foreground | colour_is($t.apex_destructive_fg)) and (.hover.background | colour_is($t.apex_destructive_hover)))'
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

# The overview feature's values are the layer's, not tokens; only the empty label is styled.
# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
overview_layer() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local o=.surfaces.overviewLayer
    expect_report "$label" "$log" "$o.titleVisible == true" \
        "overview: window titles always shown, not only on hover" APEXG2-SCENES
    expect_report "$label" "$log" "$o | .thumbnails.maxScale == $OVERVIEW_THUMBNAIL_SCALE and .thumbnailsThreshold == $OVERVIEW_THUMBNAILS_THRESHOLD" \
        "overview: workspace thumbnails at scale $OVERVIEW_THUMBNAIL_SCALE, shown from $((OVERVIEW_THUMBNAILS_THRESHOLD + 1)) workspaces" APEXG2-SCENES
    expect_report "$label" "$log" "{f: $o.thumbnails.first, w: .topBar.panel.width, h: .scenes.overview.workArea.height}
        | (.f.width - .w * $OVERVIEW_THUMBNAIL_SCALE | fabs <= 1) and (.f.height - .h * $OVERVIEW_THUMBNAIL_SCALE | fabs <= 1)" \
        "overview: and drawn at that scale of the work area (117 x 70 on 1440 x 900)" APEXG2-SCENES
    expect_report "$label" "$log" "$o.workspace | .background == false and .empty.visible and .empty.text == \"$EMPTY_WORKSPACE_TEXT\"
        and (.x + .width / 2 - .empty.x - .empty.width / 2 | fabs <= 1) and (.y + .height / 2 - .empty.y - .empty.height / 2 | fabs <= 1)" \
        "overview: no workspace background card, and \"$EMPTY_WORKSPACE_TEXT\" centred on the empty workspace" APEXG2-SCENES
    top_bar_metric "$label overview" "$scenes" "$tokens" 'the empty-workspace label is $apex_font_workspace_empty_size $apex_font_heading_weight in $apex_fg_dim' \
        "$o.workspace.empty" '(.font.size | px_is($t.apex_font_workspace_empty_size)) and .font.weight == ($t.apex_font_heading_weight | tonumber) and (.foreground | colour_is($t.apex_fg_dim))'
    expect_report "$label" "$log" ".surfaces.appGrid.grid == {columns: $LAUNCHER_COLUMNS, rows: $LAUNCHER_ROWS, iconSize: $LAUNCHER_ICON_SIZE}" \
        "launcher: $LAUNCHER_COLUMNS columns of $LAUNCHER_ICON_SIZE px icons, $LAUNCHER_ROWS rows a page" APEXG2-SCENES
    top_bar_metric "$label overview" "$scenes" "$tokens" "launcher: no workspace strip; the grid starts at the work area + \$apex_search_top + \$apex_search_height + $STOCK_SEARCH_MARGIN_BOTTOM + twice the spacing, board 36's $LAUNCHER_GRID_TOP px" \
        "{g: .surfaces.appGrid, wa: .scenes.overview.workArea}" "(.wa.y + (\$t.apex_search_top | px) + (\$t.apex_search_height | px) + $STOCK_SEARCH_MARGIN_BOTTOM
            + 2 * (.wa.height * $OVERVIEW_SPACING_RATIO | round)) as \$top | .g.strip == 0 and (.g.box.y - \$top | fabs) <= 1 and \$top == $LAUNCHER_GRID_TOP"
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
tile_preview() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label tile preview" "$scenes" "$tokens")
    local tp=.surfaces.tilePreview
    local tinted='def tinted($a; $opacity): rgba as $c | ($a | rgba) as $w | ($c[0:3] == $w[0:3]) and ($c[3] - ($opacity | num) * 255 | fabs <= 1);'

    "${metric[@]}" 'the preview over the left half fills the tile mutter gives it, behind a clear $apex_tile_preview_inset border, so it shows $apex_tile_preview_inset inside the tile' \
        "$tp" '.tile as $tile | .preview | (.styleClass | split(" ") | index("tile-preview-left") != null)
            and .x == $tile.x and .y == $tile.y and .width == $tile.width and .height == $tile.height
            and (.border | [.top, .right, .bottom, .left] | all(px_is($t.apex_tile_preview_inset))) and (.borderColor | rgba | .[3] == 0)'
    "${metric[@]}" 'it is rounded $apex_radius_tile_preview inside that border, filled with the accent at $apex_tile_preview_fill_opacity and ringed $apex_tile_preview_ring in the accent at $apex_tile_preview_ring_opacity' \
        "{p: $tp.preview, accent: .topBar.accent}" "$tinted"' .accent as $a | .p | (.radius - .border.top | px_is($t.apex_radius_tile_preview))
            and (.background | tinted($a; $t.apex_tile_preview_fill_opacity))
            and (.boxShadow | .inset and (.spread | px_is($t.apex_tile_preview_ring)) and .blur == 0 and (.color | tinted($a; $t.apex_tile_preview_ring_opacity)))'
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
screenshot_ui() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label screenshot UI" "$scenes" "$tokens")
    local s=.surfaces.screenshot

    "${metric[@]}" 'the panel is $apex_screenshot_width of $apex_panel ringed in $apex_panel_border with the shadow, radius $apex_radius_screenshot, inset $apex_screenshot_padding with a heading row of $apex_screenshot_close_size, rows $apex_screenshot_gap apart, $apex_screenshot_bottom above the bottom edge' \
        "$s" '.monitorHeight as $h | .panel | (.width | px_is($t.apex_screenshot_width)) and (.background | colour_is($t.apex_panel))
            and (.borderColor | colour_is($t.apex_panel_border)) and (.border.top | px_is($t.apex_surface_border)) and (.radius | px_is($t.apex_radius_screenshot))
            and (.boxShadow | .y == ($t.apex_shadow_y | px) and .blur == ($t.apex_shadow_blur | px) and (.color | colour_is($t.apex_shadow)))
            and (.padding.left + .border.left | px_is($t.apex_screenshot_padding))
            and (.padding.top + .border.top | px_is(($t.apex_screenshot_padding | px) + ($t.apex_screenshot_close_size | px) + ($t.apex_screenshot_gap | px) | tostring + "px"))
            and (.spacing | px_is($t.apex_screenshot_gap)) and ($h - .y - .height | px_is($t.apex_screenshot_bottom))'
    "${metric[@]}" 'the close button is a $apex_screenshot_close_size $apex_button circle in the heading row, $apex_screenshot_padding from the top and $apex_screenshot_padding + $apex_screenshot_close_inset from the side' \
        "$s" '.panel as $p | .close | (.width | px_is($t.apex_screenshot_close_size)) and (.height | px_is($t.apex_screenshot_close_size)) and .radius * 2 >= .width
            and (.background | colour_is($t.apex_button)) and (.foreground | colour_is($t.apex_fg)) and .boxShadow == null
            and (.y - $p.y | px_is($t.apex_screenshot_padding))
            and ($p.x + $p.width - .x - .width | px_is(($t.apex_screenshot_padding | px) + ($t.apex_screenshot_close_inset | px) | tostring + "px"))'
    "${metric[@]}" 'the area buttons are $apex_screenshot_type_height high, radius $apex_radius_screenshot_type, in $apex_button ($apex_button_hover checked), a $apex_screenshot_type_icon_size glyph $apex_screenshot_type_label_gap above a $apex_font_screenshot_type_size $apex_font_label_weight name; with no window, Window is $apex_fg_faint' \
        "$s" '(.types | (map(.height | px_is($t.apex_screenshot_type_height)) | all) and (map(.radius | px_is($t.apex_radius_screenshot_type)) | all)
                and (.[0].checked and (.[0].background | colour_is($t.apex_button_hover))) and (.[1].background | colour_is($t.apex_button))
                and (.[2].background | colour_is($t.apex_button)) and (.[2].foreground | colour_is($t.apex_fg_faint)))
            and (.checkedType.background | colour_is($t.apex_button_hover))
            and (.typeContent | (.icon.height | px_is($t.apex_screenshot_type_icon_size)) and (.spacing | px_is($t.apex_screenshot_type_label_gap))
                and (.labelFont.size | px_is($t.apex_font_screenshot_type_size)) and .labelFont.weight == ($t.apex_font_label_weight | tonumber))'
    "${metric[@]}" 'the pointer toggle is a $apex_screenshot_pointer_size $apex_button circle, the raw accent when on' \
        "{p: $s.pointer, accent: .topBar.accent}" '.accent as $a | .p | (.width | px_is($t.apex_screenshot_pointer_size)) and (.height | px_is($t.apex_screenshot_pointer_size))
            and .radius * 2 >= .width and (.background | colour_is($t.apex_button)) and (.checked.background | colour_is($a))'
    "${metric[@]}" 'the capture button is $apex_screenshot_capture_size, a $apex_screenshot_capture_ring $apex_fg ring around a $apex_fg dot $apex_screenshot_capture_gap inside it; recording, a $apex_screenshot_record_dot $apex_screenshot_record square, radius $apex_radius_screenshot_record_dot' \
        "$s.capture" '(.width | px_is($t.apex_screenshot_capture_size)) and (.height | px_is($t.apex_screenshot_capture_size))
            and (.border.top | px_is($t.apex_screenshot_capture_ring)) and (.borderColor | colour_is($t.apex_fg)) and (.padding.top | px_is($t.apex_screenshot_capture_gap))
            and (.circle | (.background | colour_is($t.apex_fg)) and .radius * 2 >= .width
                and (.width | px_is(($t.apex_screenshot_capture_size | px) - 2 * (($t.apex_screenshot_capture_ring | px) + ($t.apex_screenshot_capture_gap | px)) | tostring + "px")))
            and (.circle.width - 2 * .cast.margin | px_is($t.apex_screenshot_record_dot)) and (.cast.radius | px_is($t.apex_radius_screenshot_record_dot))
            and (.cast.background | colour_is($t.apex_screenshot_record))'
    "${metric[@]}" 'the screenshot and screencast switch is $apex_button inset $apex_screenshot_switch_padding; its buttons $apex_screenshot_switch_button_width x $apex_screenshot_switch_button_height, the checked one $apex_panel_solid with a $apex_screenshot_switch_shadow shadow' \
        "$s" '(.switcher | (.padding.top | px_is($t.apex_screenshot_switch_padding)) and (.background | colour_is($t.apex_button))
                and (.radius | px_is(($t.apex_screenshot_switch_button_height | px) / 2 + ($t.apex_screenshot_switch_padding | px) | tostring + "px")))
            and (.shot | .checked and (.width | px_is($t.apex_screenshot_switch_button_width)) and (.height | px_is($t.apex_screenshot_switch_button_height))
                and (.background | colour_is($t.apex_panel_solid)) and (.foreground | colour_is($t.apex_fg))
                and (.boxShadow | .y == ($t.apex_screenshot_switch_shadow_y | px) and .blur == ($t.apex_screenshot_switch_shadow_blur | px) and (.color | colour_is($t.apex_screenshot_switch_shadow))))'
    "${metric[@]}" 'the selection is shaded $apex_screenshot_shade, outlined $apex_screenshot_selection_border in $apex_screenshot_selection, with $apex_screenshot_handle_size white handles shadowed $apex_screenshot_handle_shadow' \
        "$s" '(.shade.background | colour_is($t.apex_screenshot_shade))
            and (.selection | (.border.top | px_is($t.apex_screenshot_selection_border)) and (.borderColor | colour_is($t.apex_screenshot_selection)))
            and (.handle | (.width | px_is($t.apex_screenshot_handle_size)) and (.height | px_is($t.apex_screenshot_handle_size)) and .radius * 2 >= .width
                and (.background | colour_is("#ffffff"))
                and (.boxShadow | .y == ($t.apex_screenshot_handle_shadow_y | px) and .blur == ($t.apex_screenshot_handle_shadow_blur | px) and (.color | colour_is($t.apex_screenshot_handle_shadow))))'
    "${metric[@]}" 'the chosen screen is ringed $apex_screenshot_frame in the raw accent over $apex_screenshot_screen_tint; the window selector shades $apex_screenshot_shade and rings the chosen window $apex_screenshot_frame in the accent, radius $apex_radius_screenshot_window' \
        "{s: $s, accent: .topBar.accent}" '.accent as $a | .s | (.screen | .checked and (.border.top | px_is($t.apex_screenshot_frame)) and (.borderColor | colour_is($a))
                and (.background | colour_is($t.apex_screenshot_screen_tint)))
            and (.windowSelector.background | colour_is($t.apex_screenshot_shade))
            and (.windowFrame | (.border.top | px_is($t.apex_screenshot_frame)) and (.borderColor | colour_is($a)) and (.radius | px_is($t.apex_radius_screenshot_window)))'
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

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
spotlight_style() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant" | jq --slurpfile tiles "$TILES_FILE" '. + {settings_tiles: $tiles[0]}')
    local -a metric=(top_bar_metric "$label Spotlight" "$scenes" "$tokens")
    local s=.surfaces.spotlight
    local surface='(.border | [.top, .right, .bottom, .left] | all(px_is($t.apex_surface_border))) and (.borderColor | colour_is($t.apex_panel_border))
        and (.boxShadow | .inset == false and .x == 0 and (.y | px_is($t.apex_shadow_y)) and (.blur | px_is($t.apex_shadow_blur)) and (.color | colour_is($t.apex_shadow)))'
    local selected='(.background | rgba) as $got | ($a | rgba) as $want | ([$got[0:3], $want[0:3]] | transpose | all(.[0] - .[1] | fabs <= 1))
        and ($got[3] - 255 * ($t.apex_selection_opacity | num) | fabs <= 1)'
    local tracking='(.tracking - ($t.apex_spotlight_header_tracking | rtrimstr("em") | num) * ($t.apex_font_spotlight_header_size | px) | fabs < 0.05)'

    "${metric[@]}" 'the panel is $apex_spotlight_width wide, $apex_spotlight_top below the monitor'"'"'s top edge, radius $apex_radius_spotlight, tinted $apex_panel with $apex_fg text' \
        "$s.panel" '(.width | px_is($t.apex_spotlight_width)) and (.top | px_is($t.apex_spotlight_top)) and (.radius | px_is($t.apex_radius_spotlight))
            and (.background | colour_is($t.apex_panel)) and (.foreground | colour_is($t.apex_fg))'
    "${metric[@]}" 'its ring is a $apex_surface_border border in $apex_panel_border, its shadow 0 $apex_shadow_y $apex_shadow_blur $apex_shadow' \
        "$s.panel" "$surface"
    "${metric[@]}" 'the field is $apex_spotlight_field_height high, inset $apex_spotlight_field_padding, $apex_spotlight_field_gap between its parts; its glyph $apex_spotlight_glyph_size in $apex_fg_dim' \
        "$s" '(.field | (.height | px_is($t.apex_spotlight_field_height)) and (.padding.left | px_is($t.apex_spotlight_field_padding))
            and (.padding.right | px_is($t.apex_spotlight_field_padding)) and (.spacing | px_is($t.apex_spotlight_field_gap)))
            and (.glyph | (.size | px_is($t.apex_spotlight_glyph_size)) and (.foreground | colour_is($t.apex_fg_dim)))'
    "${metric[@]}" 'its text is $apex_font_spotlight_field_size at $apex_font_spotlight_field_weight in $apex_fg, unframed and unfilled; its hint $apex_fg_hint' \
        "$s.entry" '(.font.size | px_is($t.apex_font_spotlight_field_size)) and .font.weight == ($t.apex_font_spotlight_field_weight | tonumber)
            and (.foreground | colour_is($t.apex_fg)) and (.background | rgba | .[3] == 0) and .border.top == 0 and (.hint | colour_is($t.apex_fg_hint))'
    "${metric[@]}" 'under a $apex_surface_border line in $apex_border, the results are inset $apex_spotlight_results_padding_top at the top and $apex_spotlight_results_padding elsewhere' \
        "$s.results" '(.border.top | px_is($t.apex_surface_border)) and (.borderColor | colour_is($t.apex_border)) and (.padding.top | px_is($t.apex_spotlight_results_padding_top))
            and ([.padding.right, .padding.bottom, .padding.left] | all(px_is($t.apex_spotlight_results_padding)))'
    "${metric[@]}" 'section headers, in board order, are $apex_spotlight_header_height high with their text $apex_spotlight_header_padding_bottom above the bottom and $apex_spotlight_header_padding in, $apex_font_spotlight_header_size $apex_font_heading_weight in $apex_fg_dim, tracked $apex_spotlight_header_tracking' \
        "$s" ".sections == [\"APPLICATIONS\", \"SETTINGS\", \"FILES\"] and (.headers | all((.height | px_is(\$t.apex_spotlight_header_height))
            and (.padding.bottom | px_is(\$t.apex_spotlight_header_padding_bottom)) and (.padding.left | px_is(\$t.apex_spotlight_header_padding))
            and (.font.size | px_is(\$t.apex_font_spotlight_header_size)) and .font.weight == (\$t.apex_font_heading_weight | tonumber)
            and (.foreground | colour_is(\$t.apex_fg_dim)) and $tracking))"
    "${metric[@]}" 'rows are $apex_spotlight_row_height high, radius $apex_radius_spotlight_row, inset $apex_spotlight_row_padding, $apex_spotlight_row_gap between icon, text and action; icons $apex_spotlight_icon_size' \
        "$s.rows" 'length == 9 and all((.height | px_is($t.apex_spotlight_row_height)) and (.radius | px_is($t.apex_radius_spotlight_row))
            and (.padding.left | px_is($t.apex_spotlight_row_padding)) and (.padding.right | px_is($t.apex_spotlight_row_padding)) and (.spacing | px_is($t.apex_spotlight_row_gap))
            and (.icon.width | px_is($t.apex_spotlight_icon_size)) and (.icon.height | px_is($t.apex_spotlight_icon_size)))'
    "${metric[@]}" 'the first row is selected, filled with the accent at $apex_selection_opacity; the others are unfilled' \
        "{s: $s, accent: .topBar.accent}" ".accent as \$a | .s.selected == [true, false, false, false, false, false, false, false, false]
            and (.s.rows[0] | $selected) and (.s.rows[1:] | all(.background | rgba | .[3] == 0))"
    "${metric[@]}" 'Settings rows sit on $apex_spotlight_icon_size tiles, radius $apex_radius_spotlight_tile, with $apex_spotlight_tile_glyph_size glyphs: About in System'"'"'s colour and Privacy'"'"'s from settings-tiles.json in $apex_spotlight_tile_fg, a panel without one neutral $apex_button in $apex_fg' \
        "[$s.rows[2:5][] | .tile]" 'length == 3 and all(. != null and (.width | px_is($t.apex_spotlight_icon_size)) and (.radius | px_is($t.apex_radius_spotlight_tile)) and (.glyph | px_is($t.apex_spotlight_tile_glyph_size)))
            and (.[0] | (.background | colour_is($t.settings_tiles.system)) and (.foreground | colour_is($t.apex_spotlight_tile_fg)))
            and (.[1] | (.background | colour_is($t.settings_tiles.privacy)) and (.foreground | colour_is($t.apex_spotlight_tile_fg)))
            and (.[2] | (.background | colour_is($t.apex_button)) and (.foreground | colour_is($t.apex_fg)))'
    "${metric[@]}" 'a title is $apex_font_spotlight_title_size $apex_font_label_weight in $apex_fg, $apex_spotlight_text_gap over its subtitle, $apex_font_spotlight_subtitle_size in $apex_fg_dim' \
        "$s.rows" 'all((.title.font.size | px_is($t.apex_font_spotlight_title_size)) and .title.font.weight == ($t.apex_font_label_weight | tonumber) and (.title.foreground | colour_is($t.apex_fg))
            and (.text.spacing | px_is($t.apex_spotlight_text_gap)) and (.subtitle.font.size | px_is($t.apex_font_spotlight_subtitle_size)) and (.subtitle.foreground | colour_is($t.apex_fg_dim)))'
    "${metric[@]}" 'the selected row ends in "Open", $apex_font_spotlight_action_size $apex_font_label_weight in $apex_fg_dim, $apex_spotlight_action_gap before an Enter chip $apex_spotlight_chip_height high, radius $apex_radius_spotlight_chip, in $apex_button at $apex_font_spotlight_chip_size $apex_font_heading_weight' \
        "$s.rows[0].action" '(.verb.text == "Open") and (.font.size | px_is($t.apex_font_spotlight_action_size)) and .font.weight == ($t.apex_font_label_weight | tonumber)
            and (.foreground | colour_is($t.apex_fg_dim)) and (.spacing | px_is($t.apex_spotlight_action_gap))
            and (.chip | (.height | px_is($t.apex_spotlight_chip_height)) and (.radius | px_is($t.apex_radius_spotlight_chip)) and (.background | colour_is($t.apex_button))
                and (.label.text == "Enter") and (.label.font.size | px_is($t.apex_font_spotlight_chip_size)) and .label.font.weight == ($t.apex_font_heading_weight | tonumber))'
    "${metric[@]}" 'a sum shows its result, $apex_font_spotlight_result_size $apex_font_heading_weight in tabular figures over the sum, then Calculator as the first application' \
        "$s.calculator" '.sections == ["CALCULATOR", "APPLICATIONS"] and (.row | .title.text == "1920" and .subtitle.text == "2880 / 1.5" and .action.verb.text == "Copy"
            and (.title.font.size | px_is($t.apex_font_spotlight_result_size)) and .title.font.weight == ($t.apex_font_heading_weight | tonumber) and (.title.font.features | test("tnum")))'
    "${metric[@]}" 'an empty query shows only the field; a query with no results says so in $apex_fg_dim, $apex_spotlight_empty_height high under a $apex_border line' \
        "$s" '.fieldOnly and (.empty | (.label.text | startswith("No results for")) and (.height | px_is($t.apex_spotlight_empty_height)) and (.border.top | px_is($t.apex_surface_border))
            and (.borderColor | colour_is($t.apex_border)) and (.foreground | colour_is($t.apex_fg_dim)))'
    "${metric[@]}" 'Enter on the result closes Spotlight for a toast $apex_toast_height high, radius $apex_radius_toast, tinted $apex_panel, $apex_toast_bottom above the screen'"'"'s bottom edge' \
        "$s" '.closedOnCopy and (.toast.box | (.height | px_is($t.apex_toast_height)) and (.radius | px_is($t.apex_radius_toast)) and (.background | colour_is($t.apex_panel)))
            and (.toast.bottomGap | px_is($t.apex_toast_bottom))'
    "${metric[@]}" 'the toast'"'"'s ring is a $apex_surface_border border in $apex_panel_border, its shadow 0 $apex_shadow_y $apex_shadow_blur $apex_shadow' \
        "$s.toast.box" "$surface"
    "${metric[@]}" 'it is inset $apex_toast_padding_start and $apex_toast_padding_end, $apex_toast_gap between a $apex_toast_check_size accent circle with a $apex_toast_check_icon_size check and "Copied 1920", $apex_font_size $apex_font_label_weight' \
        "{t: $s.toast, accent: .topBar.accent}" '.accent as $a | .t | (.box | (.padding.left + .border.left | px_is($t.apex_toast_padding_start)) and (.padding.right + .border.right | px_is($t.apex_toast_padding_end))
            and (.spacing | px_is($t.apex_toast_gap)) and (.font.size | px_is($t.apex_font_size)) and .font.weight == ($t.apex_font_label_weight | tonumber))
            and (.check | (.width | px_is($t.apex_toast_check_size)) and (.height | px_is($t.apex_toast_check_size)) and .radius >= ($t.apex_toast_check_size | px) / 2
                and (.background | colour_is($a)) and (.icon | px_is($t.apex_toast_check_icon_size)))
            and .label.text == "Copied 1920"'
    "${metric[@]}" 'typing in the overview opens Spotlight with the typed text and clears the overview'"'"'s own search (patch 0013)' \
        '.surfaces.overviewSearch' '.opened and .text == "disk" and .overviewText == ""'
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
launcher_search() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label launcher search" "$scenes" "$tokens")
    local l=.surfaces.launcher

    "${metric[@]}" 'in the app grid the overview'"'"'s pill is the launcher'"'"'s: $apex_launcher_search_width wide, "Search apps"' \
        "$l.pill" '(.width | px_is($t.apex_launcher_search_width)) and .hint == "Search apps"'
    "${metric[@]}" 'typing filters the grid in place, in the grid'"'"'s own box, to the matching apps, Files among them, the first selected; Spotlight stays closed' \
        "$l.found" '.gridHidden and .results == .appDisplay and (.names | index("Files") != null) and .firstSelected and (.spotlightOpen | not)'
    "${metric[@]}" 'no match says, $apex_launcher_empty_top down the grid'"'"'s box, "No Results" at $apex_font_launcher_empty_title_size $apex_font_heading_weight in $apex_fg over the hint at $apex_font_launcher_empty_hint_size in $apex_fg_dim, $apex_launcher_empty_gap apart' \
        "$l.empty" '(.top | px_is(0)) and (.padding.top | px_is($t.apex_launcher_empty_top)) and (.spacing | px_is($t.apex_launcher_empty_gap)) and (.title | .text == "No Results" and (.font.size | px_is($t.apex_font_launcher_empty_title_size))
            and .font.weight == ($t.apex_font_heading_weight | tonumber) and (.foreground | colour_is($t.apex_fg)))
            and (.hint | (.text | startswith("The launcher searches apps only")) and (.font.size | px_is($t.apex_font_launcher_empty_hint_size)) and (.foreground | colour_is($t.apex_fg_dim)))'
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
spotlight_glass() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label Spotlight glass" "$scenes" "$tokens")
    local glass='(.blur | px_is($b | px)) and (.saturation == ($s | rtrimstr("%") | tonumber / 100))
        and (.effect | . != null and .enabled and .radius == (2 * ($b | px) * $scale | round) and .saturation == ($s | rtrimstr("%") | tonumber / 100))'

    "${metric[@]}" 'the panel blurs at $apex_spotlight_blur and $apex_spotlight_saturation, the toast at $apex_toast_blur and $apex_toast_saturation (radius 2 x sigma x the scale)' \
        '{g: .surfaces.spotlight.glass, scale: .monitorScale}' ".scale as \$scale
            | (.g.panelBeforeCopy | \$t.apex_spotlight_blur as \$b | \$t.apex_spotlight_saturation as \$s | $glass)
            and (.g.toast | \$t.apex_toast_blur as \$b | \$t.apex_toast_saturation as \$s | $glass)"
}

# S3a's exit items in the real shell, with Settings answering only after the 1 s budget.
# shellcheck disable=SC2016 # jq programs, not shell expansions
spotlight_keys() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label Spotlight keys" "$scenes" "$tokens")
    local k=.surfaces.spotlightKeys
    local shown='.sections == ["APPLICATIONS", "FILES"] and .rows == 6'

    "${metric[@]}" 'within the budget, with Settings asked and still out, Applications and Files show, the first row selected' \
        "$k" ".early.ms < .budgetMs and .settings.askedMs < .early.ms and (.early | $shown)
            and .early.selected == \"Applications/org.gnome.DiskUtility.desktop\""
    "${metric[@]}" 'past the budget, Settings is cancelled and left out; Applications and Files still show' \
        "$k" ".late.ms > .budgetMs and .settings.cancelledMs >= .budgetMs and .settings.cancelledMs < .slowMs and (.late | $shown)"
    "${metric[@]}" 'Down x4, Up x1 and Down x20, pressed for real, move one selection across the sections and stop at the last row' \
        "$k" '.down4 == "Files/images" and .up1 == "Files/png" and .down20 == "Files/md"'
    "${metric[@]}" 'Enter opens the selected file through its provider, with the terms, and closes Spotlight and its modal' \
        "$k" '.enter.open == false and .enter.modal == .modalBefore and .modalOpen == .modalBefore + 1
            and .enter.activated == [{provider: "org.gnome.Nautilus.desktop", id: "md", terms: ["disk"]}]'
    "${metric[@]}" 'Esc closes Spotlight and pops its modal' \
        "$k" '.escape.open == false and .escape.modal == .modalBefore'
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
        expect "fixtures ($part)" "$fixtures" '.powerProfiles | .active == "balanced" and (.profiles | index("performance") != null)' \
            "power-profiles-daemon: Balanced, with Performance to switch to"
        expect "fixtures ($part)" "$fixtures" '.gpus | .hasDualGpu and .names == ["Intel Graphics", "NVIDIA GeForce RTX 4060"]' \
            "switcheroo-control: an integrated and a discrete GPU"
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

# shellcheck disable=SC2016 # jq programs
motion_curve() {
    local run=$1 f=$1/motion.log m tokens
    exits "$run" motion 0
    apex_light motion "$f"
    no_apex_failure motion "$f"
    m=$(report_of "$f" APEXG2-MOTION)
    local error
    error=$(jq -r '.error // empty' <<<"$m" 2>/dev/null)
    if [[ -n $error ]]; then
        fail "motion: ${error%%$'\n'*}"
        return
    fi
    expect motion "$m" '.error == null and .animated.maximise.maximised and .animated.overview.visible' \
        "the probe maximised a GTK window and opened the overview, with animations on"
    expect motion "$m" ".animated.maximise.transition | .mode == \"CUBIC_BEZIER\" and .curve == $MOTION_CURVE and .duration == $MOTION_WINDOW_MS" \
        "maximise eases the window in cubic-bezier(.2,.8,.2,1) over ${MOTION_WINDOW_MS} ms"
    expect motion "$m" ".animated.overview.transition | .mode == \"CUBIC_BEZIER\" and .curve == $MOTION_CURVE and .duration == $MOTION_OVERVIEW_MS" \
        "the overview transition eases in cubic-bezier(.2,.8,.2,1) over ${MOTION_OVERVIEW_MS} ms"
    expect motion "$m" '.enableAnimations == false and .still.maximise.maximised and .still.overview.visible' \
        "then enable-animations=false, and the window maximised and the overview opened again"
    expect motion "$m" '.still.maximise.transition == null and .still.overview.transition == null' \
        "with enable-animations=false neither creates a transition: both take 0 ms"
    local steps='["dock-lift", "intellihide", "overview", "spotlight", "quick-settings", "calendar", "dialog"]' lasting
    expect motion "$m" ".animated.surfaces | ([.steps[].name] == $steps) and ([.lasting[] | select(.apex)] | length > 0)" \
        "the control: with animations on, the recorder sees the dock's own lift and slide eases last"
    lasting=$(jq -r '[.still.surfaces.lasting[]? | "\(.where) \(.durations | max) ms"] | join(", ")' <<<"$m" 2>/dev/null)
    if jq -e ".still.surfaces | ([.steps[].name] == $steps) and .apexEases > 0 and .lasting == []" <<<"$m" >/dev/null 2>&1; then
        pass "motion: with enable-animations=false, opening and closing each surface leaves no ease above 0 ms, Apex's or stock's, but animationRequired ones"
    else
        fail "motion: with enable-animations=false, opening and closing each surface leaves no ease above 0 ms, Apex's or stock's, but animationRequired ones (lasting: ${lasting:-none recorded})"
    fi
    tokens=$(tokens_for light)
    top_bar_metric motion "$m" "$tokens" \
        'each window preview draws two layers, 0 $apex_preview_shadow_y $apex_preview_shadow_blur $apex_preview_shadow and 0 $apex_preview_shadow_2_y $apex_preview_shadow_2_blur $apex_preview_shadow_2, radius $apex_radius_window_preview' \
        '.previews' 'length > 0 and all(.styled and (.layers | length == 2 and all(.shown and .radius == ($t.apex_radius_window_preview | px))
            and (.[0].boxShadow | (.y | px_is($t.apex_preview_shadow_y)) and (.blur | px_is($t.apex_preview_shadow_blur)) and (.color | colour_is($t.apex_preview_shadow)))
            and (.[1].boxShadow | (.y | px_is($t.apex_preview_shadow_2_y)) and (.blur | px_is($t.apex_preview_shadow_2_blur)) and (.color | colour_is($t.apex_preview_shadow_2)))))'
    expect motion "$m" ".still.locatePointer.duration == $LOCATE_POINTER_RIPPLE_MS" \
        "and Locate Pointer's ripple, an animationRequired a11y aid, still takes stock's ${LOCATE_POINTER_RIPPLE_MS} ms"
}

# The layer's features, in layer.js's own list, so a new feature is idle-tested at once.
layer_features() {
    sed -n '/^const FEATURES_IN_ENABLE_ORDER = \[/,/\];/p' "$APEX_JS_DIR/layer.js" | grep -o "'[a-z-]*'" | tr -d "'"
}

# The ui/apex/ file behind each JS class or apex- style class the offenders name.
apex_sources() {
    local token file
    grep -oE '(^|[ <;])[A-Z][A-Za-z0-9]*|\.apex-[a-z0-9-]+' | sed -E 's/^[ <;.]//' | sort -u | while read -r token; do
        if [[ $token == apex-* ]]; then
            file=$(grep -rlE "['\" ]${token}['\" ]" "$APEX_JS_DIR" 2>/dev/null | head -n 1)
        else
            file=$(grep -rlE "class $token( |\\{)" "$APEX_JS_DIR" 2>/dev/null | head -n 1)
        fi
        if [[ -n $file ]]; then
            printf '%s in ui/apex/%s\n' "$token" "${file#"$APEX_JS_DIR"/}"
        fi
    done | paste -sd';' - | sed 's/;/; /g'
}

# shellcheck disable=SC2016 # jq programs
idle_desktop() {
    local run=$1 f=$1/idle.log r error feature offenders sources relayouts
    exits "$run" idle 0
    apex_light idle "$f"
    no_apex_failure idle "$f"
    for feature in $(layer_features); do
        logs idle "$f" "Apex: feature $feature enabled" "the $feature feature is on"
    done
    r=$(report_of "$f" APEXG2-IDLE)
    error=$(jq -r '.error // empty' <<<"$r" 2>/dev/null)
    if [[ -n $error ]]; then
        fail "idle: ${error%%$'\n'*}"
        return
    fi
    expect idle "$r" ".windowMs == $IDLE_WINDOW_MS and (.settled | (.startingUp | not) and (.overview | not) and .dock.visible and .dock.rested and .barGlass and .dockGlass and .easing == [])" \
        "the session settled: startup over, no overview, the dock at rest, the bar's and the dock's glass on, nothing easing"
    offenders=$(jq -r '[.idle.frames[] | "at \(.atMs) ms, \(.damage.rectangles) rectangle(s) in \(.damage.extents | "\(.x),\(.y) \(.width)x\(.height)") under \(.damage.under | map(join(" < ")) | join(" | "))"] | join("; ")' <<<"$r" 2>/dev/null)
    sources=$(jq -r '[.idle.frames[].damage.under[][]] | join(" < ")' <<<"$r" 2>/dev/null | apex_sources)
    if jq -e '.idle.afterPaints == 0 and .idle.frames == []' <<<"$r" >/dev/null 2>&1; then
        pass "idle: over ${IDLE_WINDOW_MS} ms of an idle desktop the stage paints no frame"
    else
        fail "idle: over ${IDLE_WINDOW_MS} ms of an idle desktop the stage paints no frame ($(jq -r '.idle.afterPaints' <<<"$r" 2>/dev/null) painted: ${offenders:-none recorded}${sources:+; from $sources})"
    fi
    relayouts=$(jq -r '.idle.relayouts | to_entries | map("\(.key) x\(.value)") | join("; ")' <<<"$r" 2>/dev/null)
    if jq -e '.idle.relayouts == {}' <<<"$r" >/dev/null 2>&1; then
        pass "idle: and no actor queues a relayout"
    else
        fail "idle: and no actor queues a relayout (${relayouts:-unreadable}$(apex_sources <<<"$relayouts" | sed 's/^./; from &/'))"
    fi
    expect idle "$r" '.control.afterPaints > 0 and (.control.frames | length > 0)' \
        "the control: opening Quick Settings in a window of the same counter paints frames"
    expect idle "$r" '.control.frames | length > 0 and all(.damage.extents.width > 0 and .damage.extents.height > 0 and (.damage.under | length > 0))' \
        "and each of its frames names its damage and the actors under it, as a failure would"
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
    quick_settings_layer default "$f" apex
    notifications_layer default "$f" apex
    shadow_layers default "$f" light
    window_switcher default "$f" light
    modal_dialog default "$f" light
    date_menu default "$f" light
    overview_style default "$f" light
    app_grid default "$f" light
    overview_layer default "$f" light
    derived_surfaces default "$f" light
    tile_preview default "$f" light
    spotlight_style default "$f" light
    launcher_search default "$f" light
    spotlight_glass default "$f" light
    spotlight_keys default "$f" light
    screenshot_ui default "$f" light

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
    quick_settings_layer default-scale1 "$f" apex
    notifications_layer default-scale1 "$f" apex
    shadow_layers default-scale1 "$f" light
    window_switcher default-scale1 "$f" light
    modal_dialog default-scale1 "$f" light
    date_menu default-scale1 "$f" light
    overview_style default-scale1 "$f" light
    app_grid default-scale1 "$f" light
    overview_layer default-scale1 "$f" light
    derived_surfaces default-scale1 "$f" light
    tile_preview default-scale1 "$f" light
    spotlight_style default-scale1 "$f" light
    launcher_search default-scale1 "$f" light
    spotlight_glass default-scale1 "$f" light
    spotlight_keys default-scale1 "$f" light
    screenshot_ui default-scale1 "$f" light

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
    quick_settings_layer dark-style "$f" apex
    notifications_layer dark-style "$f" apex
    shadow_layers dark-style "$f" dark
    window_switcher dark-style "$f" dark
    modal_dialog dark-style "$f" dark
    date_menu dark-style "$f" dark
    overview_style dark-style "$f" dark
    app_grid dark-style "$f" dark
    overview_layer dark-style "$f" dark
    derived_surfaces dark-style "$f" dark
    tile_preview dark-style "$f" dark
    spotlight_style dark-style "$f" dark
    launcher_search dark-style "$f" dark
    spotlight_glass dark-style "$f" dark
    spotlight_keys dark-style "$f" dark
    screenshot_ui dark-style "$f" dark
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
        quick_settings_layer "$c" "$run/$c.log" stock
        notifications_layer "$c" "$run/$c.log" stock
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
    motion_curve "$run"
    idle_desktop "$run"

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
    glass_frames glass "$run/glass.log"
    shadows_under_glass glass "$run/glass.log"
    glass_manager glass "$run/glass.log" light
    glass_unlock_vs_fedora "$run"
    indicator_cases "$run"
}

indicator_cases() {
    local run=$1 c
    for c in indicators:light indicators-scale1:light indicators-dark:dark; do
        exits "$run" "${c%:*}" 0
        no_js_error "${c%:*}" "$run/${c%:*}.log"
        no_apex_failure "${c%:*}" "$run/${c%:*}.log"
        indicator_metrics "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    done
}

# Patch 0003's glass in the frames the shell drew (glass.js, the glass case).
glass_frames() {
    local label=$1 log=$2
    expect_report "$label" "$log" '.error == null and .patched' "the probe ran the glass cases on the patched ShellBlurEffect" APEXG2-GLASS
    expect_report "$label" "$log" '.pixels.reference | .clippedFirst and .reblurCovered' \
        "damage under the glass: the first frame's redraw clip leaves the box out (it damages again up to 5 times; else: could not obtain a partial redraw), the effect's own redraw covers it" APEXG2-GLASS
    local within="(.interior.max | max) <= $GLASS_INTERIOR_MAX and (.edge.max | max) <= $GLASS_EDGE_MAX and (.box.mean | max) <= $GLASS_MEAN_ERROR"
    expect_report "$label" "$log" ".pixels.reference | .downscale > 1 and $within" \
        "then the box is blur-ref.js's Gaussian, saturate() and corners per channel: within $GLASS_INTERIOR_MAX/255 inside, $GLASS_EDGE_MAX/255 in the ds/2 band along the edges, $GLASS_MEAN_ERROR/255 on average" APEXG2-GLASS
    expect_report "$label" "$log" '.pixels.sameFrame | .covered and .changed > 0 and .differingFromFull == 0' \
        "damage forwarded to the glass box re-blurs in the same frame, as a full redraw draws it" APEXG2-GLASS
    expect_report "$label" "$log" '.pixels.clippedRedraw | (.covered | not) and .differingFromLast == 0 and .nextCovered and .nextDifferingFromFull == 0' \
        "a redraw clip that misses the box (as above, up to 5 damages) draws the last result, pixel for pixel; the next frame is the full redraw's" APEXG2-GLASS
    expect_report "$label" "$log" '.pixels.stock | (.covered | not) and .tries >= 1' \
        "the stock control obtained a partial redraw, a frame whose redraw clip misses the box (it damages again up to 5 times; else: could not obtain a partial redraw)" APEXG2-GLASS
    expect_report "$label" "$log" ".pixels.stock | (.covered | not) and .differingFromFull > 0 and (($within) | not)" \
        "stock's blur in such a frame samples pixels the frame did not repaint and misses those tolerances, so the case can see it" APEXG2-GLASS
}

# shellcheck disable=SC2016 # jq programs
shadows_under_glass() {
    local label=$1 log=$2 all='[.shadows.light, .shadows.dark | .quickSettings, .popupMenu, .dialog]'
    expect_report "$label" "$log" "$all | length == 6 and all(.covered and .sameSize and .interiorDiffering == 0)" \
        "the shadow layers sit above their surfaces, cut out inside them: Quick Settings (glass, over the pattern), a popup menu and a dialog, light and dark, draw their interiors pixel for pixel as with shadows in disabled-features" APEXG2-GLASS
    expect_report "$label" "$log" "$all | length == 6 and all((.rim | type) == \"number\" and .rim <= $GLASS_EDGE_MAX)" \
        "and the cut-out's ramp keeps the 2 px rim the rounded box covers within $GLASS_EDGE_MAX/255 (outside the arc, the shadow shows)" APEXG2-GLASS
    expect_report "$label" "$log" "$all | length == 6 and all(.samePick and (.picked | test(\"apex-shadow-layer\") | not))" \
        "a click just inside a surface's edge reaches what it reaches with shadows off, never a layer" APEXG2-GLASS
    expect_report "$label" "$log" "[.shadows.light, .shadows.dark | .quickSettings, .popupMenu | .arrowless] | length == 4 and all" \
        "the menus' BoxPointers draw nothing of their own outside the box: no arrow colour or border for a layer to cover" APEXG2-GLASS
    expect_report "$label" "$log" '[.shadows.light, .shadows.dark | .quickSettings.corners] == ["shadow-corners-light.png", "shadow-corners-dark.png"]' \
        "Quick Settings' corners captured at 400 %, light and dark, for review (captures/shadow-corners-*.png)" APEXG2-GLASS
}

fedora_glass() {
    local run=$1
    exits "$run" fedora-glass 0
    expect_report fedora-glass "$run/fedora-glass.log" '.error == null and (.patched | not) and .unlock.file == "fedora-glass-unlock.png"' \
        "Fedora's ShellBlurEffect has none of 0003's properties; the unlock blur captured" APEXG2-GLASS
    check "fedora-glass: fedora-glass-unlock.png written" test -s "$run/captures/fedora-glass-unlock.png"
}

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
glass_manager() {
    local label=$1 log=$2 variant=$3 tokens glass
    tokens=$(tokens_for "$variant")
    local -a expect_glass=(expect "$label" "$(report_of "$log" APEXG2-GLASS | jq -c --argjson t "$tokens" '. + {t: $t}' 2>/dev/null)")
    glass='def glass($blur; $saturation; $s): .radius == 2 * ($blur | px) * $s and ((.saturation - ($saturation | rtrimstr("%") | tonumber / 100)) | fabs < 0.001)
        and .enabled and .fine and .followOpacity and .background;
        def none: [.panel, .dock, .quickSettings, .calendar, .banner] | all(. == null);'

    "${expect_glass[@]}" "$glass"' .t as $t | .manager.monitorScale as $s | .manager.glass | (.panel | glass($t.apex_bar_blur; $t.apex_bar_saturation; $s))
        and (.dock | glass($t.apex_dock_blur; $t.apex_dock_saturation; $s)) and ([.quickSettings, .calendar, .banner] | all(glass($t.apex_panel_blur; $t.apex_panel_saturation; $s))) and (.solidClass | not)' \
        'the bar blurs at $apex_bar_blur and $apex_bar_saturation, the dock at $apex_dock_blur and $apex_dock_saturation; Quick Settings, the calendar and a banner at $apex_panel_blur and $apex_panel_saturation, each as radius 2 x sigma x the monitor scale, fine, following opacity'
    "${expect_glass[@]}" "$glass"' .manager.reduceTransparency | none and .blurEffects == [] and .solidClass' \
        'with Reduce Transparency no actor carries a blur effect, and the root carries apex-solid'
    "${expect_glass[@]}" "$glass"' .manager.highContrast | none and .blurEffects == [] and .solidClass' \
        'nor with high contrast'
    "${expect_glass[@]}" "$glass"' .manager.disabled | none and .blurEffects == [] and (.solidClass | not)' \
        "with disabled-features=['glass'] no blur effect either, and the tints stay"
    "${expect_glass[@]}" "$glass"' .t as $t | .manager.monitorScale as $s | .manager.restored | (.panel | glass($t.apex_bar_blur; $t.apex_bar_saturation; $s)) and (.solidClass | not)' \
        'each switch turned back, the glass is back'
}

# The stock unlock blur, at default values of 0003's properties, is Fedora's to the pixel.
glass_unlock_vs_fedora() {
    local run=$1 plan=$1/compare/glass-plan.json results=$1/compare/glass-results.json
    mkdir -p "$run/compare"
    fedora_glass "$run"
    plan_entry stock-unlock-vs-fedora "$run" fedora-glass "$run" glass unlock "$run/compare" | jq -s . >"$plan"
    compare_and_expect_equal "$plan" "$results"
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
