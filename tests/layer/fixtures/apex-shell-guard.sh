#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run by apex-shell-safe.service when GNOME Shell's unit fails: turns the layer off on a failure in
# its first 60 s, or the second later one on a deployment (none without ostree=, as in a container).

set -euo pipefail

(($# >= 2 && $# <= 4)) || { echo "usage: apex-shell-guard MARKER STATE_DIR [CMDLINE [ROOT]]" >&2; exit 2; }
marker=$1 state=$2 cmdline=${3:-/proc/cmdline} root=${4:-}
counter=$state/shell-guard-trips
schema=io.github.apex_linux.Apex.Desktop

# The booted deployment as ostree names it, <checksum>.<serial>: boot.N paths and their
# bootcsum repeat across updates that keep the kernel, the deploy directory does not.
deployment() {
    local args arg target
    read -ra args <"$cmdline"
    for arg in "${args[@]}"; do
        [[ $arg == ostree=* ]] && target=${arg#ostree=}
    done
    if [[ -n ${target:-} ]] && target=$(realpath -e -- "$root$target" 2>/dev/null); then
        basename -- "$target"
    else
        echo none
    fi
}

trip() {
    gsettings set "$schema" layer-enabled false
    mkdir -p -- "$state"
    touch -- "$state/shell-guard-tripped"
    rm -f -- "$marker" "$counter"
}

if [[ ${MONITOR_EXIT_CODE:-} == exited && ${MONITOR_EXIT_STATUS:-} == 1 ]]; then
    exit 0
fi
[[ $(gsettings get "$schema" layer-enabled) == true ]] || exit 0
if [[ -e $marker ]]; then
    trip
    exit 0
fi

id=$(deployment)
count=0
if [[ -r $counter ]]; then
    read -r seen n <"$counter" || true
    [[ ${seen:-} == "$id" && ${n:-} =~ ^[0-9]+$ ]] && count=$n
fi
count=$((count + 1))
if ((count >= 2)); then
    trip
else
    mkdir -p -- "$state"
    printf '%s %s\n' "$id" "$count" >"$counter.tmp"
    mv -f -- "$counter.tmp" "$counter"
fi
