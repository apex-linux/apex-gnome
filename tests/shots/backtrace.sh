# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

readonly BACKTRACE_BUDGET_S=120

# case_backtrace LOG RC HOME BT [EXPECTED]: a shell that died on a signal it was not expected to (RC above
# 128) gets BT: crash.c's frames from LOG, then gdb's backtrace of its core in HOME, or why there is none.
case_backtrace() {
    local log=$1 rc=$2 cores=$3 bt=$4 expected=${5:-0} core shell frames start=$SECONDS
    local -a cores_found
    mapfile -t cores_found < <(find "$cores" -maxdepth 1 -type f \( -name core -o -name 'core.[0-9]*' \) -printf '%T@ %p\n' \
        2>/dev/null | sort -rn | cut -d' ' -f2-)
    if ((rc <= 128 || rc == expected)); then
        rm -f -- "${cores_found[@]}"
        return 0
    fi
    left() {
        local seconds=$((BACKTRACE_BUDGET_S - (SECONDS - start)))
        echo $((seconds > 0 ? seconds : 1))
    }
    {
        printf 'signal %d, the shell exited %d\n' "$((rc - 128))" "$rc"
        sed -n '/^APEXG2-CRASH .*\[[0-9]*\] SIG/,/^APEXG2-CRASH end$/p' "$log"
        core=${cores_found[0]:-}
        shell=$(command -v gnome-shell)
        if [[ -z $core ]]; then
            printf 'no backtrace: no core in %s (core_pattern %s, ulimit -Hc %s)\n' "$cores" \
                "$(cat /proc/sys/kernel/core_pattern 2>/dev/null)" "$(ulimit -Hc)"
        elif ! command -v gdb >/dev/null &&
            ! timeout "$(left)" dnf5 -y -q --setopt=install_weak_deps=False install gdb >/dev/null 2>&1; then
            printf 'no backtrace: gdb missing, and dnf5 could not install it in %d s (core kept: %s)\n' \
                "$BACKTRACE_BUDGET_S" "$core"
        else
            # debuginfod has Fedora's builds; the lane's own gnome-shell has none, which gdb names.
            frames=$(DEBUGINFOD_URLS=${DEBUGINFOD_URLS:-https://debuginfod.fedoraproject.org/} DEBUGINFOD_MAXTIME=60 \
                DEBUGINFOD_MAXSIZE=500000000 timeout "$(left)" gdb -batch -iex 'set debuginfod enabled on' -ex bt \
                -ex 'thread apply all bt full' "$shell" "$core" 2>&1 | grep -v '^Downloading ')
            printf '%s\n' "$frames"
            ((SECONDS - start < BACKTRACE_BUDGET_S)) ||
                printf 'no backtrace past this point: gdb ran out of the %d s budget\n' "$BACKTRACE_BUDGET_S"
            grep -q 'Missing separate debuginfo\|No debugging symbols found\|No symbol table info available' <<<"$frames" &&
                printf 'no debuginfo for some frames: see the lines above\n'
            rm -f -- "${cores_found[@]}"
        fi
    } >"$bt" 2>&1
}
