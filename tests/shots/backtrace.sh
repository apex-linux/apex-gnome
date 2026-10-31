# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

# case_backtrace LOG RC HOME BT: a shell that died on a signal (RC above 128) gets BT: crash.c's
# frames from LOG, then gdb's backtrace of its core in HOME (its working dir), or why there is none.
case_backtrace() {
    local log=$1 rc=$2 cores=$3 bt=$4 core shell frames pattern
    ((rc > 128)) || return 0
    {
        printf 'signal %d, the shell exited %d\n' "$((rc - 128))" "$rc"
        sed -n '/^APEXG2-CRASH .*\[[0-9]*\] SIG/,/^APEXG2-CRASH end$/p' "$log"
        core=$(find "$cores" -maxdepth 1 -type f \( -name core -o -name 'core.[0-9]*' \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1)
        core=${core#* }
        shell=$(command -v gnome-shell)
        pattern=$(cat /proc/sys/kernel/core_pattern 2>/dev/null)
        if [[ -z $core && $pattern == '|'*systemd-coredump* ]] && command -v coredumpctl >/dev/null; then
            coredumpctl --no-pager debug --debugger-arguments='-batch -ex "thread apply all bt full"' "$shell" 2>&1 ||
                printf 'no backtrace: coredumpctl has no core of %s\n' "$shell"
        elif [[ -z $core ]]; then
            printf 'no backtrace: no core in %s (core_pattern %s, ulimit -Hc %s)\n' "$cores" "$pattern" "$(ulimit -Hc)"
        elif ! command -v gdb >/dev/null && ! dnf5 -y -q --setopt=install_weak_deps=False install gdb >/dev/null 2>&1; then
            printf 'no backtrace: gdb missing, and dnf5 could not install it (core kept: %s)\n' "$core"
        else
            # debuginfod has Fedora's builds; the lane's own gnome-shell has none, which gdb names.
            frames=$(DEBUGINFOD_URLS=${DEBUGINFOD_URLS:-https://debuginfod.fedoraproject.org/} \
                gdb -batch -iex 'set debuginfod enabled on' -ex bt -ex 'thread apply all bt full' "$shell" "$core" 2>&1 |
                grep -v '^Downloading ')
            printf '%s\n' "$frames"
            grep -q 'Missing separate debuginfo\|No debugging symbols found\|No symbol table info available' <<<"$frames" &&
                printf 'no debuginfo for some frames: see the lines above\n'
            rm -f -- "$core"
        fi
    } >"$bt" 2>&1
}
