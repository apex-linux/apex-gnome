#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fedora 45's updates-testing as its GA push will make it stable, for next-point.yml alone.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=SCRIPTDIR/../../tests/lib/pins.sh
. "$APEX_ROOT/tests/lib/pins.sh"

readonly ADMIT_ALL='*'
readonly SHIM=${NEXT_POINT_SHIM:-/usr/local/bin/dnf5}
readonly REAL_DNF5=${NEXT_POINT_DNF5:-/usr/bin/dnf5}
readonly WATCHED=(gnome-shell mutter gdm gjs glib2 gnome-session gsettings-desktop-schemas gtk4 libadwaita)

usage() {
    cat <<EOF
usage: .github/scripts/next-point.sh COMMAND

  image DIR   apex-image $APEX_IMAGE_REV in DIR, its updates-testing allowlist admitting
              every build ($ADMIT_ALL), for lane.sh's APEX_IMAGE_SRC. apex-lane then builds from
              updates-testing's SRPM on a buildroot that has it.
  shim        installs $SHIM, which runs 'next-point.sh dnf5' ahead of $REAL_DNF5 on PATH
  dnf5 ARG... $REAL_DNF5 with updates-testing beside each --repo=updates and
              updates-testing-source beside each --repo=updates-source; with no --repo at all,
              --enable-repo=updates-testing. The scripts' own repositories stay as written.
  versions    a Markdown table of ${WATCHED[*]}: stable, and with updates-testing

It never touches lane.sh's cache: next-point.yml runs lane.sh without APEX_LANE_CACHE.
EOF
}

dnf5_() {
    local a repo=0 args=()
    for a in "$@"; do
        args+=("$a")
        case $a in
            --repo=updates) args+=(--repo=updates-testing) ;;
            --repo=updates-source) args+=(--repo=updates-testing-source) ;;
        esac
        [[ $a != --repo=* ]] || repo=1
    done
    ((repo)) || args=(--enable-repo=updates-testing "${args[@]}")
    exec "$REAL_DNF5" "${args[@]}"
}

image() {
    local dir=$1
    git_() { git -c safe.directory='*' "$@"; }
    [[ -d $dir/.git ]] || git_ init -q "$dir"
    git_ -C "$dir" fetch -q --depth 1 "$APEX_IMAGE_URL" "$APEX_IMAGE_REV" || die "cannot fetch apex-image $APEX_IMAGE_REV"
    git_ -C "$dir" checkout -q --detach -f "$APEX_IMAGE_REV"
    grep -Eq '^ARG GA_REACHED=0$' "$dir/image/Containerfile" ||
        die "apex-image $APEX_IMAGE_REV has passed its admission cut: updates-testing is no longer what GA brings"
    printf '%s\n' "$ADMIT_ALL" >"$dir/image/packages/updates-testing-allowlist.txt"
    log "next-point: apex-image $APEX_IMAGE_REV in $dir admits every updates-testing build"
}

shim() {
    printf '#!/bin/sh\nexec %q dnf5 "$@"\n' "$APEX_ROOT/.github/scripts/next-point.sh" >"$SHIM"
    chmod 0755 "$SHIM"
    [[ $(command -v dnf5) == "$SHIM" ]] || die "$SHIM is not the dnf5 on PATH ($(command -v dnf5))"
}

newest() {
    "$REAL_DNF5" -q repoquery "${@:2}" --latest-limit=1 --arch=x86_64,noarch --qf '%{name}-%{version}-%{release}\n' "$1" 2>/dev/null | tail -n 1
}

versions() {
    local p stable testing
    printf '| Package | Stable | With updates-testing |\n|---|---|---|\n'
    for p in "${WATCHED[@]}"; do
        stable=$(newest "$p" --repo=fedora --repo=updates)
        testing=$(newest "$p" --repo=fedora --repo=updates --repo=updates-testing)
        printf '| %s | %s | %s%s |\n' "$p" "${stable:-none}" "${testing:-none}" "$([[ $stable == "$testing" ]] || echo ' (moves)')"
    done
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    dnf5) dnf5_ "${@:2}" ;;
    image) (($# == 2)) || { usage >&2; exit 2; }; image "$2" ;;
    shim) shim ;;
    versions) versions ;;
    *) usage >&2; exit 2 ;;
esac
