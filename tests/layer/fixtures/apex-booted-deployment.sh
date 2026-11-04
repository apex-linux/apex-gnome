#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run early at boot by apex-booted-deployment.service: bootc rewrites the boot.N entry that
# ostree= names after boot, so apex-shell-guard reads the deployment from OUT instead.

set -euo pipefail

(($# >= 1 && $# <= 3)) || { echo "usage: apex-booted-deployment OUT [CMDLINE [ROOT]]" >&2; exit 2; }
out=$1 cmdline=${2:-/proc/cmdline} root=${3:-}

# The deployment as ostree names it, <checksum>.<serial>: boot.N paths and their bootcsum
# repeat across updates that keep the kernel, the deploy directory does not.
read -ra args <"$cmdline"
for arg in "${args[@]}"; do
    [[ $arg == ostree=* ]] && target=${arg#ostree=}
done
# Without ostree=, as in a container, OUT stays missing and the guard keys 'none'.
[[ -n ${target:-} ]] && target=$(realpath -e -- "$root$target" 2>/dev/null) || exit 0
mkdir -p -- "$(dirname -- "$out")"
basename -- "$target" >"$out.tmp"
mv -f -- "$out.tmp" "$out"
