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
# shellcheck source=tests/shots/parts.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/parts.sh"

readonly APEX_LIGHT_SHEET=resource:///org/gnome/shell/theme/gnome-shell-light.css
readonly APEX_DARK_SHEET=resource:///org/gnome/shell/theme/gnome-shell-dark.css
readonly STOCK_SHEETS=resource:///org/gnome/shell/theme/stock
readonly FEDORA_SHEETS=resource:///org/gnome/shell/theme
readonly DIRECT_CASES=(default default-scale1 dark-style high-contrast large-text default-solid dark-style-solid high-contrast-solid
    large-text-solid dock-intellihide dock-intellihide-dark dock-one-gpu no-dock no-dock-dark stock-light stock-dark safe-env
    layer-disabled layer-cycles motion idle dock-pin dock-dnd dock-external keys glass-load glass-stress fault-configure fault-enable fault-abort shutdown-banner
    kernel-safe
    fedora-light fedora-dark glass fedora-glass
    indicators indicators-scale1 indicators-dark)
readonly DIRECT_PARTS=(main kernel fedora)
readonly CAPTURE_CASES=(default default-scale1 dark-style stock-light stock-dark fedora-light fedora-dark)
readonly SCENES=(desktop overview)
readonly STOCK_MAX_THUMBNAIL_SCALE=0.05
readonly OVERVIEW_THUMBNAIL_SCALE=0.081
readonly OVERVIEW_THUMBNAILS_THRESHOLD=1
readonly EMPTY_WORKSPACE_TEXT='No open windows'
# probe.js's overview with windows, over its fixture gradient; stock's flat thumbnail is 0.
readonly OVERVIEW_WINDOWS=3
readonly OVERVIEW_THUMBNAIL_MIN_SPREAD=0.1
readonly LAUNCHER_COLUMNS=7
readonly LAUNCHER_ROWS=4
readonly LAUNCHER_ICON_SIZE=88
readonly MESSAGE_ICON_SIZE=32
readonly MESSAGE_ROW_GAP=12
readonly CARD_COLUMNS='box[apex-message-row[message-icon,box[message-header,message-box[message-content,box]]],message-action-bin]'
readonly CARD_UPSTREAM='box[message-header,message-box[message-icon,message-content,box],message-action-bin]'
readonly LAUNCHER_GRID_TOP=132
# Stock windowPreview.js's WindowPreview hangs the title 64 * (1 - .7) + 6 px under the preview.
readonly STOCK_CAPTION_GAP=25.2
# WCAG 2.2 AA: 1.4.3 for text, 1.4.11 for the glyphs a control is known by.
# direct.sh's stress backdrop.
readonly SOLID_BACKDROP='#013b88'
readonly A11Y_TEXT_RATIO=4.5
readonly A11Y_ICON_RATIO=3
readonly A11Y_ACCENTS=(blue teal green yellow orange red pink purple slate)
readonly A11Y_SURFACES=(bar barUnread dock popupMenu osd banner quickSettings "${A11Y_ACCENTS[@]/#/quickSettingsAccents.}" wifiMenu wifiMenuConnected dateMenu
    "${A11Y_ACCENTS[@]/#/dateMenuAccents.}" switcher dialog "${A11Y_ACCENTS[@]/#/dialogAccents.}" endSession screenshot
    spotlight.popup spotlight.toast overview appGrid)
# The failures still open: upstream's high-contrast sheet, which safe mode keeps as Fedora's.
readonly A11Y_HC_TOGGLE="upstream HC sheet: Quick Settings' checked toggle, white on its accent (3.15:1), and its menu arrow (2.31:1)"
declare -A A11Y_GAPS=([high-contrast:quickSettings]=$A11Y_HC_TOGGLE)
for a11y_accent in "${A11Y_ACCENTS[@]}"; do
    A11Y_GAPS[high-contrast:quickSettingsAccents.$a11y_accent]=$A11Y_HC_TOGGLE
done
readonly A11Y_HC_TODAY="upstream HC sheet: the calendar's today, white on its accent (2.59:1 to 3.79:1)"
A11Y_GAPS[high-contrast:dateMenu]=$A11Y_HC_TODAY
for a11y_accent in blue teal green yellow orange red pink slate; do
    A11Y_GAPS[high-contrast:dateMenuAccents.$a11y_accent]=$A11Y_HC_TODAY
