#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Each case is one gjs process, because safe mode is decided once per process.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
# apex-desktop owns the schema and the crash guard: fixtures/ holds copies, and
# APEX_DESKTOP_SRC, an apex-desktop checkout, tests against its own files instead.
if [[ -n ${APEX_DESKTOP_SRC:-} ]]; then
    SCHEMA_DIR=$APEX_DESKTOP_SRC/desktop/schemas
    GUARD_UNIT=$APEX_DESKTOP_SRC/desktop/systemd/user/apex-shell-safe.service
else
    SCHEMA_DIR=$HERE/fixtures
    GUARD_UNIT=$HERE/fixtures/apex-shell-safe.service
fi
NO_SKIP=${APEX_LAYER_TESTS_NO_SKIP:-0}

tests=0
failed=0
ok() { tests=$((tests + 1)); printf 'ok %d - %s\n' "$tests" "$*"; }
not_ok() { tests=$((tests + 1)); failed=$((failed + 1)); printf 'not ok %d - %s\n' "$tests" "$*"; }
skip() {
    if [[ $NO_SKIP == 1 ]]; then
        not_ok "would skip ($*), but APEX_LAYER_TESTS_NO_SKIP=1"
    else
        tests=$((tests + 1))
        printf 'ok %d # SKIP %s\n' "$tests" "$*"
    fi
}

GI_COMPILER=$(command -v gi-compile-repository || command -v g-ir-compiler || true)
for tool in gjs glib-compile-schemas "${GI_COMPILER:-gi-compile-repository}" dbus-run-session; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        if [[ $NO_SKIP == 1 ]]; then
            printf 'not ok 1 - %s not found, but APEX_LAYER_TESTS_NO_SKIP=1\n1..1\n' "$tool"
            exit 1
        fi
        printf '1..0 # SKIP %s not found\n' "$tool"
        exit 0
    fi
done

T=$(mktemp -d "${TMPDIR:-/tmp}/apex-layer-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/schemas" "$T/noschema" "$T/nochild" "$T/data" "$T/home" "$T/shell" "$T/typelib"
# main.js and the Meta and Shell typelibs come only with gnome-shell and mutter.
cp -R "$REPO/desktop/shell/js" "$T/shell/"
cp "$HERE/main-stub.js" "$T/shell/js/ui/main.js"
for upstream in panelMenu dash iconGrid popupMenu layout; do
    cp "$HERE/stubs/$upstream.js" "$T/shell/js/ui/$upstream.js"
done
# Spotlight's providers: upstream's app search and remote providers, faked.
cp "$HERE"/stubs/appDisplay.js "$HERE"/stubs/remoteSearch.js "$HERE"/stubs/searchProviders.js "$T/shell/js/ui/"
mkdir -p "$T/shell/js/misc"
cp "$HERE/stubs/systemActions.js" "$T/shell/js/misc/"
cp "$HERE"/stubs/St.js "$HERE"/stubs/Clutter.js "$HERE"/stubs/Shell.js "$HERE"/stubs/Meta.js "$HERE"/stubs/Graphene.js \
    "$HERE"/stubs/GdkPixbuf.js "$T/"
# The shadow cutout and the indicators' mask are GObject subclasses of Clutter.ShaderEffect, which the stubs cannot be.
cp "$HERE/stubs/cutout.js" "$T/shell/js/ui/apex/shadows/cutout.js"
cp "$HERE/stubs/indicator-mask.js" "$T/shell/js/ui/apex/indicators/mask.js"
# gjs outside the shell has no St or Clutter typelib, the job no gdk-pixbuf, and the fixtures'
# Shell and Meta no WindowTracker or Barrier: the features get stubs instead.
find "$T/shell/js/ui/apex" -name '*.js' -exec sed -i -e "s|'gi://St'|'file://$T/St.js'|" \
    -e "s|'gi://Clutter'|'file://$T/Clutter.js'|" -e "s|'gi://Shell'|'file://$T/Shell.js'|" \
    -e "s|'gi://Meta'|'file://$T/Meta.js'|" -e "s|'gi://Graphene'|'file://$T/Graphene.js'|" \
    -e "s|'gi://GdkPixbuf'|'file://$T/GdkPixbuf.js'|" {} +
for gir in "$HERE"/fixtures/*.gir; do
    gir_name=${gir##*/}
    "$GI_COMPILER" "$gir" -o "$T/typelib/${gir_name%.gir}.typelib"
done
# A disabled-features restricted to its <choices> must also take the test-only features.
readonly APEX_SCHEMA=$T/io.github.apex_linux.Apex.Desktop.gschema.xml
awk '/<key name="disabled-features"/ { key = 1 }
    key && /<choices>/ && !done { print; print "        <choice value=\"fault\"/>"; print "        <choice value=\"witness\"/>"; done = 1; next }
    key && /<\/key>/ { key = 0 }
    { print }' "$SCHEMA_DIR/io.github.apex_linux.Apex.Desktop.gschema.xml" >"$APEX_SCHEMA"
cp "$SCHEMA_DIR"/*.gschema.xml "$T/schemas/"
cp "$APEX_SCHEMA" "$T/schemas/"
readonly SEARCH_PROVIDERS_SCHEMA=$HERE/fixtures/org.gnome.desktop.search-providers.gschema.xml
cp "$SEARCH_PROVIDERS_SCHEMA" "$T/schemas/"
glib-compile-schemas --strict "$T/schemas"
awk '/<child name="keybindings"/ { next }
    /<schema id="io\.github\.apex_linux\.Apex\.Desktop\.Keybindings"/ { skip = 1 }
    !skip { print }
    skip && /<\/schema>/ { skip = 0 }' "$APEX_SCHEMA" \
    >"$T/nochild/io.github.apex_linux.Apex.Desktop.gschema.xml"
cp "$SEARCH_PROVIDERS_SCHEMA" "$T/nochild/"
glib-compile-schemas --strict "$T/nochild"
mkdir -p "$T/nokey"
awk '/<key name="toggle-spotlight"/ { skip = 1 } !skip { print } skip && /<\/key>/ { skip = 0 }' \
    "$APEX_SCHEMA" >"$T/nokey/io.github.apex_linux.Apex.Desktop.gschema.xml"
cp "$SEARCH_PROVIDERS_SCHEMA" "$T/nokey/"
glib-compile-schemas --strict "$T/nokey"
mkdir -p "$T/nodock"
awk '/<key name="dock-show-trash"/ { skip = 1 } !skip { print } skip && /<\/key>/ { skip = 0 }' \
    "$APEX_SCHEMA" >"$T/nodock/io.github.apex_linux.Apex.Desktop.gschema.xml"
cp "$SEARCH_PROVIDERS_SCHEMA" "$T/nodock/"
glib-compile-schemas --strict "$T/nodock"
mkdir -p "$T/nohint"
awk '/<key name="search-hint-shown"/ { skip = 1 } !skip { print } skip && /<\/key>/ { skip = 0 }' \
    "$APEX_SCHEMA" >"$T/nohint/io.github.apex_linux.Apex.Desktop.gschema.xml"
cp "$SEARCH_PROVIDERS_SCHEMA" "$T/nohint/"
glib-compile-schemas --strict "$T/nohint"
mkdir -p "$T/noreduce"
awk '/<key name="reduce-transparency"/ { skip = 1 } !skip { print } skip && /<\/key>/ { skip = 0 }' \
    "$APEX_SCHEMA" >"$T/noreduce/io.github.apex_linux.Apex.Desktop.gschema.xml"
glib-compile-schemas --strict "$T/noreduce"

readonly CMDLINE_PLAIN='BOOT_IMAGE=(hd0,gpt2)/boot/ostree/apex/vmlinuz root=UUID=0 rw rhgb quiet'
sandbox=0
printf '%s\n' "$CMDLINE_PLAIN" >"$T/cmdline.check"
if command -v bwrap >/dev/null 2>&1 &&
    bwrap --dev-bind / / --ro-bind "$T/cmdline.check" /proc/cmdline /usr/bin/true 2>/dev/null; then
    sandbox=1
fi

# A case's runtime and config directories outlive it, so the guard and a later case of
# the same name see what its shell left there. Each case has its own session bus.
probe() {
    local name=$1 cmdline=$2
    shift 2
    local dir=$T/$name
    mkdir -p "$dir/run" "$dir/config"
    chmod 0700 "$dir/run"
    printf '%s\n' "$cmdline" >"$dir/cmdline"
    local -a cmd=(env -i PATH="$PATH" HOME="$T/home" LANG=C.UTF-8
        XDG_RUNTIME_DIR="$dir/run" XDG_CONFIG_HOME="$dir/config" XDG_DATA_DIRS="$T/data"
        GSETTINGS_BACKEND=memory GSETTINGS_SCHEMA_DIR="$T/schemas" GI_TYPELIB_PATH="$T/typelib"
        APEX_SHELL_DIR="$T/shell" "$@" dbus-run-session -- gjs -m "$HERE/probe.js")
    if ((sandbox)); then
        cmd=(bwrap --dev-bind / / --ro-bind "$dir/cmdline" /proc/cmdline "${cmd[@]}")
    fi
    RC=0
    "${cmd[@]}" </dev/null >"$dir/out" 2>&1 || RC=$?
    OUT=$dir/out
}

_show() { sed 's/^/#   /' "$OUT"; }
rc_is() { if [[ $RC == "$2" ]]; then ok "$1"; else not_ok "$1 (exit $RC, expected $2)"; _show; fi; }
has() { if grep -Eq -- "$2" "$OUT"; then ok "$1"; else not_ok "$1 (no line matches /$2/)"; _show; fi; }
lacks() { if grep -Eq -- "$2" "$OUT"; then not_ok "$1 (a line matches /$2/)"; _show; else ok "$1"; fi; }
fact() { has "$1" "^probe: $2\$"; }
count_is() { if [[ $(grep -c -- "$2" "$OUT") == "$3" ]]; then ok "$1"; else not_ok "$1 ($(grep -c -- "$2" "$OUT") lines match /$2/, expected $3)"; _show; fi; }
keybindings_are() {
    local got
    got=$(sed -n 's/^probe: keybinding\.\([a-z]*\)=.*/\1/p' "$OUT" | paste -sd' ' -)
    if [[ $got == "$2" ]]; then ok "$1"; else not_ok "$1 (the stub saw '$got', expected '$2')"; _show; fi
}

