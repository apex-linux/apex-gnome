#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# apex-lane's arguments from apex-image's image/Containerfile, one per line; no root needed.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

usage() {
    cat <<EOF2
usage: tests/lib/image-args.sh CONTAINERFILE

Prints --repos-base and the ARG REPOS_BASE of CONTAINERFILE, then --ga-reached and its
ARG GA_REACHED (0 or 1) while the Containerfile has one: apex-image's admission cut
deletes the ARG once GA is reached, and apex-lane then takes the flag as given.
EOF2
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    "" | -*) usage >&2; exit 2 ;;
esac
readonly CONTAINERFILE=$1
[[ -f $CONTAINERFILE ]] || die "image-args.sh: no $CONTAINERFILE"

arg() { sed -n "s/^ARG $1=//p" "$CONTAINERFILE"; }
repos_base=$(arg REPOS_BASE)
[[ -n $repos_base ]] || die "image-args.sh: no ARG REPOS_BASE in $CONTAINERFILE"
args=(--repos-base "$repos_base")
if grep -Eq '^ARG GA_REACHED([= ]|$)' "$CONTAINERFILE"; then
    ga_reached=$(arg GA_REACHED)
    [[ $ga_reached =~ ^[01]$ ]] || die "image-args.sh: ARG GA_REACHED in $CONTAINERFILE is '$ga_reached', not 0 or 1"
    args+=(--ga-reached "$ga_reached")
fi
printf '%s\n' "${args[@]}"
