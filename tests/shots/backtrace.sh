# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

readonly BACKTRACE_BUDGET_S=${BACKTRACE_BUDGET_S:-120}
readonly BACKTRACE_KILL_S=${BACKTRACE_KILL_S:-10}
BACKTRACE_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
readonly BACKTRACE_DIR

crash_lib() {
    gcc -O2 -Wall -Werror -shared -fPIC -o "$1" "$BACKTRACE_DIR/crash.c"
}

# shell_crash LOG RC: when RC is a signal exit, says so and where its .bt is, and succeeds; a crash fails its case.
shell_crash() {
    local bt=${1%.log}.bt
    (($2 > 128)) || return 1
    printf 'the shell crashed (SIG%s); see %s\n' "$(kill -l "$(($2 - 128))")" "${bt#"${APEX_ROOT:-}/"}"
}

# case_backtrace LOG RC HOME BT [EXPECTED]: a shell that died on a signal it was not expected to (RC above
# 128) gets BT: crash.c's frames from LOG, then gdb's backtrace of its core in HOME, or why there is none.
case_backtrace() {
    local log=$1 rc=$2 cores=$3 bt=$4 expected=${5:-0} core shell quick frames status start=$SECONDS
    local -a cores_found
    mapfile -t cores_found < <(find "$cores" -maxdepth 1 -type f \( -name core -o -name 'core.[0-9]*' \) -printf '%T@ %p\n' \
        2>/dev/null | sort -rn | cut -d' ' -f2-)
    if ((rc <= 128 || rc == expected)); then
        rm -f -- "${cores_found[@]}"
        return 0
    fi
    # Every tool shares one budget: once it is spent, the next one does not start.
    bounded() {
        local seconds=$((BACKTRACE_BUDGET_S - (SECONDS - start)))
        ((seconds > 0)) || return 124
        timeout -k "$BACKTRACE_KILL_S" "$seconds" "$@"
    }
    {
        printf 'signal %d, the shell exited %d\n' "$((rc - 128))" "$rc"
        sed -n '/^APEXG2-CRASH .*\[[0-9]*\] SIG/,/^APEXG2-CRASH end$/p' "$log"
        core=${cores_found[0]:-}
        shell=$(command -v gnome-shell)
        status=0
        command -v gdb >/dev/null || [[ -z $core ]] ||
            bounded dnf5 -y -q --setopt=install_weak_deps=False install gdb >/dev/null 2>&1 || status=$?
        if [[ -z $core ]]; then
            printf 'no backtrace: no core in %s (core_pattern %s, ulimit -Hc %s)\n' "$cores" \
                "$(cat /proc/sys/kernel/core_pattern 2>/dev/null)" "$(ulimit -Hc)"
        elif ! command -v gdb >/dev/null; then
            printf 'no backtrace: gdb missing, and dnf5 could not install it (status %d after %d s; core kept: %s)\n' \
                "$status" "$((SECONDS - start))" "$core"
        else
            # The crashing thread's frames first, without symbols to fetch, in case the full pass runs out.
            quick=$(bounded gdb -batch -iex 'set debuginfod enabled off' -ex bt "$shell" "$core" 2>&1) || status=$?
            [[ -z $quick ]] || printf '%s\n' "$quick"
            frames=$(DEBUGINFOD_URLS=${DEBUGINFOD_URLS:-https://debuginfod.fedoraproject.org/} DEBUGINFOD_MAXTIME=60 \
                DEBUGINFOD_MAXSIZE=500000000 bounded gdb -batch -iex 'set debuginfod enabled on' -ex bt \
                -ex 'thread apply all bt full' "$shell" "$core" 2>&1 | grep -v '^Downloading '
                exit "${PIPESTATUS[0]}") || status=$?
            [[ -z $frames ]] || printf '%s\n' "$frames"
            ((status != 124 && status != 137)) ||
                printf 'no backtrace: gdb ran out of the %d s budget\n' "$BACKTRACE_BUDGET_S"
            grep -q 'Missing separate debuginfo\|No debugging symbols found\|No symbol table info available' <<<"$quick$frames" &&
                printf 'no debuginfo for some frames: see the lines above\n'
            rm -f -- "${cores_found[@]}"
        fi
    } >"$bt" 2>&1
}