run_guard_unit_like_systemd() {
    local dir=$T/$1 key value cond='' line runtime='%t' state='%S'
    local -a lines=()
    while IFS='=' read -r key value; do
        value=${value//"$runtime"/$dir/run}
        value=${value//"$state"/$dir/state}
        case $key in
            ConditionPathExists) cond=$value ;;
            StateDirectory) mkdir -p "$dir/state/$value" ;;
            ExecStart | ExecStartPost) lines+=("$value") ;;
        esac
    done < <(grep -E '^[A-Za-z]+=' "$GUARD_UNIT")
    if [[ -z $cond || ! -e $cond ]]; then
        printf 'skipped\n'
        return 0
    fi
    for line in "${lines[@]}"; do
        # shellcheck disable=SC2086 # the unit's command lines are plain words
        env -i PATH="$PATH" HOME="$T/home" XDG_CONFIG_HOME="$dir/config" XDG_DATA_DIRS="$T/data" \
            GSETTINGS_BACKEND=keyfile GSETTINGS_SCHEMA_DIR="$T/schemas" $line
    done
    printf 'acted\n'
}

probe default "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_PRESS=2
rc_is "default: the probe runs" 0
fact "default: not safe" 'safe=false'
fact "default: the layer loads" 'layer=loaded'
fact "default: 'default' is light in the user mode" 'scheme\.user=prefer-light'
fact "default: and in the unlock dialog" 'scheme\.unlock-dialog=prefer-light'
fact "default: the greeter keeps upstream's dark" 'scheme\.gdm=prefer-dark'
fact "default: other modes keep upstream's" 'scheme\.initial-setup=prefer-dark'
fact "default: no fault feature without APEX_SHELL_TEST_FAULT" 'test-fault=stock'
fact "default: nor the witness" 'test-witness\.after-enable=stock'
fact "default: a throwing provider gives stock, twice" 'boom=stock,stock'
if [[ $(grep -c 'hook boom threw' "$OUT") == 1 ]]; then ok "default: and is logged once"; else not_ok "default: and is logged once"; _show; fi
fact "default: a behaviour hook without a provider gives undefined" 'run-without-provider=undefined'
fact "default: enable creates the crash guard's marker" 'starting-file=true'
fact "default: shutdown removes it" 'starting-file\.after-shutdown=false'
lacks "default: no safe mode" 'safe mode'
fact "spotlight: enable registers Super+Space, without autorepeat, in the normal and overview modes" \
    'keybinding\.add=toggle-spotlight accelerators=<Super>space flags=IGNORE_AUTOREPEAT modes=NORMAL\|OVERVIEW'
has "spotlight: the feature enables" 'Apex: feature spotlight enabled'
keybindings_are "spotlight: registered once" add
fact "spotlight: a press opens Spotlight, a modal in the popup action mode" 'modal\.push=apexSpotlight actionMode=128 count=1'
fact "spotlight: over the desktop, not the overview" 'press\.1=overview=false spotlight=true'
fact "spotlight: pressed again, it closes and gives the grab back" 'press\.2=overview=false spotlight=false'
count_is "spotlight: one grab taken, one given back" '^probe: modal\.pop=count=0$' 1
has "motion: the feature enables" 'Apex: feature motion enabled'
fact "motion: a curved mode becomes CUBIC_BEZIER, its duration kept" 'motion\.quad=CUBIC_BEZIER 250'
fact "motion: so does stock's expo" 'motion\.expo=CUBIC_BEZIER 400'
fact "motion: an actor's default ease takes the curve" 'motion\.actor-default=CUBIC_BEZIER 100'
fact "motion: linear stays linear" 'motion\.linear=LINEAR 100'
fact "motion: stepped stays stepped" 'motion\.steps=STEPS 100'
fact "motion: an adjustment's curved ease takes the curve" 'motion\.adjustment=CUBIC_BEZIER 250'
fact "motion: an adjustment without a mode keeps Clutter's linear" 'motion\.adjustment-default=none 100'
fact "motion: an ease without parameters passes through" 'motion\.no-params=undefined'
fact "motion: the eased hook sets cubic-bezier(.2,.8,.2,1)" 'motion\.curve=0\.2,0\.8 0\.2,1'
fact "motion: window geometry .3 s, the overview .2 s, popovers .18 s; other roles stock" \
    'motion\.durations=window=300 overview=200 popover=180 unknown=250'
if [[ $(run_guard_unit_like_systemd default) == skipped ]]; then
    ok "default: a later shell failure does not trip the guard (no marker)"
else
    not_ok "default: a later shell failure does not trip the guard (no marker)"
fi

probe envsafe "$CMDLINE_PLAIN" APEX_SHELL_SAFE=1 PROBE_ENABLE=1
rc_is "APEX_SHELL_SAFE=1: runs" 0
fact "APEX_SHELL_SAFE=1: safe" 'safe=true'
has "APEX_SHELL_SAFE=1: and says why" 'Apex: safe mode \(APEX_SHELL_SAFE=1\)'
fact "APEX_SHELL_SAFE=1: no layer" 'layer=null'
fact "APEX_SHELL_SAFE=1: the stock colour scheme" 'scheme\.user=prefer-dark'
fact "APEX_SHELL_SAFE=1: no provider at all" 'boom=stock,stock'
keybindings_are "APEX_SHELL_SAFE=1: no Super+Space binding" ''

if ((sandbox)); then
    probe kernel "BOOT_IMAGE=/vmlinuz root=UUID=0 rw apex.safe=1 rhgb quiet" PROBE_ENABLE=1
    rc_is "apex.safe=1: runs" 0
    fact "apex.safe=1 on the kernel command line: safe" 'safe=true'
    has "apex.safe=1: and says why" 'Apex: safe mode \(apex\.safe=1\)'
    fact "apex.safe=1: no layer" 'layer=null'
    fact "apex.safe=1: the stock colour scheme" 'scheme\.user=prefer-dark'
    lacks "apex.safe=1: no crash guard marker without a layer" 'starting-file'
    keybindings_are "apex.safe=1: no Super+Space binding" ''
    probe kernel-first "apex.safe=1 BOOT_IMAGE=/vmlinuz" PROBE_MODE=gdm
    fact "apex.safe=1 as the first word, in the greeter: safe" 'safe=true'
    probe lookalikes "BOOT_IMAGE=/vmlinuz apex.safe=0 xapex.safe=1 apex.safe=10 apex.safe rhgb"
    fact "apex.safe=0, xapex.safe=1, apex.safe=10, apex.safe: not safe" 'safe=false'
    fact "and the layer loads" 'layer=loaded'
else
    skip "apex.safe=1 on the kernel command line: bwrap cannot bind a fixture over /proc/cmdline here"
fi

probe off "$CMDLINE_PLAIN" PROBE_LAYER_OFF=1
fact "layer-enabled=false: safe" 'safe=true'
has "layer-enabled=false: and says why" 'Apex: safe mode \(layer-enabled is false\)'
fact "layer-enabled=false: the stock colour scheme" 'scheme\.user=prefer-dark'
keybindings_are "layer-enabled=false: no Super+Space binding" ''

probe gdm "$CMDLINE_PLAIN" PROBE_MODE=gdm PROBE_LAYER_OFF=1
fact "gdm mode: layer-enabled=false does not reach the greeter" 'safe=false'
fact "gdm mode: no Apex JS runs in the greeter" 'layer=null'
fact "gdm mode: upstream's colour scheme" 'scheme\.gdm=prefer-dark'

probe noschema "$CMDLINE_PLAIN" GSETTINGS_SCHEMA_DIR="$T/noschema"
fact "no Apex schema: safe" 'safe=true'
has "no Apex schema: and says why" 'Apex: safe mode \(schema io\.github\.apex_linux\.Apex\.Desktop is not installed\)'

probe broken "$CMDLINE_PLAIN" PROBE_BROKEN=1
fact "a layer that does not load: null" 'layer=null'
has "and is logged" 'Apex: the layer did not load; stock shell for this session'
fact "and its providers are gone" 'scheme\.user=prefer-dark'

probe configure "$CMDLINE_PLAIN" APEX_SHELL_TEST_FAULT=configure PROBE_ENABLE=1
rc_is "FAULT=configure: the shell goes on" 0
has "FAULT=configure: the feature is off for the session" 'Apex: feature fault off for this session \(configure: Error: injected fault in configure'
fact "FAULT=configure: its hook gives stock" 'test-fault=stock'
fact "FAULT=configure: the rest of the layer runs" 'scheme\.user=prefer-light'
fact "FAULT=configure: enable still runs" 'starting-file=true'
fact "FAULT=configure: the feature after it configures" 'test-witness=configured'
has "FAULT=configure: and enables" 'Apex: feature witness enabled'
fact "FAULT=configure: its hook reports it" 'test-witness\.after-enable=enabled'

probe enable "$CMDLINE_PLAIN" APEX_SHELL_TEST_FAULT=enable PROBE_ENABLE=1
rc_is "FAULT=enable: the shell goes on" 0
fact "FAULT=enable: the feature is on until enable" 'test-fault=fault'
has "FAULT=enable: then off for the session" 'Apex: feature fault off for this session \(enable: Error: injected fault in enable'
fact "FAULT=enable: its hook gives stock" 'test-fault\.after-enable=stock'
fact "FAULT=enable: the rest of the layer runs" 'scheme\.user\.after-enable=prefer-light'
fact "FAULT=enable: the crash guard's marker exists" 'starting-file=true'
has "FAULT=enable: the feature after it enables" 'Apex: feature witness enabled'
fact "FAULT=enable: and its hook reports it" 'test-witness\.after-enable=enabled'

probe abort "$CMDLINE_PLAIN" APEX_SHELL_TEST_FAULT=abort-after-enable PROBE_ENABLE=1 PROBE_WAIT=20
rc_is "FAULT=abort-after-enable: the shell aborts (SIGABRT)" 134
has "FAULT=abort-after-enable: and says so" 'aborting the shell'
fact "FAULT=abort-after-enable: within the marker's 60 s" 'starting-file=true'
fact "FAULT=abort-after-enable: the feature ran" 'test-fault\.after-enable=fault'
lacks "FAULT=abort-after-enable: before the wait ends" '^probe: survived='
if [[ -e $T/abort/run/apex-shell-starting ]]; then ok "the dead shell left the marker"; else not_ok "the dead shell left the marker"; fi
if [[ $(run_guard_unit_like_systemd abort) == acted ]]; then ok "the crash guard's condition holds and it runs"; else not_ok "the crash guard's condition holds and it runs"; fi
if [[ -e $T/abort/state/apex/shell-guard-tripped ]]; then ok "the guard leaves the agent's marker"; else not_ok "the guard leaves the agent's marker"; fi
if [[ ! -e $T/abort/run/apex-shell-starting ]]; then ok "the guard consumes the layer's marker"; else not_ok "the guard consumes the layer's marker"; fi
probe abort "$CMDLINE_PLAIN" GSETTINGS_BACKEND=keyfile
fact "the next login: safe" 'safe=true'
has "the next login: because the guard turned the layer off" 'Apex: safe mode \(layer-enabled is false\)'
fact "the next login: upstream's colour scheme" 'scheme\.user=prefer-dark'