done
unset a11y_accent
# The high-contrast gaps are the sheet's own colours, the same over the #013b88 backdrop.
for a11y_gap in "${!A11Y_GAPS[@]}"; do
    if [[ $a11y_gap == high-contrast:* ]]; then
        A11Y_GAPS[high-contrast-solid:${a11y_gap#*:}]=${A11Y_GAPS[$a11y_gap]}
    fi
done
unset a11y_gap
readonly A11Y_GAPS
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
# GNOME's own keys, as its schemas and windowManager.js, overviewControls.js and main.js register them.
readonly PANELS_KEYS='["<Control><Alt>Tab"]'
readonly PANELS_MODES='["NORMAL", "OVERVIEW", "LOCK_SCREEN", "UNLOCK_SCREEN", "LOGIN_SCREEN"]'
readonly APP_VIEW_KEYS='["<Super>a"]'
# DESIGN's motion: cubic-bezier(.2,.8,.2,1); window geometry .3 s, the overview .2 s.
readonly MOTION_CURVE='[0.2, 0.8, 0.2, 1]'
readonly MOTION_WINDOW_MS=300
readonly MOTION_OVERVIEW_MS=200
readonly LOCATE_POINTER_RIPPLE_MS=830
# ROADMAP S3c: an idle desktop shows no extra repaints, with every feature of the layer on.
readonly APEX_JS_DIR=${G2_APEX_JS_DIR:-$SHOTS_DIR/../../desktop/shell/js/ui/apex}
readonly IDLE_WINDOW_MS=10000
# ADR 0014's protocol in G2's terms (lead, 2026-10-24): glass may add at most 1 % frames over
# Reduce Transparency for the same scenario; the stress runs at least 60 s.
readonly GLASS_EXTRA_FRAMES_RATIO=1.01
# B opens and closes Quick Settings and then the calendar: the bar's own buttons repaint at each.
readonly GLASS_B_MENU_TOGGLES=4
readonly GLASS_STRESS_MIN_SECONDS=60
readonly DOCK_PIN_FALLBACK_MS=20000
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
# Board 22's ring width from its coverage (glass.js ringWidths): 8-bit rounding moves it under 0.05
# device px; St's inset-shadow ring inside a clear border measures 8 px at its corners against 4.
readonly TILE_RING_ALLOWANCE=0.25
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

# With malcontent's typelib (the image's flatpak-libs brings it), a failed read of the user's parental
# controls leaves gnome-shell hiding every app: no favourite, dash or app grid.
parental_controls_ready() {
    local label=$1 log=$2 failed
    failed=$(grep -hm1 'Failed to get parental controls settings' "$log" "${log%.log}.late.log" 2>/dev/null | head -n 1)
    if [[ -z $failed ]]; then
        pass "$label: the shell read the user's parental controls"
    else
        fail "$label: the shell could not read the user's parental controls, so it hides every app: ${failed#*settings: }"
    fi
}

# St drops a declaration it cannot parse with a warning naming the sheet's line, and keeps the cascade's earlier value.
no_st_css_warning() {
    local label=$1 log=$2 found
    found=$(grep -ahE 'St-WARNING \*\*: .* at line [0-9]+, col [0-9]+' "$log" "${log%.log}.late.log" 2>/dev/null \
        | sed -E 's/.*St-WARNING \*\*: [0-9:.]+: //' | sort | uniq -c | sed -E 's/^ *//' | paste -sd';' -)
    if [[ -z $found ]]; then
        pass "$label: no St CSS warning (a declaration St ignored) in the log"
    else
        fail "$label: St ignored declarations, count and warning: $found"
    fi
}

# Clutter refuses a NaN box with a CRITICAL and leaves the actor unallocated, which a case can survive:
# the CRITICAL fails it, in the case's log and in a late first start's log where the image run reran it.
no_nan_allocation() {
    local label=$1 log=$2 found
    found=$(grep -c "clutter_actor_allocate: assertion '!isnan" "$log" "${log%.log}.late.log" 2>/dev/null | grep -v ':0$' | sed 's|.*/||' | paste -sd' ' -)
    if [[ -z $found ]]; then
        pass "$label: no NaN allocation (Clutter-CRITICAL '!isnan') in the log"
    else
        fail "$label: NaN allocations, Clutter-CRITICAL '!isnan' per log: $found"
    fi
}

# GJS logs a disposed object that JS still touches with the stack that touched it; an Apex frame there
# acts on a destroyed actor, as the dock's dash redisplay did at logout before the shell crashed.
no_disposed_apex() {
    local label=$1 log=$2 found
    found=$(cat "$log" "${log%.log}.late.log" 2>/dev/null | awk '/has been already disposed/ { object = $0; sub(/.*Object /, "", object); sub(/ \(0x.*/, "", object); block = 1; counted = 0; next }
        block && /^(== Stack trace|#[0-9])/ { if (/\/ui\/apex\// && !counted) { n++; counted = 1; if (!first) { first = $0; sub(/^#[0-9]+ +[^ ]+ +[a-z] +/, "", first); first = object " at " first } }; next }
        { block = 0; counted = 0 }
        END { if (n) print n " with an Apex frame, first " first }')
    if [[ -z $found ]]; then
        pass "$label: no disposed object touched from an Apex frame"
    else
        fail "$label: disposed objects touched: $found"
    fi
}

# Clutter warns and skips an actor still queued for a relayout once it has left the stage: a shadow
# layer destroyed with its relayout queued twice, and the panel at logout, before #167, were.
no_spurious_allocation() {
    local label=$1 log=$2 found
    found=$(cat "$log" "${log%.log}.late.log" 2>/dev/null | grep -o 'Spurious clutter_actor_allocate called for actor [^ ]* \[[^]]*\]' |
        sed 's|.*actor 0x[0-9a-f]*/||' | sort | uniq -c | sed -E 's/^ *//' | paste -sd';' -)
    if [[ -z $found ]]; then
        pass "$label: no spurious allocation (Clutter laying out an actor no longer on the stage) in the log"
    else
        fail "$label: spurious allocations, count and actor: $found"
    fi
}

# At logout a relayout run once its actor has left the stage lays it out off it, and a window unmanaged
# after the global's disposal reaches ShellWM through a NULL global, as 0019 stops: both warn first.
clean_shutdown() {
    local label=$1 log=$2 out found
    # A line another process logs as the shell goes, as ibus-daemon's once it loses the display, is
    # not the shell's and prints as a note; the shell's own lines, and lines without a process, fail.
    out=$(cat "$log" "${log%.log}.late.log" 2>/dev/null | sed -n '/Shutting down GNOME Shell/,$p' | awk '
        match($0, /^\([^():]+:[0-9]+\): /) {
            name = substr($0, 2, index($0, ":") - 2)
            sub(/.*\//, "", name)
            if (name != "gnome-shell") {
                if (/CRITICAL|WARNING/) print "# note " name ": " substr($0, RLENGTH + 1)
                next
            }
        }
        found == "" && /which is not in the stage|shell_global_get: assertion|G_IS_OBJECT/ { found = $0 }
        END { if (found != "") print "FOUND " found }')
    grep '^# note ' <<<"$out"
    found=$(sed -n 's/^FOUND //p' <<<"$out" | sed 's/.*\*\*: [0-9:.]* //')
    if [[ -z $found ]]; then
        pass "$label: the shell shuts down without laying out an actor off the stage or reaching a gone global"
    else
        fail "$label: at shutdown: $found"
    fi
}

# gnome-shell 51 runs a main loop after its shutdown destroyed uiGroup: a banner timeout the tray left
# armed runs there on the disposed tray, as Apex's notifications feature stops.
no_disposed_at_shutdown() {
    local label=$1 log=$2 found
    found=$(cat "$log" "${log%.log}.late.log" 2>/dev/null | sed -n '/Shutting down GNOME Shell/,$p' |
        awk '/has been already disposed/ && !object { object = $0; sub(/.*Object /, "", object); sub(/ \(0x.*/, "", object); next }
            object && /^#0/ && !frame { frame = $0; sub(/^#0 +[^ ]+ +[a-z] +/, "", frame); sub(/ \(.*/, "", frame) }
            END { if (object) print object (frame ? " at " frame : "") }')
    if [[ -z $found ]]; then
        pass "$label: nothing touches a disposed object once the shell is shutting down"
    else
        fail "$label: after 'Shutting down GNOME Shell', a disposed object touched: $found"
    fi
}

# The probe empties the tray, and blocks the date menu's signal paths, before the shell exits: no case but
# shutdown-banner meets those races, and a path that blocks no handler (a rename upstream) fails here.
readonly DATE_MENU_CUT='(.cut | keys) == ["changed", "installed-changed", "notify::has-calendars"] and all(.cut[]; . > 0)'
exit_cut() {
    local label=$1 log=$2
    expect "$label" "$(report_of "$log" APEXG2-EXIT)" ".tray == true and $DATE_MENU_CUT" \
        "the probe leaves no banner up, and blocks the date menu's event-source and app-list handlers, for the shell's shutdown"
}

# G2's fixture apps (direct.sh's STUB_APPS) have no icon of their own: GNOME draws its generic one.
readonly FIXTURE_APPS=(io.github.apex_linux.G2Stub1.desktop io.github.apex_linux.G2Stub2.desktop io.github.apex_linux.G2Stub3.desktop)
# Icons the shell draws from its own resource because Apex Symbolic (board 31) draws none of that name yet: each
# is one apex-desktop#35 ships, and leaves this list when APEX_DESKTOP_REV reaches it (surface_icons fails it then).
readonly SHELL_RESOURCE_ICONS=(
    screenshooter-symbolic
    notification-expand-symbolic
    switch-on-symbolic
    switch-off-symbolic
    screenshot-ui-area-symbolic
    screenshot-ui-display-symbolic
    screenshot-ui-window-symbolic
    screenshot-ui-show-pointer-symbolic
    preview-close-symbolic
)
# Stock icons a surface legitimately draws, "surface name" by exact name, never a pattern.
readonly STAND_IN_ICONS=(
    # G2's switcher stand-in (probe.js's windowSwitcher) gives its items GNOME's generic app icon.
    'switcher application-x-executable'
    # A full-colour device icon a search provider returns: Apex draws symbolic glyphs, Colloid app icons and
    # boards 27-29's places and mimetypes, and inherits Adwaita's devices by design (Inherits=Adwaita,hicolor).
    'spotlight drive-harddisk'
)

# expect, but a failure quotes DETAIL, what the shell had, rather than the condition's false.
expect_named() {
    local label=$1 report=$2 cond=$3 detail=$4 desc=$5
    if [[ -z $report ]]; then
        fail "$label: $desc (no report)"
    elif jq -e "$cond" <<<"$report" >/dev/null 2>&1; then
        pass "$label: $desc"
    else
        fail "$label: $desc (got $(jq -c "$detail" <<<"$report" 2>&1 | head -c 300))"
    fi
}

# S1b's session defaults, as the image's apex-desktop sets them: its fonts, hinting and icon theme read
# and drawn, and every icon the bar, the dock, the dash and Quick Settings show resolved through Apex.
session_defaults() {
    local label=$1 log=$2 r want bad
    r=$(report_of "$log" APEXG2-SESSION)
    if [[ -n $r && -n $(jq -r '.error // empty' <<<"$r") ]]; then
        fail "$label: session defaults: $(jq -r '.error' <<<"$r" | head -n 1)"
        return
    fi
    want=$(jq -nc --arg f "$SESSION_FONT_NAME" --arg d "$SESSION_DOCUMENT_FONT_NAME" --arg m "$SESSION_MONOSPACE_FONT_NAME" \
        --arg h "$SESSION_FONT_HINTING" --arg i "$SESSION_ICON_THEME" '[$f, $d, $m, $h, $i] | map(ltrimstr("\u0027") | rtrimstr("\u0027"))
        | {"font-name": .[0], "document-font-name": .[1], "monospace-font-name": .[2], "font-hinting": .[3], "icon-theme": .[4]}')
    bad=$(jq -r --argjson want "$want" '.settings as $s | $want | to_entries[] | select($s[.key] != .value)
        | "\(.key) is \($s[.key] | tojson), not \(.value | tojson)"' <<<"$r" 2>&1 | paste -sd';' -)
    if [[ -n $r && -z $bad ]]; then
        pass "$label: the session reads apex-desktop's fonts, hinting and icon theme"
    else
        fail "$label: the session reads apex-desktop's fonts, hinting and icon theme (${bad:-no report})"
    fi
    expect_named "$label" "$r" ".shell == $(jq -c '{font: .["font-name"], iconTheme: .["icon-theme"]}' <<<"$want")" .shell \
        "the shell draws with that font and icon theme"
    expect_named "$label" "$r" '.fontconfig.sans.family == "Adwaita Sans" and (.fontconfig.sans.features | index("ss03") != null)' \
        .fontconfig.sans "fontconfig gives Adwaita Sans, with ss03, for its family"
    expect_named "$label" "$r" '.fontconfig.mono.family == "JetBrains Mono"' .fontconfig.mono \
        "fontconfig gives JetBrains Mono for its family, not a fallback"
    expect_named "$label" "$r" '.drawn.clock == "Adwaita Sans"' .drawn.clock "the bar's clock is drawn in Adwaita Sans"
    bad=$(jq '.icons' <<<"$r" 2>/dev/null | icons_not_apex)
    if [[ -n $r && -z $bad && $(jq '[.icons[] // [] | length] | add' <<<"$r") -gt 0 ]]; then
        pass "$label: every icon the bar, the dock, the dash and Quick Settings draw resolves through Apex"
    else
        fail "$label: every icon the bar, the dock, the dash and Quick Settings draw resolves through Apex (${bad:-no icons reported})"
    fi
    bad=$(jq -r --argjson resource "$(printf '%s\n' "${SHELL_RESOURCE_ICONS[@]}" | jq -R . | jq -sc .)" \
        '[.apexSymbolic // [] | .[] | select(. as $n | $resource | index($n))] | join(", ")' <<<"$r" 2>/dev/null)
    if [[ -n $r && $(jq '.apexSymbolic // [] | length' <<<"$r") -gt 0 && -z $bad ]]; then
        pass "$label: no icon listed as the shell's own (SHELL_RESOURCE_ICONS) is one Apex Symbolic ships"
    else
        [[ -n $bad ]] && bad="listed as shell-only, but /usr/share/icons/Apex has it: $bad"
        fail "$label: no icon listed as the shell's own (SHELL_RESOURCE_ICONS) is one Apex Symbolic ships (${bad:-no Apex Symbolic glyphs reported})"
    fi
    grep -q 'APEXG2-SCENES ' "$log" 2>/dev/null && surface_icons "$label" "$log"
}

# Each icon of an object of surfaces that resolves neither under Apex nor to a listed exception, as "where name: file".
icons_not_apex() {
    jq -r --argjson fixtures "$(printf '%s\n' "${FIXTURE_APPS[@]}" | jq -R . | jq -sc .)" \
        --argjson resource "$(printf '%s\n' "${SHELL_RESOURCE_ICONS[@]}" | jq -R . | jq -sc .)" \
        --argjson standIn "$(printf '%s\n' "${STAND_IN_ICONS[@]}" | jq -R . | jq -sc .)" '
        to_entries[] | .key as $where | (.value // [])[]
        | (.icon | if startswith(". GThemedIcon ") then split(" ")[2] else . end) as $name
        | select((.file // "" | startswith("/usr/share/icons/Apex/")) | not)
        | select($standIn | index("\($where) \($name)") | not)
        | select(((.file // "" | startswith("/org/gnome/shell/icons/")) and ($resource | index($name))) | not)
        | .app as $app | select($app == null or ($fixtures | index($app) | not))
        | "\($where) \($name)\(if $app then " (\($app))" else "" end): \(.file // "no icon")"' 2>&1 | paste -sd';' -
}

# The surfaces the probe opens after its scenes (probe.js's iconSurfaces), by the boards they draw.
readonly ICON_SURFACES=(
    "dateMenu|board 34's date menu and notifications"
    "overview|board 35's overview"
    "launcher|board 36's launcher grid"
    "spotlight|board 38's Spotlight results"
    "switcher|board 15's window switcher"
    "surfaces|board 16's popup menu, OSD and banner"
    "dialog|board 13's dialog"
    "endSession|board 14's end-session dialog"
    "screenshot|board 19's screenshot UI"
)

# S1b's exit row over every surface G2 opens: each draws icons, and every one resolves as session_defaults' rule says.
surface_icons() {
    local label=$1 log=$2 r entry key desc got bad
    r=$(report_of "$log" APEXG2-SESSION-SURFACES)
    if [[ -z $r || -n $(jq -r '.error // empty' <<<"$r" 2>/dev/null) ]]; then
        fail "$label: the probe walks the icons of every surface it opens (${r:+$(jq -r '.error' <<<"$r" | head -n 1)}${r:-no report})"
        return
    fi
    for entry in "${ICON_SURFACES[@]}"; do
        key=${entry%%|*} desc=${entry#*|}
        got=$(jq -c --arg k "$key" '.[$k]' <<<"$r")
        if [[ $got == null || $(jq -r 'if type == "array" then length else 0 end' <<<"$got") == 0 ]]; then
            fail "$label: $desc draws icons for the walk (got $(jq -c '.' <<<"$got" | head -c 200))"
            continue
        fi
        bad=$(jq --arg k "$key" '{($k): .[$k]}' <<<"$r" | icons_not_apex)
        if [[ -z $bad ]]; then
            pass "$label: every icon $desc draws resolves through Apex ($(jq length <<<"$got") icons)"
        else
            fail "$label: every icon $desc draws resolves through Apex ($bad)"
        fi
    done
}

# Mutter warns when two bindings claim one key: the second silently takes it from the first.
no_binding_overwritten() {
    local label=$1 log=$2 found
    found=$(cat "$log" "${log%.log}.late.log" 2>/dev/null | grep -m1 'Overwriting existing binding' | sed 's/.*WARNING \*\*: [0-9:.]* //')
    if [[ -z $found ]]; then
        pass "$label: no key binding overwrites another"
    else
        fail "$label: $found"
    fi
}

# A probe imported after startup completed emits startup-complete again (probe.js's init), so main.js's
# handler, whose "GNOME Shell started" line says it ran, runs the probe either way.
startup_handler_ran() {
    local label=$1 log=$2 when='on time' runs
    grep -q 'APEXG2-LATE' "$log" && when='after the import, from startup-complete again'
    runs=$(grep -c 'GNOME Shell started at ' "$log" 2>/dev/null) || runs=0
    if ((runs == 1)); then
        pass "$label: main.js's startup-complete handler ran once, and the probe from it ($when)"
    else
        fail "$label: main.js's startup-complete handler ran $runs times, not once (\"GNOME Shell started\" lines; probe $when)"
    fi
}

# The startup overview's grab sets OVERVIEW before startup-complete, so a late probe (main.js's handler
# skipped) finds what an on-time one does; once no modal is left, popModal sets NORMAL.
action_modes() {
    local label=$1 log=$2 r
    r=$(report_of "$log" APEXG2-MODES)
    expect "$label" "$r" '.atRun == "OVERVIEW"' \
        "the probe started under the startup overview's OVERVIEW action mode ($(jq -r 'if .late then "late" else "on time" end' <<<"$r" 2>/dev/null))"
    expect "$label" "$r" '.atEnd == (if .overview then "OVERVIEW" elif .modals == 0 then "NORMAL" else .atEnd end) and .atEnd != "NONE"' \
        "and it ended in NORMAL with no modal left, OVERVIEW with the overview open"
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

# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
dock_live_keys() {
    local label=$1 log=$2 variant=$3 report tokens
    report=$(report_of "$log" APEXG2-DOCK)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label live keys" "$report" "$tokens")
    local k=.steps.liveKeys medium='all(px_is($t.apex_dock_icon_size))'

    "${metric[@]}" 'show-focused-app-name=false hides the focused app'"'"'s name, and its reset shows it again' \
        "$k.focusedAppOff" '.set.focusedApp.visible == false and .reset.focusedApp.visible == true'
    "${metric[@]}" 'dock-icon-size small makes every icon 46, its reset $apex_dock_icon_size again' \
        "$k.small" "(.set.iconSizes | length > 0 and all(. == 46)) and (.reset.iconSizes | $medium)"
    "${metric[@]}" 'dock-icon-size large makes every icon 62, its reset $apex_dock_icon_size again' \
        "$k.large" "(.set.iconSizes | length > 0 and all(. == 62)) and (.reset.iconSizes | $medium)"
    "${metric[@]}" 'dock-running-indicators=false clears the running app'"'"'s dot, and its reset draws it in $apex_dock_dot again' \
        "$k.dotsOff" '(.set.dots | length > 0 and all(.colour | rgba | .[3] == 0)) and (.reset.dots | length > 0 and all(.colour | colour_is($t.apex_dock_dot)))'
    "${metric[@]}" 'dock-show-trash=false takes Trash out, and its reset puts it last again' \
        "$k.trashOff" '(.set.kinds | index("trash") == null) and .reset.kinds[-1] == "trash"'
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
    dock_live_keys "$label" "$log" "$4"
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
    "${metric[@]}" 'each source'"'"'s chip is its short name in capitals, an IBus source'"'"'s its engine'"'"'s language code, never its symbol' \
        '.everything.input.sources' 'length >= 2 and all(.[]; (.language // "" | split("_")[0]) as $code
            | .text == (if .type == "ibus" and ($code | length) >= 2 and ($code | length) <= 3
                then $code + (.stock | capture("(?<s>[₀-₉]*)$").s) else .stock end | ascii_upcase))'
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

# shellcheck disable=SC2016 # a jq program and token names
readonly SOLID_BAR_OFF='(.solid | not) and (.background | colour_is($t.apex_bar)) and .boxShadow == null and .glass.enabled == true'

# A window maximised on the primary monitor turns the bar solid; un-maximised, it turns it back.
# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
solid_bar() {
    local label=$1 log=$2 variant=$3 report tokens
    report=$(report_of "$log" APEXG2-SOLID-BAR)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label solid bar" "$report" "$tokens")
    "${metric[@]}" 'with a window open but not maximised the bar is $apex_bar glass, no line under it' \
        '.steps.unmaximised' "$SOLID_BAR_OFF"
    "${metric[@]}" 'maximising it turns the bar solid: $apex_bar_solid over a 0 1px 0 $apex_border line, its glass paused' \
        '.steps.maximised' \
        '.solid and (.background | colour_is($t.apex_bar_solid)) and .glass.enabled == false
            and (.boxShadow | .inset == false and .x == 0 and .y == 1 and .blur == 0 and .spread == 0 and (.color | colour_is($t.apex_border)))'
    "${metric[@]}" 'un-maximising it turns the bar back to $apex_bar glass' '.steps.restored' "$SOLID_BAR_OFF"
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
    "${metric[@]}" 'a row has no fill until hovered or :checked, then $apex_button_hover, the Wi-Fi menu'"'"'s connected fill aside' \
        "$m.rows" 'all((.background | rgba | .[3] == 0) and (.hover.background | colour_is($t.apex_button_hover)) and (.checked.background | colour_is($t.apex_button_hover)))'
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
    local layer='length == 1 and (.[0] | .shown and .box == .surfaceBox and (.boxShadow | .inset == false and .x == 0
        and (.y | px_is($t.apex_shadow_2_y)) and (.blur | px_is($t.apex_shadow_2_blur)) and (.color | colour_is($t.apex_shadow_2))))'
    "${metric[@]}" 'Quick Settings draws its second layer, 0 $apex_shadow_2_y $apex_shadow_2_blur $apex_shadow_2, on its own box' \
        '.surfaces.shadowLayers.quickSettings' "$layer and .[0].radius == (\$t.apex_radius_quick_settings | px)"
    "${metric[@]}" 'the calendar draws its second layer, 0 $apex_shadow_2_y $apex_shadow_2_blur $apex_shadow_2, on its own box' \
        '.surfaces.shadowLayers.dateMenu' "$layer"
    "${metric[@]}" 'a popup menu held at its min-width, past its natural width, draws its second layer on its whole box' \
        '.surfaces.shadowLayers.popupMenu' "$layer and (.[0] | .surfaceBox[2] - .surfaceBox[0] > .natural[0])"
    "${metric[@]}" "a dialog's second layer sits beside its box, above the lightbox under the dialog" \
        '.surfaces.shadowLayers.dialog' "$layer and .[0].besideBox"
    expect "$label shadows" "$scenes" '.surfaces.idleRepaints | .withShadows <= .withoutShadows' \
        "an idle desktop repaints no more with the shadow layers than with shadows in disabled-features"
}

# Board 17's network rows: each name, its signal glyph and its lock centred on the row, as the
# canvas draws them; network.js's name fills the row, its text at the top of a taller one.
# shellcheck disable=SC2016 # a jq program
network_rows_centred() {
    local label=$1 scenes=$2 rows=$3
    expect "$label Quick Settings" "$scenes" "$rows"' | def mid: .y + .height / 2; length > 1
        and all(.box as $r | [.label, .signal, .lockBox | select(. != null)] | all((mid - ($r | mid)) | fabs <= 1))' \
        "every network's name, signal glyph and lock are centred on its row, within 1 px (board 17)"
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
        network_rows_centred "$label" "$scenes" "$q.wifiMenu.rows"
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
        expect "$label notifications" "$scenes" "$q.trees | length == 3 and all(. == \"$CARD_COLUMNS\")" \
            "every card, the back ones too: the icon's column beside the header over the title and body, the actions under both"
        expect "$label notifications" "$scenes" "$q.layout.collapsed | .icon.width == $MESSAGE_ICON_SIZE
            and (.header.x - .icon.x - .icon.width - $MESSAGE_ROW_GAP | fabs <= 1) and (.title.x - .header.x | fabs <= 1)
            and .title.y >= .header.y + .header.height - 1 and .close.x > .header.x and .close.x + .close.width <= .card.x + .card.width
            and .actions == null" \
            "a card: the $MESSAGE_ICON_SIZE px icon, $MESSAGE_ROW_GAP px from the column of the header over the title; the close button on the right"
        expect "$label notifications" "$scenes" "$q.layout.expanded | .actions != null and (.tree | startswith(\"box[apex-message-row[\"))
            and .actions.x <= .icon.x + 1 and .actions.x + .actions.width >= .title.x + .title.width - 1 and .actions.y >= .title.y" \
            "expanded, a card's action row spans both columns, under them"
        expect "$label notifications" "$scenes" "$q.layout.collapsedAgain | .actions == null and .tree == \"$CARD_COLUMNS\"" \
            "collapsed again, the same columns, the action row hidden"
    else
        expect "$label notifications" "$scenes" "$q | (.messages | length == 3) and ($flat | not) and .dnd == null
            and .cardHeader.sourceIcon and .icon == null" \
            "stock: an app's notifications stack, each header keeps its glyph, and the footer has Clear alone"
        expect "$label notifications" "$scenes" "$q.empty | .placeholder and (.clearVisible | not)" \
            "stock: with nothing to clear, Clear hides"
        expect "$label notifications" "$scenes" "$q.trees | length == 3 and all(. == \"$CARD_UPSTREAM\")" \
            "stock: upstream's card, exactly: the header, then the icon beside the title and body, then the actions"
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
    "${metric[@]}" 'a checked toggle is the accent shaded $apex_quick_toggle_checked_shade with black, its text the accent'"'"'s foreground, its subtitle that at $apex_quick_toggle_subtitle_opacity' \
        "{t: $q.wifi.toggle, accent: .topBar.accent}" '(.accent | rgba) as $a | (.t.background | rgba) as $f | ($t.apex_quick_toggle_checked_shade | rtrimstr("%") | tonumber / 100) as $k
            | ([range(3)] | all(($f[.] - $a[.] * (1 - $k)) | fabs <= 1)) and (.t.foreground | colour_is("#ffffff"))
            and (.t.subtitle.foreground | colour_is("rgba(255, 255, 255, \($t.apex_quick_toggle_subtitle_opacity))"))'
    "${metric[@]}" 'a toggle is padded $apex_quick_toggle_padding ($apex_quick_toggle_menu_padding before a menu arrow), $apex_quick_toggle_gap between glyph and text, its glyph $apex_quick_settings_icon_size' \
        "[$q.wifi.toggle, $q.unchecked]" 'all((.box.padding.left | px_is($t.apex_quick_toggle_padding)) and (.box.spacing | px_is($t.apex_quick_toggle_gap)) and (.icon | px_is($t.apex_quick_settings_icon_size)))
            and (.[0].box.padding.right | px_is($t.apex_quick_toggle_menu_padding)) and (.[1].box.padding.right | px_is($t.apex_quick_toggle_padding))'
    "${metric[@]}" 'its title is $apex_font_quick_toggle_title_size at $apex_font_heading_weight, its subtitle $apex_font_quick_toggle_subtitle_size' \
        "$q.wifi.toggle" '(.title.font.size | px_is($t.apex_font_quick_toggle_title_size)) and .title.font.weight == ($t.apex_font_heading_weight | tonumber)
            and (.subtitle.font.size | px_is($t.apex_font_quick_toggle_subtitle_size))'
    "${metric[@]}" 'the menu arrow is $apex_quick_toggle_menu_button_width wide, the checked fill shaded $apex_quick_toggle_menu_button_shade more with black, with no separator' \
        "{w: $q.wifi, accent: .topBar.accent}" "(.accent | rgba) as \$a | (.w.menuButton.background | rgba) as \$m
            | (\$t.apex_quick_toggle_checked_shade | rtrimstr(\"%\") | tonumber / 100) as \$k
            | (.w.menuButton.width | px_is(\$t.apex_quick_toggle_menu_button_width)) and (.w.separator.width == 0)
            and ([range(3)] | all((\$m[.] - \$a[.] * (1 - \$k) * $shade) | fabs <= 1))"
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
    "${metric[@]}" 'the connected network'"'"'s row is filled $apex_button at $apex_font_label_weight, $apex_button_hover under the pointer; the others are unfilled' \
        "$q.wifiMenu" '(.connected | (.background | colour_is($t.apex_button)) and .label.font.weight == ($t.apex_font_label_weight | tonumber)
            and (.hover.background | colour_is($t.apex_button_hover))) and (.other | (.background | rgba | .[3] == 0) and .label.font.weight == 400)'
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
    "${metric[@]}" 'a button is $apex_button ($apex_button_hover hovered); the default one the accent shaded $apex_quick_toggle_checked_shade with black, in white' \
        "{b: $d.buttons, accent: .topBar.accent}" '(.accent | rgba) as $a | ($t.apex_quick_toggle_checked_shade | rtrimstr("%") | tonumber / 100) as $k
            | (.b | map(select(.default | not)) | length == 1 and all((.background | colour_is($t.apex_button)) and (.foreground | colour_is($t.apex_fg)) and (.hover.background | colour_is($t.apex_button_hover))))
            and (.b | map(select(.default)) | length == 1 and all((.background | rgba) as $f | ([range(3)] | all(($f[.] - $a[.] * (1 - $k)) | fabs <= 1))
                and (.foreground | colour_is("#ffffff"))))'
    "${metric[@]}" 'the end-session dialog has $apex_end_session_gap between its parts, its title tracked $apex_dialog_title_tracking, its countdown in tabular figures' \
        "$d.endSession" '(.box.spacing | px_is($t.apex_end_session_gap)) and (.contentSpacing | px_is($t.apex_end_session_gap))
            and (.title.tracking - ($t.apex_dialog_title_tracking | px) | fabs < 0.05) and (.description.font.features | test("tnum"))'
    local card="$d.updateCard"
    "${metric[@]}" 'Update1 staged: board 14'"'"'s update card under the text, inset $apex_update_card_padding_y $apex_update_card_padding_x, radius $apex_radius_update_card, gap $apex_update_card_gap, $apex_card ringed in $apex_card_border' \
        "$card.staged" '.below and (.padding.top | px_is($t.apex_update_card_padding_y)) and (.padding.left | px_is($t.apex_update_card_padding_x))
            and (.border.top | px_is("1px")) and (.radius | px_is($t.apex_radius_update_card)) and (.spacing | px_is($t.apex_update_card_gap))
            and (.background | colour_is($t.apex_card)) and (.borderColor | colour_is($t.apex_card_border))'
    "${metric[@]}" 'its system-software-update at $apex_update_card_icon_size, the board'"'"'s title at $apex_font_update_card_title_size, the versions at $apex_font_update_card_subtitle_size in $apex_fg_dim' \
        "$card.staged" '.icon.iconName == "system-software-update" and (.icon.size | px_is($t.apex_update_card_icon_size)) and (.textSpacing | px_is($t.apex_update_card_text_gap))
            and .title.text == "Start the new version next time" and (.title.font.size | px_is($t.apex_font_update_card_title_size))
            and .title.font.weight == ($t.apex_font_update_card_title_weight | tonumber) and (.title.foreground | colour_is($t.apex_fg))
            and .subtitle.text == "45.20261010.133 · GNOME 51.1, Linux 7.2.9, Mesa 26.1.2"
            and (.subtitle.font.size | px_is($t.apex_font_update_card_subtitle_size)) and (.subtitle.foreground | colour_is($t.apex_fg_dim))'
    "${metric[@]}" 'its switch is $apex_update_switch_width by $apex_update_switch_height, on in the accent, its knob $apex_update_switch_knob; Restart reads Restart & Update' \
        "{c: $card.staged, accent: .topBar.accent}" '.accent as $a | .c | (.toggle | .on and .sensitive and (.width | px_is($t.apex_update_switch_width))
            and (.height | px_is($t.apex_update_switch_height)) and (.background | colour_is($a)) and (.knob.width | px_is($t.apex_update_switch_knob)))
            and .buttons == ["Cancel", "Restart & Update"]'
    "${metric[@]}" 'ready-for-reboot: the same card, its switch on and insensitive, Restart & Update' \
        "$card.ready" '.below and .toggle.on and (.toggle.sensitive | not) and .buttons == ["Cancel", "Restart & Update"] and .title.text == "Start the new version next time"'
    "${metric[@]}" 'that switch draws at $apex_update_switch_insensitive_opacity, takes no focus and is unavailable to assistive technology; the staged one is whole' \
        "$card" '(.ready.toggle | (.opacity - ($t.apex_update_switch_insensitive_opacity | tonumber) | fabs < 0.01) and (.focusable | not) and (.a11ySensitive | not))
            and (.staged.toggle | .opacity == 1 and .focusable and .a11ySensitive)'
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
    "${metric[@]}" 'days of other months are $apex_calendar_other_month; today is the accent shaded $apex_quick_toggle_checked_shade with black, white at $apex_font_heading_weight' \
        "{d: $d, accent: .topBar.accent}" '(.accent | rgba) as $a | (.d.today.background | rgba) as $f | ($t.apex_quick_toggle_checked_shade | rtrimstr("%") | tonumber / 100) as $k
            | (.d.otherMonth.foreground | colour_is($t.apex_calendar_other_month)) and ([range(3)] | all(($f[.] - $a[.] * (1 - $k)) | fabs <= 1))
            and (.d.today | (.foreground | colour_is("#ffffff")) and .font.weight == ($t.apex_font_heading_weight | tonumber))'
    "${metric[@]}" 'every day number is drawn in its day'"'"'s colour: $apex_fg, weekends too, $apex_calendar_other_month in other months, white on today' \
        "$d" '(.day.ink | colour_is($t.apex_fg)) and (.weekend.ink | colour_is($t.apex_fg)) and (.otherMonth.ink | colour_is($t.apex_calendar_other_month))
            and (.today.ink | colour_is("#ffffff"))'
    "${metric[@]}" 'the events card is inset $apex_events_padding_top $apex_events_padding $apex_events_padding_bottom, its title $apex_font_events_title_size $apex_font_heading_weight in $apex_fg_dim' \
        "$d" "(.events | (.background | colour_is(\$t.apex_glass_card)) and (.radius | px_is(\$t.apex_radius_calendar))
            and ($inset | (.[0] | px_is(\$t.apex_events_padding_top)) and (.[1] | px_is(\$t.apex_events_padding)) and (.[2] | px_is(\$t.apex_events_padding_bottom))))
            and (.eventsTitle | (.font.size | px_is(\$t.apex_font_events_title_size)) and .font.weight == (\$t.apex_font_heading_weight | tonumber) and (.foreground | colour_is(\$t.apex_fg_dim)))"
    "${metric[@]}" 'Clocks and Weather are $apex_date_menu_button_height rows of $apex_glass_card ringed in $apex_glass_card_border, radius $apex_radius_date_menu_button, their text $apex_date_menu_button_padding in' \
        "$d" "[[.clocks, .clocksHeader], [.weather, .weatherHeader]] | all(.[0] != null and .[1] != null and (.[1].x - .[0].x | px_is(\$t.apex_date_menu_button_padding))
            and (.[0] | (.height | px_is(\$t.apex_date_menu_button_height)) and (.background | colour_is(\$t.apex_glass_card)) and (.borderColor | colour_is(\$t.apex_glass_card_border))
            and (.border.top | px_is(\$t.apex_surface_border)) and (.radius | px_is(\$t.apex_radius_date_menu_button))))"
    "${metric[@]}" 'Clocks sit $apex_date_menu_column_gap under the events card and Weather $apex_date_menu_button_gap under Clocks' \
        "$d" '(.clocks.y - .events.y - .events.height | px_is($t.apex_date_menu_column_gap)) and (.weather.y - .clocks.y - .clocks.height | px_is($t.apex_date_menu_button_gap))'
    "${metric[@]}" 'their headers are $apex_font_events_title_size $apex_font_label_weight in $apex_fg_dim, set up or not' \
        "$d" "[.clocksHeader, .weatherHeader] | all(. != null and (.font.size | px_is(\$t.apex_font_events_title_size)) and .font.weight == (\$t.apex_font_label_weight | tonumber)
            and (.foreground | colour_is(\$t.apex_fg_dim)))"
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
        "overview: and drawn at that scale of the work area (116 x 70 on 1440 x 900)" APEXG2-SCENES
    expect_report "$label" "$log" "$o.workspace | .background == false and .empty.visible and .empty.text == \"$EMPTY_WORKSPACE_TEXT\"
        and (.x + .width / 2 - .empty.x - .empty.width / 2 | fabs <= 1) and (.y + .height / 2 - .empty.y - .empty.height / 2 | fabs <= 1)" \
        "overview: no workspace background card, and \"$EMPTY_WORKSPACE_TEXT\" centred on the empty workspace" APEXG2-SCENES
    top_bar_metric "$label overview" "$scenes" "$tokens" 'the empty-workspace label is $apex_font_workspace_empty_size $apex_font_heading_weight in $apex_overview_fg_dim' \
        "$o.workspace.empty" '(.font.size | px_is($t.apex_font_workspace_empty_size)) and .font.weight == ($t.apex_font_heading_weight | tonumber) and (.foreground | colour_is($t.apex_overview_fg_dim))'
    local w=.surfaces.overviewWindows
    expect_report "$label" "$log" "$w | . as \$o | (.previews | length) == $OVERVIEW_WINDOWS and .dock != null and all(.previews[]; .caption.visible)
        and ([range(0; .previews | length) as \$i | .previews[\$i].caption as \$c
            | ([.previews | to_entries[] | select(.key != \$i) | .value.window, .value.caption] + [\$o.dock])[]
            | select(\$c.x < .x + .width and .x < \$c.x + \$c.width and \$c.y < .y + .height and .y < \$c.y + \$c.height)] | length == 0)" \
        "overview with $OVERVIEW_WINDOWS windows: every caption shown, none over another window's preview, another caption or the dock" APEXG2-SCENES
    top_bar_metric "$label overview" "$scenes" "$tokens" 'and the last row'"'"'s captions end $apex_dock_bottom_gap or more above the dock' \
        "$w" '([.previews[].caption | .y + .height] | max) <= .dock.y - ($t.apex_dock_bottom_gap | px) + 0.5'
    top_bar_metric "$label overview" "$scenes" "$tokens" 'board 35: each window preview is $apex_radius_window_preview round and draws two layers on its own box, 0 $apex_preview_shadow_y $apex_preview_shadow_blur $apex_preview_shadow and 0 $apex_preview_shadow_2_y $apex_preview_shadow_2_blur $apex_preview_shadow_2' \
        "$w.previews" "length == $OVERVIEW_WINDOWS"' and all(.styled and .radius == ($t.apex_radius_window_preview | px)
            and (.layers | length == 2 and all(.shown and .box == .surfaceBox and .radius == ($t.apex_radius_window_preview | px))
            and (.[0].boxShadow | (.y | px_is($t.apex_preview_shadow_y)) and (.blur | px_is($t.apex_preview_shadow_blur)) and (.color | colour_is($t.apex_preview_shadow)))
            and (.[1].boxShadow | (.y | px_is($t.apex_preview_shadow_2_y)) and (.blur | px_is($t.apex_preview_shadow_2_blur)) and (.color | colour_is($t.apex_preview_shadow_2)))))'
    top_bar_metric "$label overview" "$scenes" "$tokens" 'the workspace-bottom hook takes the dock box'"'"'s live height and $apex_dock_bottom_gap off the monitor'"'"'s bottom' \
        "$w" '.bottom.hook == .bottom.stock - .dockBox.height - ($t.apex_dock_bottom_gap | px)'
    expect_report "$label" "$log" "$w.thumbnails | length >= 2 and all(.[]; .spread >= $OVERVIEW_THUMBNAIL_MIN_SPREAD)" \
        "overview: every workspace thumbnail draws the wallpaper, not a flat fill (luminance spread $OVERVIEW_THUMBNAIL_MIN_SPREAD or more over its centre)" APEXG2-SCENES
    expect_report "$label" "$log" ".surfaces.appGrid.grid == {columns: $LAUNCHER_COLUMNS, rows: $LAUNCHER_ROWS, iconSize: $LAUNCHER_ICON_SIZE}" \
        "launcher: $LAUNCHER_COLUMNS columns of $LAUNCHER_ICON_SIZE px icons, $LAUNCHER_ROWS rows a page" APEXG2-SCENES
    top_bar_metric "$label overview" "$scenes" "$tokens" "launcher: no workspace strip; the grid starts at the work area + \$apex_search_top + \$apex_search_height + $STOCK_SEARCH_MARGIN_BOTTOM + twice the spacing, board 36's $LAUNCHER_GRID_TOP px" \
        "{g: .surfaces.appGrid, wa: .scenes.overview.workArea}" "(.wa.y + (\$t.apex_search_top | px) + (\$t.apex_search_height | px) + $STOCK_SEARCH_MARGIN_BOTTOM
            + 2 * (.wa.height * $OVERVIEW_SPACING_RATIO | round)) as \$top | .g.strip == 0 and (.g.box.y - \$top | fabs) <= 1 and \$top == $LAUNCHER_GRID_TOP"
}

# Boards 34 to 36 as laid out: what the style checks above read from the theme, measured on the allocations.
# shellcheck disable=SC2016 # jq programs and token names, not shell expansions
surface_metrics() {
    local label=$1 log=$2 variant=$3 scenes tokens
    scenes=$(report_of "$log" APEXG2-SCENES)
    tokens=$(tokens_for "$variant")
    local -a metric=(top_bar_metric "$label surface metrics" "$scenes" "$tokens")
    local n=.surfaces.notificationsLayer

    "${metric[@]}" 'a notification card: its $apex_message_icon_size icon $apex_message_padding_start in and $apex_message_padding down, the header'"'"'s column $apex_banner_gap past it' \
        "$n.layout.collapsed" '(.icon | (.width | px_is($t.apex_message_icon_size)) and (.height | px_is($t.apex_message_icon_size)))
            and (.icon.x - .card.x | px_is($t.apex_message_padding_start)) and (.icon.y - .card.y | px_is($t.apex_message_padding))
            and (.header.x - .icon.x - .icon.width | px_is($t.apex_banner_gap))'
    "${metric[@]}" 'and its $apex_banner_close_size close button $apex_message_padding_end in from the right, $apex_message_padding down' \
        "$n.layout.collapsed" '(.close | (.width | px_is($t.apex_banner_close_size)) and (.height | px_is($t.apex_banner_close_size)))
            and (.card.x + .card.width - .close.x - .close.width | px_is($t.apex_message_padding_end)) and (.close.y - .card.y | px_is($t.apex_message_padding))'
    "${metric[@]}" 'the footer is $apex_date_menu_footer_height tall: Do Not Disturb $apex_date_menu_footer_padding in from the left, the $apex_clear_button_height Clear $apex_date_menu_footer_padding in from the right, centred' \
        "$n" '(.footer.height | px_is($t.apex_date_menu_footer_height)) and (.dnd.x - .footer.x | px_is($t.apex_date_menu_footer_padding))
            and (.clear.height | px_is($t.apex_clear_button_height)) and (.footer.x + .footer.width - .clear.x - .clear.width | px_is($t.apex_date_menu_footer_padding))
            and (.clear.y + .clear.height / 2 - .footer.y - .footer.height / 2 | fabs <= 1)'
    "${metric[@]}" 'the current workspace'"'"'s $apex_thumbnail_indicator accent ring hugs its thumbnail, neither casting a shadow; the next thumbnail $apex_thumbnail_gap on' \
        "{o: .surfaces.overview, w: .surfaces.overviewWindows.thumbnails}" '($t.apex_thumbnail_indicator | px) as $r | .o.thumbnail as $th
            | (.o.indicator | .x == $th.x - $r and .y == $th.y - $r and .width == $th.width + 2 * $r and .height == $th.height + 2 * $r and .boxShadow == null)
            and $th.boxShadow == null and (.w[1].x - .w[0].x - .w[0].width | px_is($t.apex_thumbnail_gap))'
    "${metric[@]}" 'Do Not Disturb: its label, then the stock switch $apex_dnd_switch_gap after it, centred down the row' \
        "$n.dnd" '.labelBox.x < .switch.x and (.switch.x - .labelBox.x - .labelBox.width - ($t.apex_dnd_switch_gap | px) | fabs <= 1)
            and (.switch.y + .switch.height / 2 - .y - .height / 2 | fabs <= 1)'
    "${metric[@]}" "every caption hangs stock's $STOCK_CAPTION_GAP px under its window's preview, \$apex_caption_height tall" \
        '.surfaces.overviewWindows.previews' "length > 0 and all(.[]; (.caption.y - .window.y - .window.height - $STOCK_CAPTION_GAP | fabs <= 1)
            and (.caption.height - (\$t.apex_caption_height | px) | fabs <= 1))"
    "${metric[@]}" "the launcher lays its tiles at its grid's own pitch, tile plus spacing, $LAUNCHER_COLUMNS columns centred on the monitor, a full row's next one under it" \
        "{a: .surfaces.appGrid, w: .topBar.panel.width}" "(.a.spacing | .tile + .h) as \$dx | (.a.spacing | .tile + .v) as \$dy | .a.spacing.tile as \$tile
            | .a.tiles as \$r | (\$r | length) >= 2 and ([\$r[:$LAUNCHER_COLUMNS][].y] | unique | length) == 1
            and all(range([\$r | length, $LAUNCHER_COLUMNS] | min); . as \$i | \$r[\$i] | (.x - \$r[0].x - \$i * \$dx | fabs <= 1) and (.width - \$tile | fabs <= 1))
            and (2 * \$r[0].x + $((LAUNCHER_COLUMNS - 1)) * \$dx + \$tile - .w | fabs <= 1)
            and ((\$r | length) <= $LAUNCHER_COLUMNS or (\$r[$LAUNCHER_COLUMNS] | (.x - \$r[0].x | fabs <= 1) and (.y - \$r[0].y - \$dy | fabs <= 1)))"
    "${metric[@]}" 'the launcher'"'"'s pill is $apex_search_height tall, centred, $apex_search_top below the bar; its scrim the overview'"'"'s $apex_scrim' \
        "{p: .surfaces.launcher.pill, bar: .topBar.panel, scrim: .surfaces.appGrid.scrim}" '(.p.height | px_is($t.apex_search_height)) and (.p.y - .bar.height | px_is($t.apex_search_top))
            and (.p.x + .p.width / 2 - .bar.width / 2 | fabs <= 1) and (.scrim.background | colour_is($t.apex_scrim)) and .scrim.boxShadow == null'
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
    "${metric[@]}" 'inside that border the glass actor is rounded $apex_radius_tile_preview, filled with the accent at $apex_tile_preview_fill_opacity and ringed by a $apex_tile_preview_ring border in the accent at $apex_tile_preview_ring_opacity; the classed preview draws neither' \
        "{p: $tp.preview, g: $tp.glass, accent: .topBar.accent}" "$tinted"' .accent as $a | (.p | (.radius - .border.top | px_is($t.apex_radius_tile_preview))
            and (.styleClass | split(" ") | index("apex-tile-preview-glassed") != null) and (.background | rgba | .[3] == 0) and .boxShadow == null)
            and (.g | (.radius | px_is($t.apex_radius_tile_preview)) and (.background | tinted($a; $t.apex_tile_preview_fill_opacity))
            and (.border | [.top, .right, .bottom, .left] | all(px_is($t.apex_tile_preview_ring))) and (.borderColor | tinted($a; $t.apex_tile_preview_ring_opacity)))'
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
        "$k" ".settings.askedMs < .early.ms and .early.ms < .settings.askedMs + .budgetMs and (.early | $shown)
            and .early.selected == \"Applications/org.gnome.DiskUtility.desktop\""
    "${metric[@]}" 'past the budget, Settings is cancelled and left out; after the cancel, Applications and Files still show' \
        "$k" ".settings.cancelledMs >= .settings.askedMs + .budgetMs and .settings.cancelledMs < .late.ms and .late.ms < .settings.askedMs + .slowMs and (.late | $shown)"
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

# With safe, also each scene of safe mode against Fedora's.
compare_with_fedora() {
    local run=$1 safe=${2:-} scene plan=$1/compare/fedora-plan.json results=$1/compare/fedora-results.json
    mkdir -p "$run/compare"
    {
        # The Apex bar is $apex_bar_height, upstream's 2.2em: the overview below it lays out on
        # another work area, so overview_below_bar checks its layout instead.
        plan_entry apex-light-vs-fedora-desktop "$run" fedora-light "$run" no-dock desktop "$run/compare" panel
        plan_entry apex-dark-vs-fedora-desktop "$run" fedora-dark "$run" no-dock-dark desktop "$run/compare" panel
        for scene in "${SCENES[@]}"; do
            [[ $safe == safe ]] || break
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
    fedora=$(report_of "$run/fedora-light.log" | jq -r '.highContrastSheet.sha256BeforeStructure // empty')
    expect_report fedora-light "$run/fedora-light.log" '.highContrastSheet.structure == false' \
        "Fedora's high-contrast sheet has no Apex structure marker"
    expect_report stock-light "$run/stock-light.log" \
        ".highContrastSheet | .structure and .sha256BeforeStructure == \"${fedora:-none}\"" \
        "the rebuilt high-contrast sheet, which safe mode keeps (it has no stock copy), is Fedora's up to the structure marker: Apex only appends"
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
    # shellcheck disable=SC2016 # jq programs and token names, not shell expansions
    top_bar_metric "$label" "$toggled" "$(tokens_for light)" 'the calendar built in the dark restyles: its day numbers draw in the light $apex_fg, $apex_calendar_other_month in other months, white on today' \
        '.calendar' '(.day.ink | colour_is($t.apex_fg)) and (.otherMonth.ink | colour_is($t.apex_calendar_other_month)) and (.today.ink | colour_is("#ffffff"))'
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
        expect "fixtures ($part)" "$fixtures" '.gpus | .hasDualGpu and .names == ["AMD Radeon Graphics", "NVIDIA GeForce RTX 3050 Laptop GPU"]' \
            "switcheroo-control: an integrated and a discrete GPU"
        expect "fixtures ($part)" "$fixtures" '.accounts | .appsFiltered == [false, []] and .sessionLimit == 0' \
            "accountsservice: the user's parental controls filter no app and limit no session"
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

# shellcheck disable=SC2016 # jq programs
A11Y_SURFACE='(getpath($path | split("."))) as $s
    | if $s == null then ["not measured"] elif $s.error then ["error: \($s.error)"]
      elif ($s.targets | length) == 0 then ["no text or glyph found"] else empty end'
# shellcheck disable=SC2016 # jq programs
A11Y_INACTIVE_DOT='(.kind == "dot" and .name == "workspace-dot" and .alpha < 1)'
# shellcheck disable=SC2016 # jq programs
A11Y_LOW_CONTRAST='[.targets[] | select((.inactive | not) and (.offscreen | not) and (.ratio < (if .kind == "text" then $text else $icon end))
        and (($gapdot and '"$A11Y_INACTIVE_DOT"') | not))
    | "\(.kind) \(.name | tojson) \(.ink) at \(.alpha) on \(.backdrop): \(.ratio)"]'
# shellcheck disable=SC2016 # jq programs
A11Y_LAYOUT='.box as $root | [.targets[] | select(.kind == "text" and (.offscreen | not)) as $t
    | if $t.ellipsized and ($t.expandable | not) then "\($t.name | tojson) is cut short"
      elif $t.box.x < $m.x - 1 or $t.box.y < $m.y - 1 or $t.box.x + $t.box.width > $m.x + $m.width + 1
          or $t.box.y + $t.box.height > $m.y + $m.height + 1 then "\($t.name | tojson) leaves the screen"
      elif $t.box.x < $root.x - 1 or $t.box.y < $root.y - 1 or $t.box.x + $t.box.width > $root.x + $root.width + 1
          or $t.box.y + $t.box.height > $root.y + $root.height + 1 then "\($t.name | tojson) leaves its surface"
      else empty end]
    + [[.targets[] | select(.kind == "text" and (.offscreen | not))] | . as $a | range(0; length) as $i | range($i + 1; length) as $j | [$a[$i], $a[$j]]
      | select(.[0].card == .[1].card and .[0].box.x < .[1].box.x + .[1].box.width - 1 and .[1].box.x < .[0].box.x + .[0].box.width - 1
          and .[0].box.y < .[1].box.y + .[1].box.height - 1 and .[1].box.y < .[0].box.y + .[0].box.height - 1)
      | "\(.[0].name | tojson) overlaps \(.[1].name | tojson)"] | unique'

a11y_verdict() {
    local desc=$1 problems=$2
    if [[ -z $problems ]]; then pass "$desc"; else fail "$desc (${problems:0:600})"; fi
}

# Apex's own gap, not upstream's: workspace-dots.js draws an inactive dot at opacity .45, under
# WCAG 1.4.11's 3:1 over the light backdrops. Each backdrop's ratio today, which may not fall.
readonly A11Y_INACTIVE_DOT_GAP="the owner's decision on the inactive workspace dot's .45 opacity (2026-10-27)"
declare -Ar A11Y_INACTIVE_DOT_TODAY=([default]=2.86 [default-solid]=2.22 [dark-style]=4.24 [dark-style-solid]=3.55
    [high-contrast]=4.37 [high-contrast-solid]=4.37 [no-dock:bar.overview]=2.58 [no-dock:bar.desktop]=2.32)

# Whether the inactive dot is under 3:1 over the label's backdrop today: the gap holds it apart.
inactive_dot_gap() {
    local today=${A11Y_INACTIVE_DOT_TODAY[$1]:-}
    [[ -n $today ]] && jq -en "$today < $A11Y_ICON_RATIO" >/dev/null
}

# The inactive workspace dots of the surface at path: today's ratio or better, and, while the
# gap is open, still under 3:1, so the gap goes once the fix lands.
inactive_dot() {
    local label=$1 report=$2 path=$3 key=$4 today=${A11Y_INACTIVE_DOT_TODAY[$4]:-}
    local -a metric=(top_bar_metric "$label accessibility" "$report" '{}')
    local dots="getpath(\"$path\" | split(\".\")) | [.targets[]? | select($A11Y_INACTIVE_DOT) | .ratio]"
    if [[ -z $today ]]; then
        fail "$label accessibility: $path: no inactive-dot ratio recorded for $key"
        return
    fi
    "${metric[@]}" "$path: the inactive workspace dots are at least today's $today:1" "$dots" "length > 0 and all(. >= $today)"
    inactive_dot_gap "$key" || return 0
    known_gap "$A11Y_INACTIVE_DOT_GAP" "${metric[@]}" "$path: the inactive workspace dots are at $A11Y_ICON_RATIO:1 (WCAG 1.4.11)" \
        "$dots" "length > 0 and all(. >= $A11Y_ICON_RATIO)"
}

# Board 39's pills: the chip's and the timer's text at 4.5:1, the share's and the privacy group's glyphs
# at 3:1, and a pill Apex fills against the bar at 3:1; upstream's high-contrast sheet fills the button instead.
readonly A11Y_PILL_PARTS=(input:text recording:text sharing:icon privacy:icon recording:edge sharing:edge privacy:edge)
readonly A11Y_PILL_GAP="the owner's decision on board 39's pill fills over #013b88 (2026-10-31)"
readonly A11Y_PILL_HC_GAP="upstream HC sheet: the screen-sharing glyph, white on its #ff7800 fill (2.54:1)"
# Each part under WCAG AA today, at the report's own rounding: a lower one fails.
declare -Ar A11Y_PILL_TODAY=([default-solid:recording:edge]=2.02 [default-solid:sharing:edge]=1.62 [default-solid:privacy:edge]=1.62
    [dark-style-solid:recording:edge]=2.13 [dark-style-solid:sharing:edge]=2.65 [dark-style-solid:privacy:edge]=2.65
    [high-contrast:sharing:icon]=2.54 [high-contrast-solid:sharing:icon]=2.54)

# A pill part's worst ratio in an APEXG2-A11Y report, or nothing when it was not measured.
pill_ratio() {
    local report=$1 pill=${2%:*} part=${2#*:}
    if [[ $part == edge ]]; then
        jq -r --arg p "$pill" '.barPills.pills[$p].edge.ratio // empty' <<<"$report" 2>/dev/null
    else
        jq -r --arg p "$pill" --arg k "$part" \
            '[.barPills.pills[$p].targets[]? | select(.kind == $k and (.offscreen | not)) | .ratio] | min // empty' <<<"$report" 2>/dev/null
    fi
}

pill_verdict() {
    local desc=$1 worst=$2 threshold=$3
    if jq -en "$worst >= $threshold" >/dev/null; then pass "$desc"; else fail "$desc ($worst:1)"; fi
}

# Each pill part at its threshold, or, pinned, at least today's ratio and still a gap.
bar_pills() {
    local label=$1 report=$2 p worst threshold today desc gap=$A11Y_PILL_GAP
    local -A part_desc=([text]="text over what is drawn behind it" [icon]="glyphs over its fill" [edge]="fill against the bar beside it")
    local -A part_noun=([text]=text [icon]=glyphs [edge]=fill)
    [[ $label == high-contrast* ]] && gap=$A11Y_PILL_HC_GAP
    for p in "${A11Y_PILL_PARTS[@]}"; do
        [[ $label == high-contrast* && $p == *:edge ]] && continue
        threshold=$A11Y_ICON_RATIO
        [[ $p == *:text ]] && threshold=$A11Y_TEXT_RATIO
        desc="$label accessibility: barPills: the ${p%:*} pill's ${part_desc[${p#*:}]} at $threshold:1"
        worst=$(pill_ratio "$report" "$p")
        if [[ -z $worst ]]; then
            fail "$desc (not measured)"
            continue
        fi
        today=${A11Y_PILL_TODAY[$label:$p]:-}
        if [[ -z $today ]]; then
            pill_verdict "$desc" "$worst" "$threshold"
            continue
        fi
        pill_verdict "$label accessibility: barPills: the ${p%:*} pill's ${part_noun[${p#*:}]} is at least today's $today:1" "$worst" "$today"
        known_gap "$gap" pill_verdict "$desc" "$worst" "$threshold"
    done
}

# The text below 4.5:1 and the glyphs and dots below 3:1 in a report's surface at path; with gapdot
# true, the inactive workspace dots are left to inactive_dot.
a11y_low_contrast() {
    local report=$1 path=$2 gapdot=${3:-false}
    jq -r --arg path "$path" --argjson text "$A11Y_TEXT_RATIO" --argjson icon "$A11Y_ICON_RATIO" --argjson gapdot "$gapdot" \
        "[$A11Y_SURFACE] as \$e | if (\$e | length) > 0 then \$e else (getpath(\$path | split(\".\")) | $A11Y_LOW_CONTRAST) end | join(\"; \")" \
        <<<"$report" 2>&1
}

# Each surface's text at 4.5:1 and glyphs at 3:1, against the pixels the stage drew behind them.
a11y_contrast() {
    local label=$1 log=$2 report s gapdot=false
    report=$(report_of "$log" APEXG2-A11Y)
    if [[ -z $report ]]; then
        fail "$label accessibility: no APEXG2-A11Y report"
        return
    fi
    inactive_dot_gap "$label" && gapdot=true
    for s in "${A11Y_SURFACES[@]}"; do
        known_gap "${A11Y_GAPS[$label:$s]:-}" a11y_verdict "$label accessibility: $s: text $A11Y_TEXT_RATIO:1 and glyphs $A11Y_ICON_RATIO:1 against what is drawn behind them" \
            "$(a11y_low_contrast "$report" "$s" "$([[ $s == bar* ]] && echo "$gapdot" || echo false)")"
    done
    for s in bar barUnread; do
        inactive_dot "$label" "$report" "$s" "$label"
    done
    bar_pills "$label" "$report"
    expect "$label accessibility" "$report" '.wifiMenuConnected.targets | any(.kind == "text" and (.inactive | not))' \
        "the connected network's name is measured over its row's own fill"
    expect "$label accessibility" "$report" '(.bar.targets | map(select(.kind == "dot" and .name == "workspace-dot")) | length >= 2)
        and (.barUnread.targets | any((.kind == "dot" and .name == "messages-indicator") or (.kind == "icon" and .name == "message-indicator-symbolic")))' \
        "the bar's workspace dots and the clock's unread dot (upstream's glyph in high contrast) are measured as glyphs"
}

# The bar over the overview's fixture wallpaper, in the overview and on the desktop.
bar_over_fixture() {
    local label=$1 log=$2 report s
    report=$(report_of "$log" APEXG2-OVERVIEW-WINDOWS)
    if [[ -z $report ]]; then
        fail "$label accessibility: no APEXG2-OVERVIEW-WINDOWS report"
        return
    fi
    for s in bar.overview bar.desktop; do
        a11y_verdict "$label accessibility: $s over the fixture wallpaper: text $A11Y_TEXT_RATIO:1 and glyphs $A11Y_ICON_RATIO:1 against what is drawn behind them" \
            "$(a11y_low_contrast "$report" "$s" "$(inactive_dot_gap "$label:$s" && echo true || echo false)")"
        inactive_dot "$label" "$report" "$s" "$label:$s"
    done
}

# Large Text: each surface's text whole, on the screen, inside its surface and clear of the rest.
a11y_layout() {
    local label=$1 log=$2 report s problems
    report=$(report_of "$log" APEXG2-A11Y)
    expect "$label accessibility" "$report" '.textScalingFactor == 1.25' "text-scaling-factor is 1.25"
    for s in "${A11Y_SURFACES[@]}"; do
        problems=$(jq -r --arg path "$s" \
            ".monitor as \$m | [$A11Y_SURFACE] as \$e | if (\$e | length) > 0 then \$e else (getpath(\$path | split(\".\")) | $A11Y_LAYOUT) end | join(\"; \")" \
            <<<"$report" 2>&1)
        known_gap "${A11Y_GAPS[$label:$s]:-}" a11y_verdict "$label accessibility: $s: no text cut short, off the screen, outside its surface or overlapping" "$problems"
    done
}

# The light and dark captures, high contrast and Large Text, each with its own shell, over the
# Facets and again over the solid stress backdrop.
a11y_cases() {
    local run=$1 c backdrop
    for c in high-contrast large-text default-solid dark-style-solid high-contrast-solid large-text-solid; do
        exits "$run" "$c" 0
        no_js_error "$c" "$run/$c.log"
        no_apex_failure "$c" "$run/$c.log"
    done
    for backdrop in '' -solid; do
        a11y_contrast "default$backdrop" "$run/default$backdrop.log"
        a11y_contrast "dark-style$backdrop" "$run/dark-style$backdrop.log"
        a11y_contrast "high-contrast$backdrop" "$run/high-contrast$backdrop.log"
        a11y_layout "large-text$backdrop" "$run/large-text$backdrop.log"
    done
}

# The backdrop direct.sh pinned, as the probe found it painted: a case over another one, or
# over none, measures its contrast against chance.
backdrop_painted() {
    local label=$1 log=$2 want=facets-light report
    case $label in
        *-solid) want=$SOLID_BACKDROP ;;
        *dark*) want=facets-dark ;;
    esac
    report=$(report_of "$log" APEXG2-BACKDROP)
    if [[ -z $report ]]; then
        fail "$label: the $want backdrop painted (no APEXG2-BACKDROP report)"
    elif jq -e --arg want "$want" '.error == null and .expected == $want' <<<"$report" >/dev/null 2>&1; then
        pass "$label: the $want backdrop painted"
    else
        fail "$label: the $want backdrop painted ($(jq -r '.error // "the probe expected \(.expected)"' <<<"$report" 2>&1 | head -c 400))"
    fi
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
idle_window() {
    local r=$1 at=$2 what=$3 offenders sources
    offenders=$(jq -r "[$at.frames[] | \"at \\(.atMs) ms, \\(.damage.rectangles) rectangle(s) in \\(.damage.extents | \"\\(.x),\\(.y) \\(.width)x\\(.height)\") under \\(.damage.under | map(join(\" < \")) | join(\" | \"))\"] | join(\"; \")" <<<"$r" 2>/dev/null)
    sources=$(jq -r "[$at.frames[].damage.under[][]] | join(\" < \")" <<<"$r" 2>/dev/null | apex_sources)
    if jq -e "$at.afterPaints == 0 and $at.frames == []" <<<"$r" >/dev/null 2>&1; then
        pass "idle: over ${IDLE_WINDOW_MS} ms of $what the stage paints no frame"
    else
        fail "idle: over ${IDLE_WINDOW_MS} ms of $what the stage paints no frame ($(jq -r "$at.afterPaints" <<<"$r" 2>/dev/null) painted: ${offenders:-none recorded}${sources:+; from $sources})"
    fi
}

# shellcheck disable=SC2016 # jq programs
idle_desktop() {
    local run=$1 f=$1/idle.log r error feature relayouts
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
    expect idle "$r" '.settled.actionMode == "NORMAL"' "and settleDesktop left the NORMAL action mode"
    idle_window "$r" .idle "an idle desktop"
    idle_window "$r" .quickSettings "the desktop with Quick Settings open"
    idle_window "$r" .reduceTransparency.idle "an idle desktop with Reduce Transparency"
    idle_window "$r" .reduceTransparency.quickSettings "Quick Settings open with Reduce Transparency"
    relayouts=$(jq -r '.idle.relayouts | to_entries | map("\(.key) x\(.value)") | join("; ")' <<<"$r" 2>/dev/null)
    if jq -e '.idle.relayouts == {}' <<<"$r" >/dev/null 2>&1; then
        pass "idle: and no actor queues a relayout"
    else
        fail "idle: and no actor queues a relayout (${relayouts:-unreadable}$(apex_sources <<<"$relayouts" | sed 's/^./; from &/'))"
    fi
    expect idle "$r" '.overview | .shown and .wallpapers >= 2 and .idle.afterPaints == 0 and .idle.frames == [] and .idle.relayouts == {}' \
        "over ${IDLE_WINDOW_MS} ms of the open overview, its thumbnails drawing the wallpaper, the stage paints no frame and queues no relayout"
    expect idle "$r" '.control.afterPaints > 0 and (.control.frames | length > 0)' \
        "the control: opening Quick Settings in a window of the same counter paints frames"
    expect idle "$r" '.control.frames | length > 0 and all(.damage.extents.width > 0 and .damage.extents.height > 0 and (.damage.under | length > 0))' \
        "and each of its frames names its damage and the actors under it, as a failure would"
}

# shellcheck disable=SC2016 # jq programs
glass_load_scenario() {
    local r=$1 s=$2 at=".scenarios.$2" missed empty surfaces trace
    missed=$(jq -r "[$at.glass.missed[] | \"\\(.surface) at \\(.atMs) ms (\\(.overlap))\"] | join(\"; \")" <<<"$r" 2>/dev/null)
    if jq -e "$at.glass.contentFrames > 0 and $at.glass.missed == []" <<<"$r" >/dev/null 2>&1; then
        pass "glass-load $s: every change under a glass box re-blurs that box in the same frame (forwarded damage)"
    else
        fail "glass-load $s: every change under a glass box re-blurs that box in the same frame (forwarded damage) (missed: ${missed:-no content frame})"
    fi
    empty=$(jq -r "[$at.glass.surfaces | to_entries[] | select((.value.empty // 0) > 0) | \"\\(.key) in \\(.value.empty)\"] | join(\", \")" <<<"$r" 2>/dev/null)
    if jq -e "[$at.glass.surfaces[] | .empty // 0] | add // 0 | . == 0" <<<"$r" >/dev/null 2>&1; then
        pass "glass-load $s: every glass box draws at its size, in its first frame too"
    else
        fail "glass-load $s: every glass box draws at its size, in its first frame too (empty: $empty frames)"
    fi
    expect "glass-load $s" "$r" "$at.reduceTransparency.surfaces == {} and $at.reduceTransparency.contentFrames > 0" \
        "with Reduce Transparency the same scenario runs and no glass is live"
    surfaces=$(jq -r "$at.glass.surfaces | to_entries | map(\"\\(.key) \\(.value.reblurs) re-blurs/\\(.value.partial) partial/\\(.value.contentUnder) under\") | join(\", \")" <<<"$r" 2>/dev/null)
    trace=$(jq -r "[$at.glass.trace[:6][] | \"\\(.clip | if . then \"\\(.x),\\(.y) \\(.width)x\\(.height)\" else \"none\" end): \\(.overlap | to_entries | map(\"\\(.key) \\(.value)\") | join(\" \"))\"] | join(\" / \")" <<<"$r" 2>/dev/null)
    echo "# glass-load $s: modelled glass cost $(jq -r "$at.glass.modelledMsPerFrame" <<<"$r" 2>/dev/null) ms per frame (0014-blurcost.py's model, report only); ${surfaces:-no glass}"
    [[ $s == C ]] && return
    if jq -e "($at.glass.frames / $at.glass.contentFrames) <= ($at.reduceTransparency.frames / $at.reduceTransparency.contentFrames) * $GLASS_EXTRA_FRAMES_RATIO" <<<"$r" >/dev/null 2>&1; then
        pass "glass-load $s: glass adds at most 1 % frames over Reduce Transparency, per change under it"
    else
        fail "glass-load $s: glass adds at most 1 % frames over Reduce Transparency, per change under it ($(jq -r "\"\\($at.glass.frames)/\\($at.glass.contentFrames) against \\($at.reduceTransparency.frames)/\\($at.reduceTransparency.contentFrames)\"" <<<"$r" 2>/dev/null); ${surfaces}; first clips: ${trace})"
    fi
}

# shellcheck disable=SC2016 # jq programs
glass_load() {
    local run=$1 f=$1/glass-load.log r error
    exits "$run" glass-load 0
    no_apex_failure glass-load "$f"
    r=$(report_of "$f" APEXG2-GLASS-LOAD)
    error=$(jq -r '.error // empty' <<<"$r" 2>/dev/null)
    if [[ -n $error ]]; then
        fail "glass-load: ${error%%$'\n'*}"
        return
    fi
    glass_load_scenario "$r" A
    expect "glass-load A" "$r" '.scenarios.A.glass.surfaces | (.panel.reblurs // 0) == 0 and .dock.reblurs == .dock.contentUnder and .dock.contentUnder > 0 and ((."quick-settings".reblurs // 0) == (."quick-settings".contentUnder // 0))' \
        "a glass box re-blurs exactly when the video changes under it: the dock each time, Quick Settings and the bar never"
    glass_load_scenario "$r" B
    expect "glass-load B" "$r" ".scenarios.B.glass.surfaces | (.panel.reblurs // 0) <= $GLASS_B_MENU_TOGGLES and .dock.contentUnder > 0 and .\"quick-settings\".contentUnder > 0 and .calendar.contentUnder > 0" \
        "the window passes under the dock, Quick Settings and the calendar, and the bar, which it never passes under, re-blurs at most once per open or close of a bar menu ($GLASS_B_MENU_TOGGLES; got $(jq -r '.scenarios.B.glass.surfaces.panel.reblurs // 0' <<<"$r" 2>/dev/null))"
    glass_load_scenario "$r" C
}

# shellcheck disable=SC2016 # jq programs
glass_stress() {
    local run=$1 f=$1/glass-stress.log synthetic real
    exits "$run" glass-stress 0
    no_apex_failure glass-stress "$f"
    synthetic=$(report_of "$f" APEXG2-GLASS)
    real=$(report_of "$f" APEXG2-GLASS-LOAD-STRESS)
    expect glass-stress "$synthetic" ".patched and .stress.seconds >= $GLASS_STRESS_MIN_SECONDS and .stress.frames > 0 and .stress.clipped > 0 and .stress.compared > 0" \
        "the synthetic box's stress ran $(jq -r '.stress.seconds // "?"' <<<"$synthetic" 2>/dev/null) s (at least $GLASS_STRESS_MIN_SECONDS), with clipped frames and compared ones"
    expect glass-stress "$synthetic" '.stress.black == 0 and .stress.stale == 0 and .stress.unequal == 0' \
        "no black frame, no stale one, and each compared frame equals a full redraw"
    expect glass-stress "$real" ".seconds >= $GLASS_STRESS_MIN_SECONDS and .frames > 0 and .contentFrames > 0" \
        "the real boxes' stress ran $(jq -r '.seconds // "?"' <<<"$real" 2>/dev/null) s: a video under the dock and Quick Settings"
    expect glass-stress "$real" '.missed == []' \
        "and every change under a glass box re-blurred that box in the same frame"
}

# shellcheck disable=SC2016 # jq programs
dock_pin() {
    local run=$1 f=$1/dock-pin.log r error offenders sources
    exits "$run" dock-pin 0
    no_apex_failure dock-pin "$f"
    r=$(report_of "$f" APEXG2-DOCK-PIN)
    error=$(jq -r '.error // empty' <<<"$r" 2>/dev/null)
    if [[ -n $error ]]; then
        fail "dock-pin: ${error%%$'\n'*}"
        return
    fi
    expect dock-pin "$r" '.settled | (.startingUp | not) and (.overview | not) and .dock.visible' \
        "the session settled: startup over, no overview, the dock shown"
    expect dock-pin "$r" '.settled.actionMode == "NORMAL"' "and settleDesktop left the NORMAL action mode"
    expect dock-pin "$r" '.pinned as $p | ($p != null) and (.dockApps | index($p) != null) and .dockUpdate.afterPaints > 0' \
        "a pinned favourite ($(jq -r '.pinned // "none"' <<<"$r" 2>/dev/null)) shows in the dock at once"
    expect dock-pin "$r" ".windowMs.dockUpdate + .windowMs.fallback > $DOCK_PIN_FALLBACK_MS" \
        "the windows run past main.js's ${DOCK_PIN_FALLBACK_MS} ms fallback for deferred work after the pin"
    echo "# dock-pin: main.js's fallback fired at $(jq -r '.fallbackFiredMs | if length > 0 then map("\(.) ms") | join(", ") else "no time" end' <<<"$r" 2>/dev/null) after the pin (report only)"
    offenders=$(jq -r '[.fallback.frames[] | "at \(.atMs) ms, \(.damage.rectangles) rectangle(s) in \(.damage.extents | "\(.x),\(.y) \(.width)x\(.height)") under \(.damage.under | map(join(" < ")) | join(" | "))"] | join("; ")' <<<"$r" 2>/dev/null)
    sources=$(jq -r '[.fallback.frames[].damage.under[][]] | join(" < ")' <<<"$r" 2>/dev/null | apex_sources)
    if jq -e '.fallback.afterPaints == 0 and .fallback.frames == []' <<<"$r" >/dev/null 2>&1; then
        pass "dock-pin: after the dock's own update the stage paints no frame, through the fallback"
    else
        fail "dock-pin: after the dock's own update the stage paints no frame, through the fallback ($(jq -r '.fallback.afterPaints' <<<"$r" 2>/dev/null) painted: ${offenders:-none recorded}${sources:+; from $sources})"
    fi
    expect dock-pin "$r" '.stock.shown and (.stock.dashApps | length > 0) and (.stock.dashApps - .stock.favorites == [])' \
        "with the dock in disabled-features, the overview's own dash holds the favourites ($(jq -r '.stock.dashApps | join(", ")' <<<"$r" 2>/dev/null))"
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
        startup_handler_ran "$c" "$f"
        no_nan_allocation "$c" "$f"
        no_st_css_warning "$c" "$f"
        parental_controls_ready "$c" "$f"
        no_disposed_apex "$c" "$f"
        no_binding_overwritten "$c" "$f"
        no_spurious_allocation "$c" "$f"
        clean_shutdown "$c" "$f"
        no_disposed_at_shutdown "$c" "$f"
        # fault-abort may abort before its report; its exit status says the shell ran.
        [[ $c == fault-abort ]] && continue
        action_modes "$c" "$f"
        [[ $c == shutdown-banner ]] || exit_cut "$c" "$f"
        expect_report "$c" "$f" '.mode == "user"' "the probe ran: the static import graph loaded"
        fixed_clock "$c" "$f"
        backdrop_painted "$c" "$f"
    done
    fixtures_on_the_bus "$run"

    f=$run/default.log
    exits "$run" default 0
    apex_light default "$f"
    session_defaults default "$f"
    no_apex_failure default "$f"
    spotlight_key default "$f"
    search_hint default "$f" true
    virtual_monitor default "$f"
    expect_report default "$f" '.testFault == "stock" and .env.APEX_SHELL_TEST_FAULT == null' \
        "no fault feature without APEX_SHELL_TEST_FAULT"
    expect_report default "$f" '.startingMarker == true' "the layer created %t/apex-shell-starting at enable"
    check "default: the marker is removed at shutdown" grep -q '^default .*marker-after-exit=no' "$run/results-main.txt"
    top_bar default "$f" light
    solid_bar default "$f" light
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
    surface_metrics default "$f" light
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
    surface_metrics default-scale1 "$f" light
    spotlight_glass default-scale1 "$f" light
    spotlight_keys default-scale1 "$f" light
    screenshot_ui default-scale1 "$f" light

    f=$run/dark-style.log
    exits "$run" dark-style 0
    session_defaults dark-style "$f"
    expect_report dark-style "$f" ".stylesheet == \"$APEX_DARK_SHEET\" and .sheet.markers == [\"dark\"]" \
        "color-scheme prefer-dark loads the Apex dark sheet with its marker"
    expect_report dark-style "$f" '(.markerColor | colour_is("#f6f6f8")) and .safe == false' \
        "the marker actor takes the dark bar token (#f6f6f8)"
    no_apex_failure dark-style "$f"
    spotlight_key dark-style "$f"
    top_bar dark-style "$f" dark
    solid_bar dark-style "$f" dark
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
    surface_metrics dark-style "$f" dark
    spotlight_glass dark-style "$f" dark
    spotlight_keys dark-style "$f" dark
    screenshot_ui dark-style "$f" dark
    dark_style_off dark-style "$f"
    a11y_cases "$run"

    for c in dock-intellihide:light dock-intellihide-dark:dark; do
        exits "$run" "${c%:*}" 0
        no_apex_failure "${c%:*}" "$run/${c%:*}.log"
        dock_intellihide "${c%:*}" "$run/${c%:*}.log" "$run" "${c#*:}"
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
    session_defaults safe-env "$f"

    f=$run/layer-disabled.log
    exits "$run" layer-disabled 0
    logs layer-disabled "$f" 'Apex: safe mode \(layer-enabled is false\)' "logs 'Apex: safe mode (layer-enabled is false)'"
    expect_report layer-disabled "$f" '.layerEnabled == false' "the user's layer-enabled is false"
    stock_view layer-disabled "$f" dark
    stock_scheme layer-disabled "$f"

    layer_cycles "$run"
    motion_curve "$run"
    idle_desktop "$run"
    glass_load "$run"
    glass_stress "$run"
    dock_pin "$run"

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
    compare_with_fedora "$run" safe
    glass_frames glass "$run/glass.log"
    shadows_under_glass glass "$run/glass.log"
    glass_manager glass "$run/glass.log" light
    glass_unlock_vs_fedora "$run"
    indicator_cases "$run"
    one_gpu_case "$run"
    no_dock_case "$run"
    dock_dnd_case "$run"
    dock_external_case "$run"
    keys_case "$run"
    shutdown_banner_case "$run"
}

# shellcheck disable=SC2016 # jq programs
readonly DOCK_DND_FILES='org.gnome.Nautilus.desktop' DOCK_DND_CLOCKS='org.gnome.clocks.desktop'
readonly DOCK_DND_WEATHER='org.gnome.Weather.desktop' DOCK_DND_RUNNING='io.github.apex_linux.G2Window.desktop'

# The dock-dnd case: real drags, each read back from favorite-apps and the dock's drawn order.
dock_dnd_case() {
    local run=$1 f=$1/dock-dnd.log r error files=$DOCK_DND_FILES clocks=$DOCK_DND_CLOCKS
    local weather=$DOCK_DND_WEATHER running=$DOCK_DND_RUNNING
    exits "$run" dock-dnd 0
    no_js_error dock-dnd "$f"
    no_apex_failure dock-dnd "$f"
    r=$(report_of "$f" APEXG2-DOCK-DND)
    error=$(jq -r '.error // empty' <<<"$r" 2>/dev/null)
    if [[ -n $error ]]; then
        fail "dock-dnd: ${error%%$'\n'*}"
        return
    fi
    expect dock-dnd "$r" '.settled | (.startingUp | not) and (.overview | not) and .dock.visible and .actionMode == "NORMAL"' \
        "the session settled: startup over, no overview, the dock shown, the NORMAL action mode"
    expect dock-dnd "$r" "def shows(\$f): .favorites == \$f and .apps == \$f and .drawnInOrder;
        .steps.initial | shows([\"$files\", \"$clocks\"])" "the dock draws the case's favourites, Files then Clocks"
    expect dock-dnd "$r" ".steps.reorder | .favorites == [\"$clocks\", \"$files\"] and .apps == .favorites and .drawnInOrder" \
        "Clocks dragged onto Files' leading quarter comes first, in favorite-apps and in the dock's drawn order"
    expect dock-dnd "$r" ".steps.fromGrid | .favorites == [\"$clocks\", \"$weather\", \"$files\"] and .apps == .favorites and .drawnInOrder" \
        "Weather dragged from the app grid onto Files' leading quarter is pinned between Clocks and Files"
    expect dock-dnd "$r" '.steps.unpin.label == "Unpin"' "a favourite dragged over Show Apps labels it Unpin"
    expect dock-dnd "$r" ".steps.unpin | .favorites == [\"$clocks\", \"$files\"] and .apps == .favorites and .drawnInOrder" \
        "and dropped there it is unpinned, from favorite-apps and the dock"
    expect dock-dnd "$r" ".steps.dropOff | .favorites == [\"$clocks\", \"$files\"] and .apps == .favorites and .drawnInOrder" \
        "a favourite dropped off the dock stays pinned where it was: stock's dash unpins only on Show Apps"
    expect dock-dnd "$r" ".steps.onTrash | .favorites == [\"$clocks\", \"$files\"] and .apps == .favorites and .drawnInOrder" \
        "Trash refuses an app: a favourite dropped on it stays pinned where it was"
    expect dock-dnd "$r" ".steps.running | .installed and .running and .shown and .before.favorites == [\"$clocks\", \"$files\"] and
        .before.apps == [\"$clocks\", \"$files\", \"$running\"]" "a running app outside the favourites shows after them"
    expect dock-dnd "$r" ".steps.running.after | .favorites == [\"$clocks\", \"$running\", \"$files\"] and .apps == .favorites and .drawnInOrder" \
        "and dropped onto Files' leading quarter it is pinned between Clocks and Files"
    expect dock-dnd "$r" ".steps.cancelled | .favorites == [\"$clocks\", \"$files\"] and .apps == .favorites and .drawnInOrder" \
        "a drag cancelled with Esc changes nothing"
    expect dock-dnd "$r" '[.steps[] | if .after then .before, .after else . end] | length == 9 and
        all(.tail == ["separator", "show-apps", "trash"])' "after every drop and the cancel, the separator, Show Apps and Trash stay last"
    expect dock-dnd "$r" '[.steps[] | if .after then .before, .after else . end | .drag] | length == 9 and all(
        (.placeholder | not) and (.emptyTarget | not) and .modals == 0 and .actionMode == "NORMAL" and (.grab | not) and
        .showAppsLabel == "Show Apps" and .showAppsName == "Show Apps" and .faded == [] and
        (.strays | length <= 1 and all(.type == "Clutter_Actor" and .width == 0 and .height == 0 and .children == 0)))' \
        "and nothing is left in a drag state: no placeholder, grab or modal, NORMAL, every icon opaque, Show Apps named so, and no actor but DND's 0x0 event actor"
}

# shellcheck disable=SC2016 # jq programs
readonly DOCK_BLURS='def blurs($blur; $scale): .radius == 2 * ($blur | px) * $scale and .resourceScale == $scale and .enabled and
    .box.width > 0 and .box.height > 0;'
# shellcheck disable=SC2016 # a jq program
readonly DOCK_INSIDE='def inside($m): .x >= $m.x and .x + .width <= $m.x + $m.width and .y >= $m.y and .y + .height <= $m.y + $m.height;'

# The dock-external case: the primary's windows alone hide the dock and turn the bar solid,
# and the dock and the bar follow the primary that DisplayConfig sets.
# shellcheck disable=SC2016 # token names in descriptions, jq programs
dock_external_case() {
    local run=$1 f=$1/dock-external.log r error tokens cost
    exits "$run" dock-external 0
    no_js_error dock-external "$f"
    no_apex_failure dock-external "$f"
    r=$(report_of "$f" APEXG2-DOCK-EXTERNAL)
    error=$(jq -r '.error // empty' <<<"$r" 2>/dev/null)
    if [[ -n $error ]]; then
        fail "dock-external: ${error%%$'\n'*}"
        return
    fi
    tokens=$(tokens_for light)
    local -a metric=(top_bar_metric dock-external "$r" "$tokens")
    expect dock-external "$r" '.settled | (.startingUp | not) and (.overview | not) and .dock.visible and .actionMode == "NORMAL"' \
        "the session settled: startup over, no overview, the dock shown, the NORMAL action mode"
    expect dock-external "$r" '.steps.initial | .primary == 0 and .monitors == [{x: 0, y: 0, width: 1440, height: 900, index: 0},
        {x: 1440, y: 0, width: 960, height: 540, index: 1}]' \
        "the 2880x1800 panel is the primary and the 1920x1080 display sits right of it, both at scale 2"
    "${metric[@]}" 'the dock is on the primary only, $apex_dock_bottom_gap above its bottom edge and centred' \
        '.steps.initial' "$DOCK_INSIDE . as \$s | (.dockBox | inside(\$s.monitors[0])) and (.dockHidden | not) and
        (.dock.bottomGap | px_is(\$t.apex_dock_bottom_gap)) and (.dock.centreOffset | fabs <= 0.5)"
    expect dock-external "$r" '.steps.initial.panelBox | .x == 0 and .y == 0 and .width == 1440' "and so is the bar, the primary's width"
    expect dock-external "$r" '.steps.onSecondary | .window == {monitor: 1, maximised: true} and (.dockHidden | not) and (.barSolid | not)' \
        "a window maximised on the external display neither hides the dock nor turns the bar solid"
    expect dock-external "$r" '.steps.onPrimary | .window == {monitor: 0, maximised: true} and .dockHidden and .barSolid' \
        "moved to the primary, still maximised, it hides the dock and turns the bar solid"
    expect dock-external "$r" '.steps.backOnSecondary | .window == {monitor: 1, maximised: true} and (.dockHidden | not) and (.barSolid | not)' \
        "and moved back, the dock shows and the bar is translucent again"
    expect dock-external "$r" '.steps.overview | .shown and .controlsState == 1 and (.scrims | length == 2) and
        ([.scrims[] | .visible and (.launcher | not)] | all) and [.scrims[].box] == .monitors and (.views | length == 2)' \
        "the overview shows a view on each monitor over a scrim per monitor, each covering its monitor"
    "${metric[@]}" 'each scrim blurs at 2 x $apex_overview_scrim_blur x its monitor'"'"'s scale (2 on both)' \
        '.steps.overview.glass' "$DOCK_BLURS (.scrims | length == 2) and (.scrims | all(blurs(\$t.apex_overview_scrim_blur; 2)))"
    expect dock-external "$r" '.steps.launcher | .shown and .controlsState == 2 and ([.scrims[] | .visible and .launcher] | all) and
        [.scrims[].box] == .monitors' "and so does the launcher, each scrim styled apex-launcher"
    expect dock-external "$r" '.steps.swapped | .changed and .primary == 1' \
        "DisplayConfig's ApplyMonitorsConfig makes the external display the primary (monitors-changed)"
    "${metric[@]}" 'the dock follows it, $apex_dock_bottom_gap above its bottom edge and centred' \
        '.steps.swapped' "$DOCK_INSIDE . as \$s | (.dockBox | inside(\$s.monitors[1])) and
        (.dock.bottomGap | px_is(\$t.apex_dock_bottom_gap)) and (.dock.centreOffset | fabs <= 0.5)"
    expect dock-external "$r" '.steps.swapped.panelBox | .x == 1440 and .y == 0 and .width == 960' "and so does the bar"
    expect dock-external "$r" '.steps.swapped | .window.maximised and (.window.monitor == .primary) == .dockHidden and
        (.window.monitor == .primary) == .barSolid' \
        "and the dock hides and the bar turns solid exactly when the maximised window is on the new primary"
    expect dock-external "$r" '.steps.mixedOnExternal | .changed and .primary == 1 and .monitors == [{x: 0, y: 0, width: 1440, height: 900, index: 0},
        {x: 1440, y: 0, width: 1920, height: 1080, index: 1}]' \
        "ApplyMonitorsConfig sets the external display at scale 1 as the primary, the panel at scale 2 beside it"
    "${metric[@]}" 'the dock moves to it, $apex_dock_bottom_gap above its bottom edge and centred, and the bar spans it' \
        '.steps.mixedOnExternal' "$DOCK_INSIDE . as \$s | (.dockBox | inside(\$s.monitors[1])) and .panelBox == {x: 1440, y: 0, width: 1920, height: 32} and
        (.dock.bottomGap | px_is(\$t.apex_dock_bottom_gap)) and (.dock.centreOffset | fabs <= 0.5)"
    "${metric[@]}" 'their glass blurs at scale 1 there: radius 2 x $apex_dock_blur and 2 x $apex_bar_blur, each on a laid-out box' \
        '.steps.mixedOnExternal.desktopGlass' "$DOCK_BLURS (.dock | blurs(\$t.apex_dock_blur; 1)) and (.bar | blurs(\$t.apex_bar_blur; 1))"
    "${metric[@]}" "in the overview a scrim covers each monitor, blurring an unscaled clone of the desktop at 2 x \$apex_overview_scrim_blur x that monitor's own scale: 2 on the panel, 1 on the external display" \
        '.steps.mixedOnExternal' "$DOCK_BLURS .overview.stage == {x: 0, y: 0, width: 3360, height: 1080} and (.overview.scrims | length == 2) and
        [.overview.scrims[].box] == .overview.monitors and ([.overview.scrims[].visible] | all) and (.overview.views | length == 2) and
        [.glass.scrims[].box] == .overview.monitors and (.glass.scrims[0] | blurs(\$t.apex_overview_scrim_blur; 2)) and
        (.glass.scrims[1] | blurs(\$t.apex_overview_scrim_blur; 1)) and ([.glass.scrims[] | .clone == .source] | all)"
    cost=$(jq -r 'def ms: . * 100 | round / 100;
        [.steps.overview, .steps.mixedOnExternal] | map(.glass.cost | "\(.perMonitor | ms) ms against \(.wholeStage | ms)") | join(";")' <<<"$r" 2>/dev/null)
    expect dock-external "$r" '.steps.mixedOnExternal.glass.cost | .perMonitor < .wholeStage' \
        "a scrim per monitor models cheaper per re-blur than one stage-wide scrim at the views' highest scale (${cost#*;})"
    echo "# dock-external: 0014-blurcost.py's ms per scrim re-blur, per monitor against stage-wide (report only):" \
        "both at scale 2 ${cost%%;*}; mixed ${cost#*;}"
    expect dock-external "$r" '.steps.mixedOnExternal.desktopGlass.scrims | length == 2 and all(.enabled == false)' "and the hidden scrims stop blurring"
    expect dock-external "$r" '.steps.mixed | .changed and .primary == 0 and (.window.monitor == .primary) == .dockHidden and
        (.window.monitor == .primary) == .barSolid' \
        "with the panel the primary again, the dock and the bar follow it, and its maximised window hides the dock and turns the bar solid"
    "${metric[@]}" 'and the dock, under the panel (hidden there), and its glass blur at scale 2 again' \
        '.steps.mixed' "$DOCK_BLURS .monitors[0] as \$m | .dockBox.x >= \$m.x and .dockBox.x + .dockBox.width <= \$m.x + \$m.width and
        (.glass.dock | blurs(\$t.apex_dock_blur; 2)) and (.glass.bar | .resourceScale == 2 and .radius == 2 * (\$t.apex_bar_blur | px) * 2)"
}

# The keys case: each binding as registered, then pressed through a virtual keyboard.
keys_case() {
    local run=$1 f=$1/keys.log r error input backward
    exits "$run" keys 0
    no_js_error keys "$f"
    no_apex_failure keys "$f"
    r=$(report_of "$f" APEXG2-KEYS)
    error=$(jq -r '.error // empty' <<<"$r" 2>/dev/null)
    if [[ -n $error ]]; then
        fail "keys: ${error%%$'\n'*}"
        return
    fi
    input=$(tr "'" '"' <<<"$INPUT_SOURCE_KEYS")
    backward=$(tr "'" '"' <<<"$INPUT_SOURCE_BACKWARD_KEYS")
    expect keys "$r" ". as \$k | .bindings.inputSource == {modes: \$k.allModes, accelerators: $input}
        and .bindings.inputSourceBackward == {modes: \$k.allModes, accelerators: $backward}" \
        "the input source's Super+Alt+Space and Shift+Super+Alt+Space, apex-desktop's override, in every mode"
    expect keys "$r" ".bindings.panels == {modes: $PANELS_MODES, accelerators: $PANELS_KEYS}" \
        "Ctrl+Alt+Tab, GNOME's, in the session, overview, lock, unlock and login modes"
    expect keys "$r" ".bindings.appView == {modes: $SPOTLIGHT_MODES, accelerators: $APP_VIEW_KEYS}
        and .bindings.overlay == {modes: $SPOTLIGHT_MODES, key: \"Super\"}" \
        "Super+A and the Super tap, GNOME's, in the NORMAL and OVERVIEW modes"
    expect keys "$r" '.pressed | .sources == ["us", "fr"] and .first == "us"' "two input sources, us first"
    expect keys "$r" '.pressed.superSpace == {spotlight: true, source: "us"}' \
        "Super+Space opens Spotlight and leaves the input source alone"
    expect keys "$r" '.pressed | .superAltSpace.source == "fr" and .shiftSuperAltSpace.source == "us"' \
        "Super+Alt+Space switches to the next input source, and Shift+Super+Alt+Space back"
    expect keys "$r" '.pressed.ctrlAltTab | ([.groups[] | select(.dock)] | length == 1) and .dockFocused' \
        "Ctrl+Alt+Tab lists the dock among its groups, and the keyboard focus reaches it"
    expect keys "$r" '.pressed.superTap == {overview: true, apps: false}' "a Super tap opens the overview, on its windows"
    expect keys "$r" '.pressed.superA == {overview: true, apps: true}' "Super+A opens the launcher, the app grid"
    expect keys "$r" '.modals == 0' "and nothing is left holding a grab"
}

# The no-dock case: disabled-features=['dock'], so the overview's own dash is back and the
# workspace-bottom hook leaves stock's edge.
no_dock_case() {
    local run=$1 c
    for c in no-dock no-dock-dark; do
        exits "$run" "$c" 0
        no_apex_failure "$c" "$run/$c.log"
        desktop_without_dock "$c" "$run/$c.log"
        overview_without_dock "$c" "$run/$c.log"
    done
    bar_over_fixture no-dock "$run/no-dock.log"
}

# The desktop the Fedora comparison takes: captured, with no Apex dock on it.
desktop_without_dock() {
    local label=$1 log=$2
    expect_report "$label" "$log" '.error == null and .desktopOnly and (.scenes.desktop.file | type == "string")' \
        "the desktop scene is captured for the Fedora comparison" APEXG2-SCENES
    expect_report "$label" "$log" '.dock == null and .scenes.desktop.boxes.dock == null' "with no Apex dock on it" APEXG2-SCENES
}

overview_without_dock() {
    local label=$1 log=$2
    expect_report "$label" "$log" '.error == null and .dock == null and .bottom.hook == .bottom.stock' \
        "without the dock feature, the last row's captions may reach stock's bottom edge, the monitor's" APEXG2-OVERVIEW-WINDOWS
    expect_report "$label" "$log" "(.previews | length) == $OVERVIEW_WINDOWS and all(.previews[]; .caption.visible)
        and ([range(0; .previews | length) as \$i | .previews[\$i].caption as \$c
            | (.previews | to_entries[] | select(.key != \$i) | .value.window, .value.caption)
            | select(\$c.x < .x + .width and .x < \$c.x + \$c.width and \$c.y < .y + .height and .y < \$c.y + \$c.height)] | length == 0)" \
        "and every caption is shown, none over another window's preview or caption" APEXG2-OVERVIEW-WINDOWS
}

# Whether the part ran every case an assertion reads; patched_assertions sets part.
asserted() {
    local c
    [[ $part == main ]] && return 0
    for c in "$@"; do
        [[ " ${PR_CASES[*]} ${PR_FEDORA_CASES[*]} " == *" $c "* ]] || return 1
    done
}

# The shutdown-banner case: the tray's banner timeout falls due in gnome-shell's shutdown loop, after the
# tray went with uiGroup; clean_shutdown and no_disposed_at_shutdown read the log past it.
shutdown_banner_case() {
    local run=$1 f=$1/shutdown-banner.log
    exits "$run" shutdown-banner 0
    no_apex_failure shutdown-banner "$f"
    expect shutdown-banner "$(report_of "$f" APEXG2-SHUTDOWN-BANNER)" ".pending and .armed and $DATE_MENU_CUT" \
        "as the shell exits, a notification is up or queued, the tray's banner timeout armed, and the date menu's handlers blocked"
    logs shutdown-banner "$f" 'Shutting down GNOME Shell' "the shell went through its shutdown"
}

# patched.sh's assertions after direct.sh's PART: main asserts every case, pr only the cases
# PR_CASES lists, and each of those must have run and reported.
patched_assertions() {
    local run=$1 part=$2 c
    for c in default default-scale1 dark-style stock-light stock-dark safe-env layer-disabled layer-cycles motion idle dock-pin glass-load glass-stress no-dock no-dock-dark; do
        asserted "${c%:*}" || continue
        no_js_error "$c" "$run/$c.log"
        fixed_clock "$c" "$run/$c.log"
    done
    # Every case the fedora and main parts run sets the backdrop; fault-abort may abort before it reports.
    for c in "${DIRECT_CASES[@]}"; do
        asserted "$c" || continue
        [[ $c == kernel-safe || $c == fault-abort ]] || backdrop_painted "$c" "$run/$c.log"
        [[ $c == kernel-safe || $c == fault-abort ]] || action_modes "$c" "$run/$c.log"
        [[ $c == kernel-safe || $c == fault-abort || $c == shutdown-banner ]] || exit_cut "$c" "$run/$c.log"
        [[ $c == kernel-safe ]] || startup_handler_ran "$c" "$run/$c.log"
        [[ -e $run/$c.log ]] && no_nan_allocation "$c" "$run/$c.log"
        [[ -e $run/$c.log ]] && no_st_css_warning "$c" "$run/$c.log"
        [[ -e $run/$c.log ]] && parental_controls_ready "$c" "$run/$c.log"
        [[ -e $run/$c.log ]] && no_disposed_apex "$c" "$run/$c.log"
        [[ -e $run/$c.log ]] && no_binding_overwritten "$c" "$run/$c.log"
        [[ -e $run/$c.log ]] && no_spurious_allocation "$c" "$run/$c.log"
        [[ -e $run/$c.log ]] && clean_shutdown "$c" "$run/$c.log"
        [[ -e $run/$c.log ]] && no_disposed_at_shutdown "$c" "$run/$c.log"
    done
    for c in default default-scale1 dark-style; do
        asserted "${c%:*}" || continue
        exits "$run" "$c" 0
        no_apex_failure "$c" "$run/$c.log"
    done
    asserted default && search_hint default "$run/default.log" true
    asserted safe-env && search_hint safe-env "$run/safe-env.log" false
    asserted default && top_bar default "$run/default.log" light
    asserted default && top_bar_today default "$run/default.log" light
    asserted default && top_bar_gaps default "$run/default.log" light
    asserted default-scale1 && top_bar default-scale1 "$run/default-scale1.log" light
    asserted default-scale1 && top_bar_today default-scale1 "$run/default-scale1.log" light
    asserted dark-style && top_bar dark-style "$run/dark-style.log" dark
    asserted default && solid_bar default "$run/default.log" light
    asserted dark-style && solid_bar dark-style "$run/dark-style.log" dark
    asserted dark-style && top_bar_today dark-style "$run/dark-style.log" dark
    asserted dark-style && top_bar_gaps dark-style "$run/dark-style.log" dark
    asserted default && dock_metrics default "$run/default.log" light
    asserted default-scale1 && dock_metrics default-scale1 "$run/default-scale1.log" light
    asserted dark-style && dock_metrics dark-style "$run/dark-style.log" dark
    for c in dock-intellihide:light dock-intellihide-dark:dark; do
        asserted "${c%:*}" || continue
        exits "$run" "${c%:*}" 0
        no_js_error "${c%:*}" "$run/${c%:*}.log"
        no_apex_failure "${c%:*}" "$run/${c%:*}.log"
        dock_intellihide "${c%:*}" "$run/${c%:*}.log" "$run" "${c#*:}"
    done
    asserted stock-light && no_dock stock-light "$run/stock-light.log"
    asserted stock-dark && no_dock stock-dark "$run/stock-dark.log"
    for c in default:light default-scale1:light dark-style:dark; do
        asserted "${c%:*}" || continue
        shell_surfaces "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        quick_settings "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        quick_settings_layer "${c%:*}" "$run/${c%:*}.log" apex
        notifications_layer "${c%:*}" "$run/${c%:*}.log" apex
        shadow_layers "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        window_switcher "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        modal_dialog "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        date_menu "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        overview_style "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        app_grid "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        overview_layer "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        derived_surfaces "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        tile_preview "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        spotlight_style "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        launcher_search "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        surface_metrics "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        spotlight_glass "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        spotlight_keys "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
        screenshot_ui "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    done
    for c in stock-light stock-dark; do
        asserted "${c%:*}" || continue
        quick_settings_layer "$c" "$run/$c.log" stock
        notifications_layer "$c" "$run/$c.log" stock
    done
    asserted default dark-style high-contrast large-text default-solid dark-style-solid high-contrast-solid \
        large-text-solid && a11y_cases "$run"
    asserted layer-cycles && layer_cycles "$run"
    asserted motion && motion_curve "$run"
    asserted idle && idle_desktop "$run"
    asserted glass-load && glass_load "$run"
    asserted glass-stress && glass_stress "$run"
    asserted dock-pin && dock_pin "$run"
    asserted glass && no_js_error glass "$run/glass.log"
    asserted glass && glass_frames glass "$run/glass.log"
    asserted glass && shadows_under_glass glass "$run/glass.log"
    asserted glass && glass_manager glass "$run/glass.log" light
    asserted glass fedora-glass && glass_unlock_vs_fedora "$run"
    asserted indicators indicators-scale1 indicators-dark && indicator_cases "$run"
    asserted dock-one-gpu && one_gpu_case "$run"
    asserted no-dock no-dock-dark && no_dock_case "$run"
    asserted dock-dnd && dock_dnd_case "$run"
    asserted dock-external && dock_external_case "$run"
    asserted keys && keys_case "$run"
    asserted shutdown-banner && shutdown_banner_case "$run"
    asserted fedora-light fedora-dark no-dock no-dock-dark &&
        compare_with_fedora "$run" "$(asserted stock-light stock-dark && echo safe)"
    if [[ $part == pr ]]; then
        part_ran "$run" pr "${PR_CASES[@]}"
        part_ran "$run" fedora "${PR_FEDORA_CASES[@]}"
    fi
}

hung_part() {
    local run=$1 part=$2
    fail "direct.sh $part: $(sed -n 's/^\([^ ]*\) exit=124 secs=\([0-9]*\) .*/\1 had no report within \2 s/p' "$run/results-$part.txt" |
        tail -n 1); G2 stops at a hung case, so the cases after it did not run"
}

# A part that runs some of main's cases asserts only those: each must have run and reported,
# so a case dropped from direct.sh fails here instead of passing unasserted.
part_ran() {
    local run=$1 part=$2 c
    shift 2
    for c in "$@"; do
        if ! grep -q "^$c exit=" "$run/results-$part.txt" 2>/dev/null; then
            fail "$c: direct.sh $part did not run it"
        elif [[ $c != fault-abort && -z $(report_of "$run/$c.log") ]]; then
            fail "$c: direct.sh $part ran it, but it reported nothing"
        else
            pass "$c: direct.sh $part ran it and it reported"
        fi
    done
}

# The dock-one-gpu case: fixtures.py --gpus 1, as switcheroo-control reports a laptop
# whose NVIDIA driver is not bound.
one_gpu_case() {
    local run=$1
    exits "$run" dock-one-gpu 0
    no_js_error dock-one-gpu "$run/dock-one-gpu.log"
    no_apex_failure dock-one-gpu "$run/dock-one-gpu.log"
    one_gpu_menu dock-one-gpu "$run/dock-one-gpu.log"
}

one_gpu_menu() {
    local label=$1 log=$2
    expect_report "$label" "$log" '.hasDualGpu == false and (.items | length > 0)' \
        "the dock's app menu opens while switcheroo-control reports one GPU" APEXG2-GPU
    expect_report "$label" "$log" '.items != null and (.items | all(. != "Launch Using Discrete Graphics Card"))' \
        "and offers no Launch Using Discrete Graphics Card" APEXG2-GPU
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
    local label=$1 log=$2 variant=$3 tokens glass empty
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
    "${expect_glass[@]}" '.t as $t | .manager.monitorScale as $s | .manager.scrims
        | def scrim($blur; $saturation): .radius == 2 * ($blur | px) * $s and ((.saturation - ($saturation | rtrimstr("%") | tonumber / 100)) | fabs < 0.001) and .fine and (.background | not);
        (.overview | scrim($t.apex_overview_scrim_blur; $t.apex_overview_scrim_saturation) and .enabled)
        and (.launcher | scrim($t.apex_launcher_scrim_blur; $t.apex_launcher_scrim_saturation) and .enabled)
        and (.hidden.enabled | not) and .barOverScrim.enabled and .barOverScrim.background' \
        'the overview scrim blurs a clone of the desktop at $apex_overview_scrim_blur and $apex_overview_scrim_saturation in actor mode, the launcher at $apex_launcher_scrim_blur and $apex_launcher_scrim_saturation, off once the overview hides; the bar blurs the scrim beneath it'
    empty=$(report_of "$log" APEXG2-GLASS | jq -r '.manager.emptyBox | "\(.emptyFrames) empty frames; laid out \(.laidOut.allocation | join("x")) after \(.laidOut.frames) frames, \(if .laidOut.enabled then "on" else "off" end)"' 2>/dev/null)
    "${expect_glass[@]}" '.manager.emptyBox | ([.shown, .hidden, .shownAgain] | all(.enabled | not)) and .emptyFrames == 3 and .laidOut.enabled and (.zeroHeight.enabled | not)' \
        "an actor-mode surface with an empty box draws a frame shown, hidden and shown again without blurring, blurs once laid out, and pauses at zero height (${empty:-no report})"
    "${expect_glass[@]}" "$glass"' .t as $t | .manager.monitorScale as $s | .manager.derived
        | (.osd | glass($t.apex_panel_blur; $t.apex_panel_saturation; $s)) and (.switcher | glass($t.apex_panel_blur; $t.apex_panel_saturation; $s))
        and (.screenshot | .radius == 2 * ($t.apex_panel_blur | px) * $s and .fine and (.enabled | not))' \
        'the derived glass: the OSD and an Alt+Tab list blur at $apex_panel_blur and $apex_panel_saturation as the popovers do; the screenshot panel too, paused while closed'
    "${expect_glass[@]}" 'def fits: .cornerRadius as $r | .painted.radii | all(. == $r); .manager
        | ([.glass.panel, .glass.dock, .glass.quickSettings, .glass.calendar, .glass.banner, .derived.osd, .derived.switcher, .tile.shown.glass]
            | all(fits and .painted.box == [0, 0] + .allocation))
        and (.derived.screenshot | fits)' \
        'every glass rounds its blur at its border radius, all four corners, over the box St paints its background in: the bar, the dock, Quick Settings, the calendar, a banner, the OSD, an Alt+Tab list and the tile preview; the screenshot panel'"'"'s corners too'
    "${expect_glass[@]}" '.manager.derived.switcher.corner | .radius > 0 and .outside > 0 and .inside > 0 and .blurredOutside == 0 and .blurredInside == .inside' \
        'over a checker, an Alt+Tab list'"'"'s bottom-left corner blurs no pixel past its border'"'"'s arc and every pixel inside it (board 15)'
    "${expect_glass[@]}" '.manager.derived.switcher.corner.capturedDiffering == 0' \
        'and a screenshot shows that corner as the screen does, pixel for pixel: off stage, the blur maps the stage through the capture'"'"'s viewport'
    local conformance
    conformance=$(report_of "$log" APEXG2-GLASS | jq -r '.manager.conformance | "\(.registered | length) registered: \(.registered | join(", "))"' 2>/dev/null)
    "${expect_glass[@]}" '.manager.conformance | (.registered | length) > 0 and .unchecked == [] and (.registered | all(. as $n | $n | IN(["panel", "dock", "quick-settings", "calendar", "banner", "osd", "spotlight", "toast", "switcher", "screenshot", "tilePreview"][]) or startswith("scrim-")))' \
        "every surface the glass registry got in the case was checked, each by name, and none unknown to it (${conformance:-no report})"
    "${expect_glass[@]}" '.manager.conformance.checked | to_entries | all(.value | .cornerRadius as $r
        | (.painted.radii | all(. == $r)) and (.allocation[0] == null or .painted.box == [0, 0] + .allocation))' \
        'each rounds its blur at its border radius, all four corners, over the box St paints its background in: the Spotlight panel and the toast too'
    "${expect_glass[@]}" '.manager.conformance.checked | ["dock", "quick-settings", "calendar", "banner", "osd", "spotlight", "toast"] as $rounded
        | [$rounded[] as $n | .[$n].corner | .radius > 0 and .outside > 0 and .ring > 0 and .blurredOutside == 0 and .blurredRing == .ring] | length == 7 and all' \
        'over a checker, the bottom-left corner of the dock, Quick Settings, the calendar, a banner, the OSD, the Spotlight panel and the toast blurs no pixel past its border'"'"'s arc and every pixel in the band inside it'
    "${expect_glass[@]}" '.manager.conformance.checked | [.["dock", "quick-settings", "calendar", "banner", "osd", "spotlight", "toast"].corner.capturedDiffering] | length == 7 and all(. == 0)' \
        'and a screenshot shows each of those corners as the screen does, pixel for pixel'
    "${expect_glass[@]}" "$glass"' .t as $t | .manager.monitorScale as $s | .manager.tile.shown.glass
        | glass($t.apex_tile_preview_blur; $t.apex_tile_preview_saturation; $s) and .cornerRadius == ($t.apex_radius_tile_preview | px) * $s' \
        'the shown tile preview registers its glass at board 22'"'"'s $apex_tile_preview_blur and $apex_tile_preview_saturation, rounded $apex_radius_tile_preview'
    "${expect_glass[@]}" '.t as $t | .manager.tile.shown | (.inset | px_is($t.apex_tile_preview_inset)) and .glassBox == .inner' \
        'the blurred box is the preview inside its clear $apex_tile_preview_inset border, exactly'
    "${expect_glass[@]}" ".manager.tile.shown | .downscale > 1 and .innerDiffering > 0 and (.interior.max | max) <= $GLASS_INTERIOR_MAX and (.edge.max | max) <= $GLASS_EDGE_MAX and (.box.mean | max) <= $GLASS_MEAN_ERROR" \
        "with its fill and ring held off, the pixels there are blur-ref.js's blur of the pattern, within $GLASS_INTERIOR_MAX/255 inside, $GLASS_EDGE_MAX/255 in the ds/2 band, $GLASS_MEAN_ERROR/255 on average"
    "${expect_glass[@]}" '.manager.tile.shown.bandDiffering == 0' \
        'and the clear border around them shows the pattern itself, pixel for pixel: no blur'
    local ring='def ringed($t): (.borderColor | rgba) as $b | (.background | rgba) as $f
        | .mapped and .glassed and (.borders | length == 4 and all(px_is($t.apex_tile_preview_ring)))
        and (.radius | px_is($t.apex_radius_tile_preview)) and (.previewBackground | rgba | .[3] == 0) and (.previewShadow | not)
        and $b[0:3] == $f[0:3] and ($b[3] - ($t.apex_tile_preview_ring_opacity | num) * 255 | fabs <= 1)
        and ($f[3] - ($t.apex_tile_preview_fill_opacity | num) * 255 | fabs <= 1);'
    "${expect_glass[@]}" "$ring"' .t as $t | .manager.tile.ring | ringed($t)' \
        'the glass actor draws the fill and a $apex_tile_preview_ring border ring in one hue, at $apex_tile_preview_fill_opacity and $apex_tile_preview_ring_opacity, rounded $apex_radius_tile_preview; the classed preview draws neither'
    "${expect_glass[@]}" ".t as \$t | .manager.tile | (.ring.expected - (\$t.apex_tile_preview_ring | px) * .shown.scale | fabs < 0.01)
        and (.ring as \$r | [\$r.corners[], \$r.edges[]] | length == 8 and all(. - \$r.expected | fabs <= $TILE_RING_ALLOWANCE))" \
        "drawn, the ring is \$apex_tile_preview_ring times the scale wide in each corner and along each edge, from its coverage, within $TILE_RING_ALLOWANCE device px"
    "${expect_glass[@]}" "$ring"' .t as $t | .manager.tile.reduceTransparency | ringed($t) and .glass == null' \
        'with Reduce Transparency the blur goes, the glass actor stays: its fill and ring, even round the corners'
    "${expect_glass[@]}" '.manager.tile.highContrast | .glass == null and .glassed and (.borders | all(. == 0)) and (.background | rgba | .[3] == 0)
        and (.previewBackground | rgba | .[3] > 0)' \
        'with high contrast, whose sheet keeps upstream'"'"'s tile preview, the blur goes and the glass actor paints nothing: the preview draws upstream'"'"'s alone'
    "${expect_glass[@]}" '.manager.tile.hidden | .glass == null and (.visible | not) and .differing == 0' \
        'closed, the preview leaves no blur behind: no effect, and the pattern itself where it was'
    "${expect_glass[@]}" '.manager.scrims | .forwarded.changed > 0 and .forwarded.differingFromFull == 0 and .unforwarded.differingFromFull > 0' \
        'a window damaged under the scrim, forwarded as the manager forwards a window'"'"'s damage, re-blurs it in the same frame as a full redraw would; unforwarded, the blur'"'"'s halo stays stale, which is why it is forwarded'
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
    echo "# guard phases whose probe was imported after startup, then emitted startup-complete again: ${late:-none}"
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
