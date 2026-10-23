#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Each case is one gjs process, because safe mode is decided once per process.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
# The apex-desktop checkout, for the schema and the crash guard.
DESKTOP_SRC=${APEX_DESKTOP_SRC:-$REPO}
NO_SKIP=${APEX_LAYER_TESTS_NO_SKIP:-0}
GUARD_UNIT=$DESKTOP_SRC/desktop/systemd/user/apex-shell-safe.service

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

for tool in gjs glib-compile-schemas; do
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
mkdir -p "$T/schemas" "$T/noschema" "$T/data" "$T/home" "$T/shell"
# The layer restyles the shell through main.js, which only the gnome-shell tree has.
cp -R "$REPO/desktop/shell/js" "$T/shell/"
printf '%s\n' "export const sessionMode = {_sync: () => printerr('probe: restyled')};" >"$T/shell/js/ui/main.js"
cp "$DESKTOP_SRC"/desktop/schemas/*.gschema.xml "$T/schemas/"
glib-compile-schemas --strict "$T/schemas"

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
        GSETTINGS_BACKEND=memory GSETTINGS_SCHEMA_DIR="$T/schemas"
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

probe default "$CMDLINE_PLAIN" PROBE_ENABLE=1
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

if ((sandbox)); then
    probe kernel "BOOT_IMAGE=/vmlinuz root=UUID=0 rw apex.safe=1 rhgb quiet" PROBE_ENABLE=1
    rc_is "apex.safe=1: runs" 0
    fact "apex.safe=1 on the kernel command line: safe" 'safe=true'
    has "apex.safe=1: and says why" 'Apex: safe mode \(apex\.safe=1\)'
    fact "apex.safe=1: no layer" 'layer=null'
    fact "apex.safe=1: the stock colour scheme" 'scheme\.user=prefer-dark'
    lacks "apex.safe=1: no crash guard marker without a layer" 'starting-file'
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

probe bogus "$CMDLINE_PLAIN" APEX_SHELL_TEST_FAULT=everything PROBE_ENABLE=1
rc_is "FAULT=everything: runs" 0
has "FAULT=everything: names no phase" 'APEX_SHELL_TEST_FAULT=everything names no phase'
fact "FAULT=everything: no fault feature" 'test-fault=stock'

probe disabled "$CMDLINE_PLAIN" APEX_SHELL_TEST_FAULT=enable PROBE_DISABLED=fault PROBE_ENABLE=1
has "disabled-features skips a feature" 'Apex: feature fault is in disabled-features'
fact "and its hook gives stock" 'test-fault=stock'

printf '1..%d\n' "$tests"
((failed == 0))