probe abortsafe "$CMDLINE_PLAIN" APEX_SHELL_TEST_FAULT=abort-after-enable APEX_SHELL_SAFE=1 PROBE_ENABLE=1 PROBE_WAIT=8
rc_is "FAULT=abort-after-enable in safe mode: no layer, no fault" 0

probe switch "$CMDLINE_PLAIN" APEX_SHELL_TEST_FAULT=enable PROBE_ENABLE=1 PROBE_SWITCH=3
rc_is "layer-enabled cycles: the shell goes on" 0
for cycle in 1 2 3; do
    fact "cycle $cycle: layer-enabled=false gives stock hooks and the stock colour scheme" \
        "switch\.$cycle\.false=safe=true scheme=prefer-dark witness=stock"
    fact "cycle $cycle: layer-enabled=true gives the layer back" \
        "switch\.$cycle\.true=safe=false scheme=prefer-light witness=enabled"
done
count_is "layer-enabled cycles: each switch restyles the shell once" '^probe: restyled$' 6
count_is "layer-enabled cycles: each says which shell" 'Apex: layer-enabled is false: the stock shell' 3
count_is "layer-enabled cycles: the features enable again each time" 'Apex: feature witness enabled' 4
count_is "layer-enabled cycles: a feature that failed at enable stays off for the session" 'Apex: feature fault off for this session' 1
lacks "layer-enabled cycles: every feature disables cleanly" 'did not disable cleanly|cannot restyle'
keybindings_are "layer-enabled cycles: Super+Space goes with each false and comes back with each true" \
    'add remove add remove add remove add'

probe livedisabled "$CMDLINE_PLAIN" APEX_SHELL_TEST_FAULT=configure PROBE_ENABLE=1 PROBE_DISABLE_LIVE=witness
fact "disabled-features while enabled: the feature is off at once, its hooks stock" \
    'disabled-live\.witness=witness=stock scheme=prefer-light'
fact "taken out again: the feature configures and enables afresh" \
    'disabled-live\.none=witness=enabled scheme=prefer-light'
count_is "disabled-features while enabled: it says so" 'Apex: feature witness is in disabled-features' 2
fact "disabled-features changed while the layer is off: it holds when the layer comes back" \
    'disabled-while-off=witness=stock'
count_is "a feature that failed to configure stays off: it configures once" 'Apex: feature fault off for this session' 1
lacks "disabled-features while enabled: every feature disables cleanly" 'did not disable cleanly|cannot restyle'

probe offswitch "$CMDLINE_PLAIN" PROBE_LAYER_OFF=1 PROBE_SWITCH=1
fact "a session that starts with layer-enabled=false stays stock when it turns true" \
    'switch\.1\.true=safe=true scheme=prefer-dark witness=stock'
lacks "and nothing restyles it" '^probe: restyled$'
keybindings_are "nor adds Super+Space" ''

probe bogus "$CMDLINE_PLAIN" APEX_SHELL_TEST_FAULT=everything PROBE_ENABLE=1
rc_is "FAULT=everything: runs" 0
has "FAULT=everything: names no phase" 'APEX_SHELL_TEST_FAULT=everything names no phase'
fact "FAULT=everything: no fault feature" 'test-fault=stock'

probe disabled "$CMDLINE_PLAIN" APEX_SHELL_TEST_FAULT=enable PROBE_DISABLED=fault PROBE_ENABLE=1
has "disabled-features skips a feature" 'Apex: feature fault is in disabled-features'
fact "and its hook gives stock" 'test-fault=stock'
lacks "disabled-features: a test-only feature, under APEX_SHELL_TEST_FAULT, is a feature" 'names no feature'

probe typo "$CMDLINE_PLAIN" PROBE_DISABLED=glas,dock PROBE_ENABLE=1 PROBE_DISABLE_LIVE=glas
has "disabled-features: the feature a typo misspells stays on" 'Apex: feature glass enabled'
if awk '/<key name="disabled-features"/ { key = 1 } key && /<choices>/ { found = 1 } key && /<\/key>/ { key = 0 }
    END { exit !found }' "$APEX_SCHEMA"; then
    fact "disabled-features: the schema's <choices> refuse a list with a typo" 'disabled-features='
    lacks "disabled-features: so the layer never sees it" 'names no feature'
else
    fact "disabled-features: a schema without <choices> takes a typo" 'disabled-features=glas,dock'
    has "disabled-features: the layer logs the name of no feature" 'Apex: disabled-features names no feature glas$'
    count_is "disabled-features: once, through every later change" 'names no feature glas' 1
    has "disabled-features: the real name beside it still disables its feature" 'Apex: feature dock is in disabled-features'
    lacks "disabled-features: and is not logged" 'names no feature dock'
fi

probe motion-disabled "$CMDLINE_PLAIN" PROBE_DISABLED=motion PROBE_ENABLE=1
has "disabled-features=['motion']: skips the feature" 'Apex: feature motion is in disabled-features'
fact "disabled-features=['motion']: stock's mode" 'motion\.quad=EASE_OUT_QUAD 250'
fact "disabled-features=['motion']: an actor's default stays Clutter's" 'motion\.actor-default=none 100'
fact "disabled-features=['motion']: no curve is set" 'motion\.curve=stock'
fact "disabled-features=['motion']: stock durations" 'motion\.durations=window=250 overview=250 popover=250 unknown=250'

probe quick-settings "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_QUICK_SETTINGS=1
has "quick-settings: the feature enables" 'Apex: feature quick-settings enabled'
fact "quick-settings: VPN after Airplane Mode (DESIGN's order)" \
    'qs\.order=Wi-Fi,Bluetooth,Power Mode,Night Light,Dark Style,Do Not Disturb,Airplane Mode,VPN,Auto Rotate'
fact "quick-settings: On or Off under a toggle without a subtitle; a toggle's own subtitle stays" \
    'qs\.subtitles=Wi-Fi=Home,Bluetooth=Off,Power Mode=Balanced,Night Light=Off,Dark Style=Off,Do Not Disturb=Off,Airplane Mode=Off,VPN=Off,Auto Rotate=Off'
fact "quick-settings: Power Mode lit at Balanced, its checked state stock" 'qs\.power=checked=false classes=apex-lit'
fact "quick-settings: the state follows checked; a subtitle the toggle sets wins" 'qs\.live=dnd=On bluetooth=Headphones'
fact "quick-settings: once the toggle drops its own, ours follows again" 'qs\.own-subtitle-gone=bluetooth=On'
fact "quick-settings: the active network's row is :checked, its lock after the name" 'qs\.row\.active=children=icons,label,lock,check icons=signal checked=true lock=2/apex-network-lock'
fact "quick-settings: another network's row is not" 'qs\.row\.other=children=icons,label,lock,check icons=signal checked=false lock=2/apex-network-lock'
fact "quick-settings: a submenu header's subtitle ends the title's row" 'qs\.menu=3,0 x_align=3'
fact "quick-settings: :checked follows is-active" 'qs\.row\.switched=children=icons,label,lock,check icons=signal checked=false lock=2/apex-network-lock \| children=icons,label,lock,check icons=signal checked=true lock=2/apex-network-lock'
fact "quick-settings: layer off: the row stock again" 'qs\.off\.row=children=icons,label,check icons=signal,lock checked=false lock=3/none'
fact "quick-settings: layer off: the subtitle under the title" 'qs\.off\.menu=1,1 x_align=0'
fact "quick-settings: layer off: :checked no longer follows" 'qs\.off\.row-unfollowed=checked=false'
fact "quick-settings: layer back on: rows and menus built before it change again" 'qs\.on\.row=children=icons,label,lock,check icons=signal checked=true lock=2/apex-network-lock'
fact "quick-settings: layer back on: the subtitle on the title's row" 'qs\.on\.menu=3,0 x_align=3'
fact "quick-settings: layer off: stock order" \
    'qs\.off\.order=Wi-Fi,VPN,Bluetooth,Power Mode,Night Light,Dark Style,Do Not Disturb,Airplane Mode,Auto Rotate'
fact "quick-settings: layer off: only the toggles' own subtitles" \
    'qs\.off\.subtitles=Wi-Fi=Home,VPN=-,Bluetooth=-,Power Mode=Balanced,Night Light=-,Dark Style=-,Do Not Disturb=-,Airplane Mode=-,Auto Rotate=-'
fact "quick-settings: layer off: Power Mode unlit" 'qs\.off\.power=checked=false classes=none'
fact "quick-settings: layer back on: DESIGN's order again" \
    'qs\.on\.order=Wi-Fi,Bluetooth,Power Mode,Night Light,Dark Style,Do Not Disturb,Airplane Mode,VPN,Auto Rotate'
fact "quick-settings: layer back on: lit again" 'qs\.on\.power=checked=false classes=apex-lit'

probe end-session "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_END_SESSION=1
has "end-session: the feature enables" 'Apex: feature end-session enabled'
fact "end-session: power off: Restart between Cancel and Power Off, stock's icon, the theme's gap, the row's widths" \
    'end-session\.power-off=buttons=Cancel,Restart,Power Off icon=system-shutdown-symbolic spacing=10 homogeneous=false row=true'
fact "end-session: Restart goes through stock's reboot confirmation" 'end-session\.confirmed=ConfirmedReboot'
fact "end-session: restart: no second Restart, the icon follows, an even row" \
    'end-session\.restart=buttons=Cancel,Restart icon=view-refresh-symbolic spacing=10 homogeneous=true row=false'
fact "end-session: log out: stock has no icon for it" \
    'end-session\.logout=buttons=Cancel,Log Out icon=none spacing=10 homogeneous=true row=false'
fact "end-session: layer off: stock's row and no icon, at once" \
    'end-session\.off=buttons=Cancel,Power Off icon=none spacing=12 homogeneous=true row=false'
fact "end-session: layer off: reopened, still stock" \
    'end-session\.off\.reopened=buttons=Cancel,Power Off icon=none spacing=12 homogeneous=true row=false'
fact "end-session: layer back on: board 14's row again" \
    'end-session\.on=buttons=Cancel,Restart,Power Off icon=system-shutdown-symbolic spacing=10 homogeneous=false row=true'
