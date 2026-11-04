#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run by apex-shell-safe.service when GNOME Shell's unit fails: turns the layer off on a failure in
# its first 60 s, or the second later one on the deployment recorded at boot in BOOTED, else none.

set -euo pipefail

(($# >= 2 && $# <= 3)) || { echo "usage: apex-shell-guard MARKER STATE_DIR [BOOTED]" >&2; exit 2; }
marker=$1 state=$2 booted=${3:-/run/apex/booted-deployment}
counter=$state/shell-guard-trips
schema=io.github.apex_linux.Apex.Desktop

deployment() {
    local id=
    [[ -r $booted ]] && read -r id <"$booted"
    [[ $id =~ ^[0-9a-f]+\.[0-9]+$ ]] && echo "$id" || echo none
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
