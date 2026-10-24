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
for tool in gjs glib-compile-schemas "${GI_COMPILER:-gi-compile-repository}"; do
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
cp "$HERE"/stubs/*.js "$T/"
# gjs outside the shell has no St or Clutter typelib: the features get stubs instead.
find "$T/shell/js/ui/apex" -name '*.js' -exec sed -i \
    -e "s|'gi://St'|'file://$T/St.js'|" -e "s|'gi://Clutter'|'file://$T/Clutter.js'|" {} +
for gir in "$HERE"/fixtures/*.gir; do
    gir_name=${gir##*/}
    "$GI_COMPILER" "$gir" -o "$T/typelib/${gir_name%.gir}.typelib"
done
cp "$SCHEMA_DIR"/*.gschema.xml "$T/schemas/"
glib-compile-schemas --strict "$T/schemas"
awk '/<child name="keybindings"/ { next }
    /<schema id="io\.github\.apex_linux\.Apex\.Desktop\.Keybindings"/ { skip = 1 }
    !skip { print }
    skip && /<\/schema>/ { skip = 0 }' "$SCHEMA_DIR/io.github.apex_linux.Apex.Desktop.gschema.xml" \
    >"$T/nochild/io.github.apex_linux.Apex.Desktop.gschema.xml"
glib-compile-schemas --strict "$T/nochild"

readonly CMDLINE_PLAIN='BOOT_IMAGE=(hd0,gpt2)/boot/ostree/apex/vmlinuz root=UUID=0 rw rhgb quiet'
sandbox=0
printf '%s\n' "$CMDLINE_PLAIN" >"$T/cmdline.check"
if command -v bwrap >/dev/null 2>&1 &&
    bwrap --dev-bind / / --ro-bind "$T/cmdline.check" /proc/cmdline /usr/bin/true 2>/dev/null; then
    sandbox=1
fi

# A case's runtime and config directories outlive it, so the guard and a later case of
# the same name see what its shell left there.
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
        APEX_SHELL_DIR="$T/shell" "$@" gjs -m "$HERE/probe.js")
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
has "spotlight: a press opens the overview with its search entry focused" '^probe: overview=shown, search focused$'
fact "spotlight: so the overview is up" 'press\.1=overview=true'
fact "spotlight: pressed again while it is up, it hides the overview" 'press\.2=overview=false'
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

probe spotlight-disabled "$CMDLINE_PLAIN" PROBE_DISABLED=spotlight PROBE_ENABLE=1 PROBE_PRESS=1
has "disabled-features=['spotlight']: skips the feature" 'Apex: feature spotlight is in disabled-features'
keybindings_are "disabled-features=['spotlight']: no Super+Space binding" ''
fact "disabled-features=['spotlight']: Super+Space opens nothing" 'press\.1=overview=false'
fact "disabled-features=['spotlight']: no handler gets the press" 'unbound-press=toggle-spotlight'
fact "disabled-features=['spotlight']: the rest of the layer runs" 'scheme\.user\.after-enable=prefer-light'

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

readonly KEPT_PILL='remoteAccess,camera,volumeInput,location,network,volumeOutput,unsafeMode,system'
readonly STOCK_PILL='remoteAccess,camera,volumeInput,location,brightness,thunderbolt,nightLight,network,darkMode,doNotDisturb,backlight,bluetooth,rfkill,autoRotate,volumeOutput,unsafeMode,powerProfiles,system'
probe top-bar "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_TOP_BAR=1 PROBE_SCALE=2
rc_is "top bar: the probe runs" 0
for feature in workspace-dots hot-corner status-pill; do
    has "top bar: $feature enables" "Apex: feature $feature enabled"
done
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

probe top-bar-disabled "$CMDLINE_PLAIN" PROBE_ENABLE=1 PROBE_TOP_BAR=1 PROBE_DISABLED=workspace-dots,hot-corner,status-pill
fact "disabled-features: the dot hooks give stock" 'top-bar\.dots=99 99 99 inactive="stock"'
fact "disabled-features: the status pill keeps every indicator" "pill=$STOCK_PILL"
fact "disabled-features: the corner stays stock" 'hot-corner\.zone=none reactive=false x=undefined y=undefined undefinedxundefined'
lacks "disabled-features: nothing is rebuilt or restyled" 'hot-corners=rebuilt|workspace-dot=restyled'

printf '1..%d\n' "$tests"
((failed == 0))