lacks "end-session: no feature fails or disables uncleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe end-session-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_END_SESSION=1 PROBE_DISABLED=end-session
has "disabled-features=['end-session']: skips the feature" 'Apex: feature end-session is in disabled-features'
fact "disabled-features=['end-session']: stock's power-off row" \
    'end-session\.power-off=buttons=Cancel,Power Off icon=none spacing=12 homogeneous=true row=false'

probe quick-settings-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_QUICK_SETTINGS=1 PROBE_DISABLED=quick-settings
has "disabled-features=['quick-settings']: skips the feature" 'Apex: feature quick-settings is in disabled-features'
fact "disabled-features=['quick-settings']: stock order" \
    'qs\.order=Wi-Fi,VPN,Bluetooth,Power Mode,Night Light,Dark Style,Do Not Disturb,Airplane Mode,Auto Rotate'
fact "disabled-features=['quick-settings']: Power Mode unlit" 'qs\.power=checked=false classes=none'
fact "disabled-features=['quick-settings']: a network row stays stock" 'qs\.row\.active=children=icons,label,check icons=signal,lock checked=false lock=3/none'
fact "disabled-features=['quick-settings']: the subtitle stays under the title" 'qs\.menu=1,1 x_align=0'

probe shadows "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SHADOWS=1
has "shadows: the feature enables" 'Apex: feature shadows enabled'
fact "shadows: a registered surface gets one layer from -apex-shadow-layer, its box and radius, just above its top ancestor" \
    'shadows\.registered=box-shadow: 0px 2px 8px 0px rgba\(20, 30, 60, 0\.2\); border-radius: 14px; at 106,46 300x200 above=true cutout=14'
fact "shadows: registering draws before the next frame, not inside the call" 'shadows\.before-the-frame=0'
fact "shadows: registering again keeps one layer" 'shadows\.registered-twice=1'
fact "shadows: an unmapped surface keeps no layer" 'shadows\.unmapped=none'
fact "shadows: mapped again, it draws again" \
    'shadows\.mapped-again=box-shadow: 0px 2px 8px 0px rgba\(20, 30, 60, 0\.2\); border-radius: 14px; at 106,46 300x200 above=true cutout=14'
fact "shadows: layer off: no layer drawn" 'shadows\.off=none'
fact "shadows: layer back on: the registration draws again" \
    'shadows\.on=box-shadow: 0px 2px 8px 0px rgba\(20, 30, 60, 0\.2\); border-radius: 14px; at 106,46 300x200 above=true cutout=14'
fact "shadows: a destroyed surface takes its layer with it" 'shadows\.destroyed=0 layers, root=bin'

probe shadows-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SHADOWS=1 PROBE_DISABLED=shadows
has "disabled-features=['shadows']: skips the feature" 'Apex: feature shadows is in disabled-features'
fact "disabled-features=['shadows']: a registration draws nothing" 'shadows\.registered=none'

probe spotlight-disabled "$CMDLINE_PLAIN" PROBE_DISABLED=spotlight PROBE_ENABLE=1 PROBE_PRESS=1 PROBE_OVERVIEW_SEARCH=1
has "disabled-features=['spotlight']: skips the feature" 'Apex: feature spotlight is in disabled-features'
keybindings_are "disabled-features=['spotlight']: no Super+Space binding" ''
fact "disabled-features=['spotlight']: Super+Space opens nothing" 'press\.1=overview=false spotlight=false'
fact "disabled-features=['spotlight']: no handler gets the press" 'unbound-press=toggle-spotlight'
fact "disabled-features=['spotlight']: the rest of the layer runs" 'scheme\.user\.after-enable=prefer-light'
fact "disabled-features=['spotlight']: the overview's search stays stock" 'overview-search=stock'
lacks "disabled-features=['spotlight']: and is not reset" 'overview-search\.reset'


probe spotlight-live "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_DISABLE_LIVE=spotlight
keybindings_are "spotlight in and out of disabled-features, and the layer off and on: the binding follows each change" \
    'add remove add remove add'
count_is "spotlight in disabled-features while enabled: it says so" 'Apex: feature spotlight is in disabled-features' 2
lacks "spotlight live: the feature disables cleanly" 'did not disable cleanly|cannot restyle'

probe spotlight-nochild "$CMDLINE_PLAIN" GSETTINGS_SCHEMA_DIR="$T/nochild" PROBE_ENABLE=1
fact "no Keybindings child schema: not safe mode" 'safe=false'
has "no Keybindings child schema: only spotlight is off, and says why" \
    'Apex: feature spotlight off for this session \(configure: Error: schema io\.github\.apex_linux\.Apex\.Desktop\.Keybindings is not installed\)'
count_is "no Keybindings child schema: in one log line" 'Apex: .*spotlight' 1
keybindings_are "no Keybindings child schema: no Super+Space binding" ''
fact "no Keybindings child schema: the rest of the layer runs" 'scheme\.user\.after-enable=prefer-light'
fact "no Keybindings child schema: enable still runs" 'starting-file=true'

probe spotlight-nokey "$CMDLINE_PLAIN" GSETTINGS_SCHEMA_DIR="$T/nokey" PROBE_ENABLE=1
has "a Keybindings schema without toggle-spotlight: only spotlight is off, and says why" \
    'Apex: feature spotlight off for this session \(configure: Error: schema io\.github\.apex_linux\.Apex\.Desktop\.Keybindings has no key toggle-spotlight\)'
keybindings_are "a Keybindings schema without toggle-spotlight: no Super+Space binding" ''
fact "a Keybindings schema without toggle-spotlight: the rest of the layer runs" 'scheme\.user\.after-enable=prefer-light'

readonly APPS='APPLICATIONS: Disks Disk Usage Analyzer Disk Benchmark Disk Images'
readonly SETTINGS='SETTINGS: Disk Encryption Disk Storage Removable Disks'
readonly FILES='FILES: disk-usage-2026-10.csv disk-unlock-board.png Disk Images diskspace-notes.md'
probe spotlight "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SPOTLIGHT=1
rc_is "spotlight: the probe runs" 0
fact "spotlight: an empty query shows only the field" 'spotlight\.opened=field only'
fact "spotlight: the field has the keyboard focus" 'spotlight\.focus=true'
fact "spotlight: sections in order, capped at 4 apps, 3 settings, 4 files; the first row selected, Enter to open" \
    "spotlight\.disk=APPLICATIONS: Disks\*Open Disk Usage Analyzer Disk Benchmark Disk Images \| $SETTINGS \| $FILES"
lacks "spotlight: a provider without a section shows nothing" 'Characters'
fact "spotlight: Settings rows sit on tiles: the panel's colour from settings-tiles.json, System's for its search-only pages, neutral without one" \
    'spotlight\.tiles=Disk Encryption=#3584e4 Disk Storage=#6f8396 Removable Disks=neutral'
fact "spotlight: Apex Desktop's tile is the accent" 'spotlight\.tiles-apex=Apex Desktop=accent'
fact "spotlight: Down moves across sections" \
    "spotlight\.down-4=$APPS \| SETTINGS: Disk Encryption\*Open Disk Storage Removable Disks \| $FILES"
fact "spotlight: Up moves back" \
    "spotlight\.up-1=APPLICATIONS: Disks Disk Usage Analyzer Disk Benchmark Disk Images\*Open \| $SETTINGS \| $FILES"
fact "spotlight: Down stops at the last row" \
    "spotlight\.down-20=$APPS \| $SETTINGS \| FILES: disk-usage-2026-10.csv disk-unlock-board.png Disk Images diskspace-notes.md\*Open"
fact "spotlight: Up stops at the first" "spotlight\.up-20=APPLICATIONS: Disks\*Open .*"
fact "spotlight: Enter activates the selected result through its provider, with the terms" \
    'spotlight\.activated=org\.gnome\.Settings\.desktop:privacy terms=disk'
fact "spotlight: and closes Spotlight" 'spotlight\.enter-on-a-setting=closed'
fact "spotlight: Enter on an app launches it" 'spotlight\.launched=org\.gnome\.DiskUtility\.desktop'
fact "spotlight: a sum: its result first, then Calculator as the first application" \
    'spotlight\.sum=CALCULATOR: 1920\(2880 / 1\.5\)\*Copy \| APPLICATIONS: Calculator'
fact "spotlight: Enter on the result copies it to the clipboard" 'clipboard=1:1920'
fact "spotlight: closes Spotlight" 'spotlight\.enter-on-the-sum=closed'
fact "spotlight: and shows the Copied toast" 'spotlight\.toast=Copied 1920 in-ui-group=true'
fact "spotlight: the toast goes after a moment" 'spotlight\.toast-later=gone'
fact "spotlight: the open panel registers its glass" 'spotlight\.glass-open=spotlight'
fact "spotlight: closed, its glass goes with it; the toast registers its own" 'spotlight\.glass-copied=toast'
fact "spotlight: and the toast's goes with the toast" 'spotlight\.glass-later=none'
lacks "spotlight: copying launches nothing" 'spotlight\.activated=org\.gnome\.Calculator'
fact "spotlight: a query with no results says so" 'spotlight\.none=empty "No results for “zzz”"'
fact "spotlight: Esc closes" 'spotlight\.escape=closed'
fact "spotlight: clearing the query shows only the field again" 'spotlight\.cleared=field only'
fact "spotlight: a query typed over a running one shows only the later's results" 'spotlight\.superseded=empty "No results for “zzz”"'
fact "spotlight: Super+Space inside Spotlight closes it" 'spotlight\.toggle-key=closed'
fact "spotlight: the Super tap closes it and opens the overview" 'spotlight\.overlay-key=closed overview=true'
fact "spotlight: a click outside closes it" 'spotlight\.click-outside=closed'
fact "spotlight: hovering a row selects it" "spotlight\.hover=APPLICATIONS: Disks Disk Usage Analyzer\*Open .*"
fact "spotlight: clicking a row activates it" 'spotlight\.launched=org\.gnome\.baobab\.desktop'
fact "spotlight: closing leaves no popup on the stage" 'spotlight\.stage=0'
fact "spotlight: text typed in the overview opens Spotlight with it, through 0013's hook" \
    "spotlight\.from-overview=true APPLICATIONS: Disks\*Open Disk Usage Analyzer Disk Benchmark Disk Images \| $SETTINGS \| $FILES"
fact "spotlight: and resets the overview's own search" 'spotlight\.overview-reset=yes'
fact "spotlight: while Spotlight is open the overview's search keeps its stock path" 'spotlight\.from-overview-again=false'
fact "spotlight: activating a result from the overview closes Spotlight and hides the overview" 'spotlight\.from-overview-enter=closed overview=false'
fact "spotlight: the overview's search pill taking the focus opens Spotlight with an empty field" 'spotlight\.from-overview-focus=true field only'
fact "spotlight: put in disabled-features while open, it closes and goes" 'spotlight\.live-disabled=0 popup=true'
fact "spotlight: taken out again, Super+Space opens it afresh" 'spotlight\.live-enabled=field only'
count_is "spotlight: every grab is given back" '^probe: modal\.push=' "$(grep -c '^probe: modal\.pop=' "$OUT")"
lacks "spotlight: nothing fails" 'off for this session|did not disable cleanly|Spotlight search failed|JS ERROR|Gjs-WARNING'

probe spotlight-slow "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SPOTLIGHT=slow PROBE_SPOTLIGHT_SLOW=org.gnome.Settings.desktop
fact "spotlight: a slow provider does not hold back the sections that answered" \
    "spotlight\.slow\.at-700ms=APPLICATIONS: Disks\*Open Disk Usage Analyzer Disk Benchmark Disk Images \| $FILES"
fact "spotlight: past its 1 s budget, its section is left out" \
    "spotlight\.slow\.at-1300ms=APPLICATIONS: Disks\*Open Disk Usage Analyzer Disk Benchmark Disk Images \| $FILES"
fact "spotlight: and its call is cancelled" 'spotlight\.cancelled=org\.gnome\.Settings\.desktop'

probe spotlight-late "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SPOTLIGHT=late PROBE_SPOTLIGHT_SLOW=org.gnome.Settings.desktop PROBE_SPOTLIGHT_SLOW_MS=600
fact "spotlight: within its budget, a slower section is not there yet" \
    "spotlight\.late\.at-300ms=APPLICATIONS: Disks\*Open Disk Usage Analyzer Disk Benchmark Disk Images \| $FILES"
fact "spotlight: the selection moves among the sections shown" \
    "spotlight\.late\.down-5=$APPS \| FILES: disk-usage-2026-10.csv disk-unlock-board.png\*Open Disk Images diskspace-notes.md"
fact "spotlight: the section arrives in its place, and the selection stays on its row" \
    "spotlight\.late\.at-900ms=$APPS \| $SETTINGS \| FILES: disk-usage-2026-10.csv disk-unlock-board.png\*Open Disk Images diskspace-notes.md"
lacks "spotlight: an answer within budget cancels nothing" 'spotlight\.cancelled='

probe spotlight-late-sum "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SPOTLIGHT=late-sum PROBE_SPOTLIGHT_SLOW=org.gnome.Calculator.desktop PROBE_SPOTLIGHT_SLOW_MS=600
fact "spotlight: no rows yet and the query not done: only the field, no 'No results'" 'spotlight\.late-sum\.at-300ms=field only'
fact "spotlight: a late sum still puts Calculator first among the applications" \
    'spotlight\.late-sum\.at-900ms=CALCULATOR: 1920\(2880 / 1\.5\)\*Copy \| APPLICATIONS: Calculator'

probe launcher "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_LAUNCHER=1
rc_is "launcher: the probe runs" 0
fact "launcher: outside the app grid the overview's pill is stock" 'launcher\.desktop=hint=Type to search pill=false grid'
fact "launcher: in the app grid it is the launcher's own, \"Search apps\"" 'launcher\.app-grid=hint=Search apps pill=true grid'
fact "launcher: there 0013's hook keeps typed text from the stock search" 'launcher\.hook-text=true'
fact "launcher: and leaves the focus to the stock entry" 'launcher\.hook-focus=false'
lacks "launcher: without resetting the pill" 'launcher\.reset='
fact "launcher: apps only, by name, the grid filtered in place, the first match selected" \
    'launcher\.dis=hint=Search apps pill=true Disk Usage Analyzer\*, Disks'
fact "launcher: Spotlight stays closed" 'launcher\.spotlight=false'
fact "launcher: Enter launches the first match" 'launcher\.launched=disk-usage-analyzer\.desktop'
fact "launcher: no match says so, and that Super+Space searches everything" \
    'launcher\.zzz=hint=Search apps pill=true No Results / The launcher searches apps only\. Super\+Space searches everything\.'
fact "launcher: an empty pill shows the grid again" 'launcher\.cleared=hint=Search apps pill=true grid'
fact "launcher: apps inside folders are found too" 'launcher\.folder-app=hint=Search apps pill=true Characters\*'
fact "launcher: leaving the app grid gives the stock pill and grid back" 'launcher\.left=hint=Type to search pill=false grid'
fact "launcher: and empties it" 'launcher\.left-text=""'
fact "launcher: with spotlight in disabled-features the app grid keeps the stock pill" 'launcher\.disabled=hint=Type to search pill=false grid'
fact "launcher: taken out again, the launcher's pill is back" 'launcher\.enabled-again=hint=Search apps pill=true grid'
lacks "launcher: nothing fails" 'off for this session|did not disable cleanly|JS ERROR'

readonly KEPT_PILL='remoteAccess,camera,volumeInput,location,network,volumeOutput,unsafeMode,system'
readonly STOCK_PILL='remoteAccess,camera,volumeInput,location,brightness,thunderbolt,nightLight,network,darkMode,doNotDisturb,backlight,bluetooth,rfkill,autoRotate,volumeOutput,unsafeMode,powerProfiles,system'
probe top-bar "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_TOP_BAR=1 PROBE_SCALE=2
rc_is "top bar: the probe runs" 0
has "top bar: the panel feature enables" 'Apex: feature panel enabled'
fact "workspace-dots: the active dot widens from its own width to the sheet's -apex-active-width as it expands; the others stay full size at .45" \
    'top-bar\.dots=7 15 22 inactive=\{"opacity":0\.45,"scale":1\}'
fact "status-pill: network, volume, battery, the privacy and the unsafe-mode indicators stay" "pill=$KEPT_PILL"
fact "status-pill: and so for indicators set up after enable" "pill\.set-up-after-enable=$KEPT_PILL"
fact "hot-corner: the corner becomes a reactive 4 x 4 zone at its own position, in scaled px" \
    'hot-corner\.zone=hot-corner reactive=true x=0 y=0 8x8'
fact "hot-corner: in the chrome, hidden under fullscreen windows" 'chrome\.add=hot-corner trackFullscreen=true'
count_is "hot-corner: entering it triggers the barrier once, until the pointer leaves it off the barrier" '^probe: hot-corner\.trigger=' 2
fact "hot-corner: leaving it while on the barrier keeps the barrier's trigger" 'hot-corner\.after-leave-on-the-barrier=true'
fact "layer-enabled=false: the dot hooks give stock" 'top-bar\.off\.dots=99 99 99 inactive="stock"'
fact "layer-enabled=false: the status pill gets every indicator back, in order" "pill\.off=$STOCK_PILL"
fact "layer-enabled=true: the filter again" "pill\.on=$KEPT_PILL"
count_is "both dots restyle at each enable and disable" '^probe: workspace-dot=restyled$' 6
count_is "the hot corners are rebuilt at each enable and disable" '^probe: hot-corners=rebuilt$' 3
lacks "top bar: no feature fails or disables uncleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe top-bar-rtl "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_TOP_BAR=1 PROBE_SCALE=1 PROBE_RTL=1
fact "hot-corner, right to left: the zone lies left of the corner" 'hot-corner\.zone=hot-corner reactive=true x=-4 y=0 4x4'

probe top-bar-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_TOP_BAR=1 PROBE_DISABLED=panel
has "disabled-features=['panel']: skips the feature" 'Apex: feature panel is in disabled-features'
fact "disabled-features=['panel']: the dot hooks give stock" 'top-bar\.dots=99 99 99 inactive="stock"'
fact "disabled-features=['panel']: the status pill keeps every indicator" "pill=$STOCK_PILL"
fact "disabled-features=['panel']: the corner stays stock" 'hot-corner\.zone=none reactive=false x=undefined y=undefined undefinedxundefined'
lacks "disabled-features=['panel']: nothing is rebuilt or restyled" 'hot-corners=rebuilt|workspace-dot=restyled'

probe panel-live "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_DISABLE_LIVE=panel
count_is "panel in and out of disabled-features while enabled: it says so" 'Apex: feature panel is in disabled-features' 2
count_is "panel live: the hot corners are rebuilt at each enable and disable" '^probe: hot-corners=rebuilt$' 5
lacks "panel live: the feature disables cleanly" 'off for this session|did not disable cleanly|cannot restyle'

panel_classes_are() {
    local got
    got=$(sed -n 's/^probe: set \(.*\)$/[\1]/p; s/^probe: panel\.classes=\(.*\)$/\1/p' "$OUT" | paste -sd' ' -)
    if [[ $got == "$2" ]]; then ok "$1"; else not_ok "$1 (got '$got', expected '$2')"; _show; fi
}

probe solid-bar "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SOLID_BAR=1
has "solid-bar: the panel feature enables" 'Apex: feature panel enabled'
panel_classes_are "solid-bar: the bar is solid exactly while translucent-top-bar is off and the layer on" \
    'none [translucent-top-bar=false] apex-solid-bar [translucent-top-bar=true] none [translucent-top-bar=false] apex-solid-bar [layer-enabled=false] none [layer-enabled=true] apex-solid-bar'
lacks "solid-bar: no feature fails or disables uncleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe solid-bar-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SOLID_BAR=1 PROBE_DISABLED=panel
panel_classes_are "disabled-features=['panel']: the bar stays translucent" \
    '[translucent-top-bar=false] [translucent-top-bar=true] [translucent-top-bar=false] [layer-enabled=false] [layer-enabled=true]'

probe focused-app "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_FOCUSED_APP=1
has "focused-app: the panel feature enables" 'Apex: feature panel enabled'
fact "focused-app: its item follows the Activities pill in the left box" 'panel\.add=apex-focused-app at 1 in left'
fact "focused-app: \"Desktop\" while nothing has focus, a label that takes no clicks" \
    'focused-app\.none=Desktop name=Desktop visible=true reactive=false'
fact "focused-app: the focused app's name" 'focused-app\.files=Files name=Files visible=true reactive=false'
fact "focused-app: \"Desktop\" again when focus goes" 'focused-app\.unfocused=Desktop name=Desktop visible=true reactive=false'
fact "focused-app: show-focused-app-name=false hides it" 'focused-app\.hidden=Desktop name=Desktop visible=false reactive=false'
fact "focused-app: and the lock screen" 'focused-app\.locked=Desktop name=Desktop visible=false reactive=false'
fact "focused-app: layer-enabled=false takes it out of the bar" 'focused-app\.off=none'
fact "focused-app: layer-enabled=true brings it back" 'focused-app\.on=Desktop name=Desktop visible=true reactive=false'
lacks "focused-app: no feature fails or disables uncleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe focused-app-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_FOCUSED_APP=1 PROBE_DISABLED=panel
lacks "disabled-features=['panel']: no item in the bar" 'panel\.add=apex-focused-app'
fact "disabled-features=['panel']: nothing follows the focus" 'focused-app\.files=none'

readonly SEARCH_ITEM='Search \(Super\+Space\) pill=apex-search-pill icon=system-search-symbolic'
probe search-button "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SEARCH_BUTTON=1
has "search-button: the panel feature enables" 'Apex: feature panel enabled'
fact "search-button: just before the status pill in the right box" 'panel\.add=apex-search at 2 in right'
fact "search-button: a pill with the search glyph, named for its key" "search\.enabled=$SEARCH_ITEM visible=true"
fact "search-button: hovered, its tooltip shows centred below it" 'search\.tooltip\.hover=true at 1256,32'
fact "search-button: and hides when the pointer leaves" 'search\.tooltip\.unhover=false at 1256,32'
fact "search-button: the tooltip names the key, in the chrome as dash.js's labels are" 'chrome\.add=Search \(Super\+Space\) trackFullscreen=false'
fact "search-button: a click opens Spotlight, as Super+Space does" 'search\.click\.1=overview=false spotlight=true'
fact "search-button: a second click closes it" 'search\.click\.2=overview=false spotlight=false'
fact "search-button: the lock screen hides it" "search\.locked=$SEARCH_ITEM visible=false"
fact "search-button: layer-enabled=false takes it out of the bar" 'search\.off=none'
fact "search-button: layer-enabled=true brings it back" "search\.on=$SEARCH_ITEM visible=true"
lacks "search-button: no feature fails or disables uncleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe search-no-spotlight "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SEARCH_BUTTON=1 PROBE_DISABLED=spotlight
fact "disabled-features=['spotlight']: the search button opens the overview with its search entry focused" 'search\.click\.1=overview=true spotlight=false'
fact "disabled-features=['spotlight']: and a second click hides it" 'search\.click\.2=overview=false spotlight=false'

probe search-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SEARCH_BUTTON=1 PROBE_DISABLED=panel
fact "disabled-features=['panel']: no search button" 'search\.enabled=none'
fact "disabled-features=['panel']: and Super+Space stays" 'keybinding\.add=toggle-spotlight .*'

probe maximised "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_MAXIMISED=1
panel_classes_are "solid-bar: solid while a window on the primary monitor is maximised and the overview is closed" \
    'none [maximised] apex-solid-bar [overview] none [no-overview] apex-solid-bar [minimised] none [unminimised] apex-solid-bar [unmaximised] none [other-monitor] none [desktop-window] none [workspace] apex-solid-bar [closed] none [translucent-top-bar=false] apex-solid-bar [layer-enabled=false] none [restacked]'
lacks "solid-bar: the maximised-window trigger disables cleanly" 'off for this session|did not disable cleanly|cannot restyle'

readonly GLASS_ON='panel:r96/s1.6/c0/on/background quick-settings:r120/s1.8/c52/on/background calendar:r120/s1.8/c52/on/background'
readonly GLASS_OFF='panel:none quick-settings:none calendar:none'
readonly BANNER_ON='banner:r120/s1.8/c32/on/background'
probe glass "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_GLASS=1
has "glass: the feature enables" 'Apex: feature glass enabled'
fact "glass: the bar, Quick Settings and the calendar blur behind them: radius 2 x their sheet's sigma x the scale, its saturation and corners, fine, following opacity; the offscreen redirects they sit in are held off" \
    "glass\.enabled=$GLASS_ON solid=false redirects=0,0"
fact "glass: a banner blurs from the moment it is shown" "glass\.banner=$GLASS_ON $BANNER_ON solid=false redirects=0,0"
fact "glass: the bar's glass pauses while the bar is solid" \
    "glass\.solid-bar=panel:r96/s1\.6/c0/paused/background quick-settings:r120/s1\.8/c52/on/background calendar:r120/s1\.8/c52/on/background $BANNER_ON solid=false redirects=0,0"
fact "glass: the bar's glass pauses on the lock screen and in the unlock dialog (isLocked)" \
    "glass\.locked=panel:r96/s1\.6/c0/paused/background quick-settings:r120/s1\.8/c52/on/background calendar:r120/s1\.8/c52/on/background $BANNER_ON solid=false redirects=0,0"
fact "glass: and comes back on unlock" "glass\.unlocked=$GLASS_ON $BANNER_ON solid=false redirects=0,0"
fact "glass: a closed popover's glass pauses" \
    "glass\.menu-closed=panel:r96/s1\.6/c0/on/background quick-settings:r120/s1\.8/c52/paused/background calendar:r120/s1\.8/c52/on/background $BANNER_ON solid=false redirects=0,0"
fact "glass: a second register() replaces the first's opts, one surface per actor" 'glass\.registered-twice=dock:r112/s1\.8/c44/paused/background 1'
fact "glass: another feature registers its actor, the dock's sigma 28 at 1.8, without the manager" 'glass\.registered=dock:r112/s1\.8/c44/on/background'
fact "glass: a damaged window that touches no glass box redraws none" 'glass\.damage-elsewhere=panel=0 quick-settings=0 dock=0 -> panel=0 quick-settings=0 dock=0'
fact "glass: a window moved under the bar redraws the bar's box" 'glass\.moved-under-the-bar=panel=1 quick-settings=0 dock=0'
fact "glass: moved out from under the bar and damaged under the dock, it redraws the bar once more and the dock" 'glass\.damage-under-the-dock=panel=2 quick-settings=0 dock=2'
fact "glass: a restack redraws every glass box" 'glass\.restacked=panel=3 quick-settings=1 dock=3'
fact "glass: Reduce Transparency removes every blur and roots apex-solid; the redirects come back" \
    "glass\.reduce-transparency=$GLASS_OFF banner:none solid=true redirects=2,2"
fact "glass: and the registered dock's" 'glass\.reduce-transparency\.dock=dock:none'
fact "glass: high contrast does the same" "glass\.high-contrast=$GLASS_OFF banner:none solid=true redirects=2,2"
fact "glass: disabled-features=['glass'] removes every blur and keeps the tints" "glass\.disabled=$GLASS_OFF banner:none solid=false redirects=2,2"
fact "glass: and the registered dock's" 'glass\.disabled\.dock=dock:none'
fact "glass: an actor registered while glass is off waits" 'glass\.registered-while-disabled=later:none'
fact "glass: and blurs once glass is back" 'glass\.registered-while-disabled\.enabled=later:r136/s1\.8/c52/on/background'
fact "glass: unregistered, twice, the dock loses its blur" 'glass\.unregistered=dock:none'
fact "glass: layer-enabled=false removes every blur and gives the redirects back" "glass\.off=$GLASS_OFF banner:none solid=false redirects=2,2"
fact "glass: layer-enabled=true brings the glass back" "glass\.on=$GLASS_ON $BANNER_ON solid=false redirects=0,0"
lacks "glass: no feature fails or disables uncleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe glass-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_DISABLED=glass PROBE_GLASS=1
has "disabled-features=['glass']: skips the feature" 'Apex: feature glass is in disabled-features'
fact "disabled-features=['glass']: no blur, the panel's own redirect" "glass\.enabled=$GLASS_OFF solid=false redirects=2,2"

probe glass-noreduce "$CMDLINE_PLAIN" GSETTINGS_SCHEMA_DIR="$T/noreduce" PROBE_ENABLE=1
has "a schema without reduce-transparency: only glass is off, and says why" \
    'Apex: feature glass off for this session \(configure: Error: io\.github\.apex_linux\.Apex\.Desktop has no key reduce-transparency\)'
has "and the rest of the layer runs" 'Apex: feature panel enabled'

readonly SEARCH_HINT='^probe: notify=Press Super+Space to search$'
probe search-hint "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_SWITCH=2
count_is "search hint: the first enable shows it, once, through layer-enabled cycles" "$SEARCH_HINT" 1
fact "search hint: and remembers it" 'search-hint-shown=true'
probe search-hint-shown "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_HINT_SHOWN=1
count_is "search hint: not shown again once search-hint-shown is true" "$SEARCH_HINT" 0
probe search-hint-locked "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_LOCKED=1
count_is "search hint: not on the lock screen" "$SEARCH_HINT" 0
fact "search hint: so it waits for the next unlocked enable" 'search-hint-shown=false'
probe search-hint-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_DISABLED=panel
count_is "search hint: not with disabled-features=['panel']" "$SEARCH_HINT" 0
probe search-hint-safe "$CMDLINE_PLAIN" PROBE_ENABLE=1 APEX_SHELL_SAFE=1
count_is "search hint: not in safe mode" "$SEARCH_HINT" 0
probe search-hint-nokey "$CMDLINE_PLAIN" GSETTINGS_SCHEMA_DIR="$T/nohint" PROBE_ENABLE=1 PROBE_SWITCH=1
count_is "search hint: a schema without search-hint-shown shows none" "$SEARCH_HINT" 0
count_is "search hint: and says so once" 'has no key search-hint-shown: no search hint' 1
has "search hint: the rest of the panel runs" 'Apex: feature panel enabled'

# Only GDM unlocks, after PAM succeeds: no Apex file may name a route to it.
readonly UNLOCK_ROUTES=("deactivate(" "emit('unlock'" "Unlock" "_onVerificationComplete" "finish(")
readonly UNLOCK_INJECTIONS=("Main.screenShield.deactivate(false);" "Main.screenShield.emit('unlock');"
    "this._loginManager.Unlock();" "this._userVerifier._onVerificationComplete();" "this._authPrompt.finish(() => {});")
unlock_routes() {
    local -a args=()
    local route
    for route in "${UNLOCK_ROUTES[@]}"; do args+=(-e "$route"); done
    grep -rnF "${args[@]}" -- "$1" || true
}
APEX_JS=$REPO/desktop/shell/js/ui/apex
found=$(unlock_routes "$APEX_JS")
if [[ -z $found && -f $APEX_JS/lock/stage.js ]]; then
    ok "unlock guard: nothing under js/ui/apex/ names a route to unlocking"
else
    not_ok "unlock guard: nothing under js/ui/apex/ names a route to unlocking"
    printf '#   %s\n' "$found"
fi
for i in "${!UNLOCK_ROUTES[@]}"; do
    copy=$T/guard-$i
    cp -R "$APEX_JS" "$copy"
    printf '%s\n' "${UNLOCK_INJECTIONS[$i]}" >>"$copy/lock/stage.js"
    found=$(unlock_routes "$copy")
    if [[ $found == "$copy/lock/stage.js:"*"${UNLOCK_ROUTES[$i]}"* && $(wc -l <<<"$found") == 1 ]]; then
        ok "unlock guard: catches ${UNLOCK_ROUTES[$i]} injected into a copy"
    else
        not_ok "unlock guard: catches ${UNLOCK_ROUTES[$i]} injected into a copy (found: ${found:-nothing})"
    fi
done

readonly STOCK_LOCK_LAYOUT='dialog=unlock-dialog stack=prompt-box,unlock-dialog-clock stage= clock=time,date,hint hint=true children=backgrounds,stack'
lock_is_stock() {
    local why=$1
    fact "$why: the lock screen keeps upstream's two stages" "lock\.layout=$STOCK_LOCK_LAYOUT"
    fact "$why: and opens on the clock, with no conversation" 'lock\.open=page=none prompt=none cancelled=none'
    fact "$why: blanking touches nothing" 'lock\.blank=page=none prompt=none cancelled=none'
    fact "$why: upstream's blur" 'lock\.blur=\{"brightness":0\.65,"radius":90\}'
    fact "$why: the clock slides away as upstream's" 'lock\.clock-progress=0 0\.5 1'
    fact "$why: upstream's \"Password\"" 'lock\.question\."Password:"="Password"'
    fact "$why: upstream's question, colon stripped" 'lock\.question\."Verification code:"="Verification code"'
    fact "$why: upstream's avatar icon" 'lock\.avatar\.real-name=stock'
}

probe lock "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_LOCK=1
rc_is "lock: the probe runs" 0
has "lock: the feature enables" 'Apex: feature lock enabled'
fact "lock: the unlock-dialog hook gives the stock code" 'lock\.run=undefined'
fact "lock: one stage, the clock over the prompt box, date above time, upstream's hint hidden, the overlay over the backgrounds" \
    'lock\.layout=dialog=unlock-dialog apex-lock stack=apex-lock-stage stage=unlock-dialog-clock,prompt-box clock=date,time,hint hint=false children=backgrounds,apex-lock-overlay,stack'
fact "lock: opens on the prompt with a conversation" 'lock\.open=page=prompt prompt=conversation-1 cancelled=none'
fact "lock: the unlock hint follows the prompt" 'lock\.prompt-box=conversation-1,Press Enter to unlock'
readonly HINT_PASSWORD='"Press Enter to unlock" glyph=none failed=false'
readonly HINT_SCAN='"Or touch the fingerprint reader" glyph=auth-fingerprint-symbolic failed=false'
readonly HINT_FAILED='"Fingerprint not recognized\. Try again\." glyph=auth-fingerprint-symbolic failed=true'
fact "lock: the password's hint, upstream's message line and indicator" "lock\.hint\.password=$HINT_PASSWORD message=true indicator=true"
fact "lock: gdm-fingerprint's prompt is board 20's line with the print, in place of upstream's message and indicator" \
    "lock\.hint\.fingerprint-scan=$HINT_SCAN message=false indicator=false"
fact "lock: a failed scan swaps the line's text" "lock\.hint\.fingerprint-failed=$HINT_FAILED message=false indicator=false"
fact "lock: and keeps it when upstream's queue empties" "lock\.hint\.queue-done=$HINT_FAILED message=true indicator=false"
fact "lock: the password's own problem stays in upstream's message line" \
    "lock\.hint\.password-problem=$HINT_FAILED message=true indicator=false"
fact "lock: the reader's next prompt brings the line back" "lock\.hint\.fingerprint-again=$HINT_SCAN message=false indicator=false"
fact "lock: a prompt rebuilt after blank starts on the password's hint" "lock\.hint\.after-wake=$HINT_PASSWORD message=true indicator=true"
fact "lock: blanking tears the prompt down and cancels its verifier" 'lock\.blank=page=clock prompt=none cancelled=conversation-1'
fact "lock: waking builds a new conversation" 'lock\.wake=page=prompt prompt=conversation-2 cancelled=conversation-1'
fact "lock: standby is blank too" 'lock\.standby=page=clock prompt=none cancelled=conversation-1,conversation-2'
fact "lock: and waking again builds another" 'lock\.wake-again=page=prompt prompt=conversation-3 cancelled=conversation-1,conversation-2'
fact "lock: suspend is blank too" 'lock\.suspend=page=clock prompt=none cancelled=conversation-1,conversation-2,conversation-3'
fact "lock: a display without power saving keeps a prompt" \
    'lock\.unsupported=page=prompt prompt=conversation-4 cancelled=conversation-1,conversation-2,conversation-3'
count_is "lock: each teardown is logged once, for the VM tests" '^.*Apex: lock: screen blank, prompt torn down$' 4
count_is "lock: each rebuild too" '^.*Apex: lock: screen on, prompt rebuilt$' 4
fact "lock: the hint stays after the rebuilt prompt" 'lock\.prompt-box\.after-wake=conversation-4,Press Enter to unlock'
fact "lock: locked while blank, the first conversation ends as DisplayConfig answers" \
    'lock\.open-blank=page=clock prompt=none cancelled=conversation-1'
fact "lock: and the next starts when the screen wakes" 'lock\.open-blank\.wake=page=prompt prompt=conversation-2 cancelled=conversation-1'
fact "lock: a DisplayConfig that never answers leaves the prompt up" \
    'lock\.display-config-silent=page=prompt prompt=conversation-1 cancelled=none'
fact "lock: so does one that fails" 'lock\.display-config-error=page=prompt prompt=conversation-1 cancelled=none'
has "lock: and says so" 'Apex: lock: no org\.gnome\.Mutter\.DisplayConfig, so the prompt stays at blank'
fact "lock: the clock never slides away" 'lock\.clock-progress=0 0 0'
fact "lock: blur sigma 30 (radius 60), saturation 1.3, no darkening" 'lock\.blur=\{"brightness":1,"radius":60,"saturation":1\.3\}'
fact "lock: PAM's exact \"Password:\" reads \"Enter Password\"" 'lock\.question\."Password:"="Enter Password"'
fact "lock: \"Password: \" with a space is PAM's question verbatim" 'lock\.question\."Password: "="Password: "'
fact "lock: other questions verbatim" 'lock\.question\."Verification code:"="Verification code:"'
fact "lock: without a colon too" 'lock\.question\."PIN"="PIN"'
fact "lock: lower-case \"password:\" verbatim" 'lock\.question\."password:"="password:"'
fact "lock: the avatar is the real name's initial, sized to the avatar" \
    'lock\.avatar\.real-name=A apex-avatar-initial font-size: 37px;'
fact "lock: or the user name's, upper-cased" 'lock\.avatar\.user-name=Đ apex-avatar-initial font-size: 37px;'
fact "lock: leading spaces skipped" 'lock\.avatar\.spaces=Z apex-avatar-initial font-size: 37px;'
fact "lock: no name keeps upstream's icon" 'lock\.avatar\.nobody=stock'
lacks "lock: the feature disables cleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe lock-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_LOCK=1 PROBE_DISABLED=lock
has "disabled-features=['lock']: skips the feature" 'Apex: feature lock is in disabled-features'
lock_is_stock "disabled-features=['lock']"
probe lock-safe "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_LOCK=1 APEX_SHELL_SAFE=1
lock_is_stock "APEX_SHELL_SAFE=1"
probe lock-gdm "$CMDLINE_PLAIN" PROBE_MODE=gdm PROBE_LOCK=1
fact "gdm mode: no layer" 'layer=null'
lock_is_stock "gdm mode"

readonly OVERVIEW_ON='title-visible=true overlay=close scale=0\.081 threshold=1 box=0\.081 grid=\[\{"rows":4,"columns":7\}\] icon=88 strip=0'
readonly OVERVIEW_STOCK='title-visible=false overlay=title\+close scale=0\.05 threshold=2 box=0\.05 grid="stock" icon=-1 strip=130'
readonly EMPTY_LABEL='"No open windows" \.apex-workspace-empty'
probe overview "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_OVERVIEW=1
has "overview: the overview feature enables" 'Apex: feature overview enabled'
fact "overview: titles always shown, the overlay fades only the close button; thumbnails at .081 from two workspaces; the launcher 7 columns of 88 px, with no workspace strip above it" \
    "overview\.enabled=$OVERVIEW_ON"
fact "launcher: the grid picks its mode and icon size afresh" 'overview\.enabled\.relayout=mode=-1 page-width=0'
count_is "launcher: the controls lay out again at each enable and disable, so the strip comes and goes at once" '^probe: controls=relayout$' 3
fact "workspaces: no background card, and an empty workspace says so" "workspace\.enabled\.empty=background=false $EMPTY_LABEL visible=true opacity=255"
fact "workspaces: the label goes when a window arrives" "workspace\.enabled\.window-added=background=false $EMPTY_LABEL visible=false opacity=255"
fact "workspaces: and fades with the overview" "workspace\.enabled\.half-open=background=false $EMPTY_LABEL visible=true opacity=128"
fact "workspaces: a workspace with windows hides it from the start" "workspace\.enabled\.with-windows=background=false $EMPTY_LABEL visible=false opacity=255"
fact "layer-enabled=false: the stock overview, the primary thumbnails and the launcher restored" "overview\.off=$OVERVIEW_STOCK"
fact "layer-enabled=false: workspaces keep their background and get no label" 'workspace\.off\.empty=background=true no label'
fact "layer-enabled=true: the overview again" "overview\.on=$OVERVIEW_ON"
lacks "overview: no feature fails or disables uncleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe overview-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_OVERVIEW=1 PROBE_DISABLED=overview
has "disabled-features=['overview']: skips the feature" 'Apex: feature overview is in disabled-features'
fact "disabled-features=['overview']: the stock overview and launcher" "overview\.enabled=$OVERVIEW_STOCK"
fact "disabled-features=['overview']: the grid is left alone" 'overview\.enabled\.relayout=mode=0 page-width=1272'
fact "disabled-features=['overview']: workspaces stay stock" 'workspace\.enabled\.empty=background=true no label'

probe overview-live "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_DISABLE_LIVE=overview
count_is "overview in and out of disabled-features while enabled: it says so" 'Apex: feature overview is in disabled-features' 2
lacks "overview live: the feature disables cleanly" 'off for this session|did not disable cleanly|cannot restyle'

readonly DOCK_TAIL='separator show-apps:54 trash:54'
probe dock "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_DOCK=1
has "dock: the feature enables" 'Apex: feature dock enabled'
fact "dock: the favourites, then the separator, Show Apps and Trash, at 54 (medium); dots on; the overview's dash hidden" \
    "dock\.enabled=Files:54 Web:54 $DOCK_TAIL indicators=true visible=true dash=false dash-height=0"
fact "dock: dock-icon-size small is 46" 'dock\.dock-icon-size=small=Files:46 Web:46 separator show-apps:46 trash:46 .*'
fact "dock: large is 62" 'dock\.dock-icon-size=large=Files:62 Web:62 separator show-apps:62 trash:62 .*'
fact "dock: dock-show-trash=false hides Trash" 'dock\.dock-show-trash=false=.* trash:62\(hidden\) .*'
fact "dock: dock-running-indicators=false hides the dots" 'dock\.dock-running-indicators=false=.* indicators=false .*'
fact "dock: the lock screen hides it" "dock\.locked=Files:54 Web:54 $DOCK_TAIL indicators=true visible=false dash=false dash-height=0"
fact "dock: its background registers with the glass registry as 'dock'" 'dock\.glass=dock'
fact "dock: its Show Apps opens the overview's app grid" 'dock\.show-apps=overview=true overview-button=true'
fact "dock: and follows the overview's own button" 'dock\.overview-show-apps-off=dock-button=false'
fact "dock: no separator between the dock's favourites and running apps, upstream's elsewhere; a full-colour Show Apps" \
    'dock\.hooks=separator=false stock-separator=true show-apps=view-app-grid'
fact "dock: layer-enabled=false takes it away and gives the overview its dash back, at its own height" 'dock\.off=none dash=true dash-height=-1'
fact "dock: layer-enabled=true brings it back" "dock\.on=Files:54 Web:54 $DOCK_TAIL indicators=true visible=true dash=false dash-height=0"
count_is "dock: the old dock is destroyed" '^probe: dock\.destroyed=apexDock$' 1
lacks "dock: no feature fails or disables uncleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe intellihide "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_INTELLIHIDE=1
fact "intellihide: a threshold-0 barrier on the bottom edge, under the dock, blocking downward motion" \
    'intellihide\.barrier=x=660\.\.780 y=900\.\.900 directions=8'
fact "intellihide: the pressure barrier triggers on the first hit" 'pressure-barrier=threshold=0 timeout=1000'
intellihide_steps_are() {
    local got
    got=$(sed -n 's/^probe: set \(.*\)$/[\1]/p; s/^probe: intellihide\.hidden=\(.*\)$/\1/p' "$OUT" | paste -sd' ' -)
    if [[ $got == "$2" ]]; then ok "$1"; else not_ok "$1 (got '$got', expected '$2')"; _show; fi
}
intellihide_steps_are "intellihide: hidden behind a maximised window, revealed by the edge while the pointer is on it, shown in the overview and with the key off" \
    '[initial] false [maximised] true [edge] false [pointer-elsewhere] true [edge-again] false [pointer-on-dock] false [left] true [overview] false [no-overview] true [intellihide=false] false [intellihide=true] true [closed] false [layer-enabled=false] false'
fact "intellihide: layer-enabled=false takes its barrier away" 'intellihide\.after-off=pressure-destroyed=true barrier-destroyed=true'
lacks "intellihide: no feature fails or disables uncleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe dock-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_DOCK=1 PROBE_DISABLED=dock
has "disabled-features=['dock']: skips the feature" 'Apex: feature dock is in disabled-features'
fact "disabled-features=['dock']: no dock, and the overview keeps its dash" 'dock\.enabled=none dash=true dash-height=-1'

probe dock-live "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_DISABLE_LIVE=dock
count_is "dock in and out of disabled-features while enabled: it says so" 'Apex: feature dock is in disabled-features' 2
lacks "dock live: the feature disables cleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe dock-nokey "$CMDLINE_PLAIN" GSETTINGS_SCHEMA_DIR="$T/nodock" PROBE_ENABLE=1
has "a schema without dock-show-trash: only the dock is off, and says why" \
    'Apex: feature dock off for this session \(configure: Error: io\.github\.apex_linux\.Apex\.Desktop has no key dock-show-trash\)'
has "and the rest of the layer runs" 'Apex: feature panel enabled'

probe indicators "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_INDICATORS=1 \
    PROBE_THEME_ICONS=apex-sync-symbolic,apex-chat-symbolic,apex-games
has "indicators: the feature enables" 'Apex: feature indicators enabled'
fact "indicators: the shell owns org.kde.StatusNotifierWatcher while nobody else does" 'indicators\.watcher=shell'
fact "indicators: with no items, no indicators and no divider; both sit before the status pill" \
    'indicators\.empty=hidden overflow=none divider=false order=a11y,keyboard,indicators,divider,quickSettings'
fact "indicators: four items show in the order they registered: the theme's -symbolic icon, or a full-colour icon or a pixmap as a mask" \
    'indicators\.four=File sync:symbolic,Game launcher:mask,Password manager:pixmap,Chat:symbolic overflow=none divider=true order=a11y,keyboard,indicators,divider,quickSettings'
fact "indicators: a fifth moves two to the overflow: three show, and +2" \
    'indicators\.five=File sync:symbolic,Game launcher:mask,Password manager:pixmap overflow=\+2 divider=true'
fact "indicators: a pixmap's network-order ARGB becomes RGBA" 'indicators\.pixmap=16x16 alpha=true first-pixel-rgba=10,20,30,255'
fact "indicators: the overflow menu has a row per hidden item: glyph, title, chevron; an icon the theme lacks gets the fallback" \
    'indicators\.overflow\.rows=symbolic:Chat:go-next-symbolic fallback:Media player:go-next-symbolic'
fact "indicators: a row closes the overflow menu and opens that item's menu under the overflow button" \
    'indicators\.overflow\.after-row=open=false item-menu-under=overflow'
fact "indicators: a Passive item is hidden, and four show again" \
    'indicators\.passive=File sync:symbolic,Game launcher:mask,Password manager:pixmap,Chat:symbolic overflow=none divider=true'
fact "indicators: NeedsAttention adds the dot" 'indicators\.attention=.*,Chat:symbolic\+dot overflow=none divider=true'
fact "indicators: primary click calls Activate, under the button" 'sni\.File sync\.Activate=1316 32'
fact "indicators: middle click calls SecondaryActivate" 'sni\.File sync\.SecondaryActivate=1316 32'
fact "indicators: secondary click on an item without a menu calls ContextMenu" 'sni\.File sync\.ContextMenu=1316 32'
fact "indicators: scrolling calls Scroll, vertically" 'sni\.File sync\.Scroll=-120 vertical'
fact "indicators: and horizontally" 'sni\.File sync\.Scroll=-120 horizontal'
fact "indicators: primary click on an item with a menu, not only a menu, activates it" 'sni\.Chat\.Activate=1316 32'
fact "indicators: secondary click opens the DBusMenu: the title as header, a shortcut, a switch, a separator, a submenu of radio items; hidden and disabled rows" \
    'indicators\.menu=\[Chat\] Show Chat<Ctrl\+Shift\+C> Do Not Disturb=switch:false \| Status>\(Online=radio:on Away=radio:off\) Hidden\(hidden\) Quit Chat\(off\)'
fact "indicators: the open menu's button shows as checked" 'indicators\.menu\.button-checked=true'
fact "indicators: ItemsPropertiesUpdated changes the open menu in place" \
    'indicators\.menu\.updated=\[Chat\] Show Chat Window<Ctrl\+Shift\+C> Do Not Disturb=switch:true .*'
fact "indicators: opening the menu sends opened" 'menu\.Chat\.event=0 opened'
fact "indicators: a row sends clicked" 'menu\.Chat\.event=2 clicked'
fact "indicators: a submenu sends opened" 'menu\.Chat\.event=4 opened'
fact "indicators: closing sends closed" 'menu\.Chat\.event=0 closed'
fact "indicators: and the button is no longer checked" 'indicators\.menu\.closed=open=false button-checked=false'
fact "indicators: primary click on an item that is only a menu opens it" 'indicators\.item-is-menu=\[Game launcher\] Library'
fact "indicators: an item whose app leaves the bus goes" \
    'indicators\.vanished=Game launcher:mask,Password manager:pixmap,Chat:symbolic\+dot overflow=none divider=true'
fact "indicators: disabled-features=['indicators'] takes them, the divider and the watcher away" \
    'indicators\.disabled=none watcher=none order=a11y,keyboard,quickSettings'
readonly REREGISTERED='(Password manager:pixmap|Chat:symbolic\+dot|Game launcher:mask)(,(Password manager:pixmap|Chat:symbolic\+dot|Game launcher:mask)){2} overflow=none divider=true'
fact "indicators: back out of it, the shell owns the watcher again and the items register again" \
    "indicators\.re-enabled=$REREGISTERED watcher=shell"
fact "indicators: layer-enabled=false takes them away" 'indicators\.layer-off=none watcher=none'
fact "indicators: layer-enabled=true brings them back" "indicators\.layer-on=$REREGISTERED"
lacks "indicators: the feature disables cleanly" 'off for this session|did not disable cleanly|cannot restyle'

probe indicators-remote "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_REMOTE_WATCHER=1 PROBE_THEME_ICONS=apex-sync-symbolic
fact "another process's watcher: the shell registers as a host with it" \
    'fake-watcher\.host=org\.kde\.StatusNotifierHost-apex-[0-9]+'
fact "another process's watcher: the items it lists show" 'remote\.listed=Early:symbolic overflow=none divider=true'
fact "another process's watcher: and the items it announces" 'remote\.announced=Early:symbolic,Late:symbolic overflow=none divider=true'
fact "another process's watcher: once it leaves, the shell owns the name and the items register with it" \
    'remote\.gone=(Early|Late):symbolic,(Early|Late):symbolic overflow=none divider=true watcher=shell'

probe indicators-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_DISABLED=indicators PROBE_WATCHER_OWNER=1
has "disabled-features=['indicators']: skips the feature" 'Apex: feature indicators is in disabled-features'
fact "disabled-features=['indicators']: nobody owns the watcher" 'watcher-owner=none'

probe indicators-safe "$CMDLINE_PLAIN" APEX_SHELL_SAFE=1 PROBE_ENABLE=1 PROBE_WATCHER_OWNER=1
fact "safe mode: no indicators, and nobody owns the watcher" 'watcher-owner=none'

printf '1..%d\n' "$tests"
((failed == 0))
