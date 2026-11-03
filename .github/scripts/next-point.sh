#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fedora 45's updates-testing as its GA push will make it stable, for next-point.yml alone.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=SCRIPTDIR/../../tests/lib/pins.sh
. "$APEX_ROOT/tests/lib/pins.sh"

readonly SHIM=${NEXT_POINT_SHIM:-/usr/local/bin/dnf5}
readonly REAL_DNF5=${NEXT_POINT_DNF5:-/usr/bin/dnf5}
readonly WATCHED=(gnome-shell mutter gdm gjs glib2 gnome-session gsettings-desktop-schemas gtk4 libadwaita
    gnome-control-center nautilus ptyxis vte291-gtk4)

usage() {
    cat <<EOF
usage: .github/scripts/next-point.sh COMMAND

  image DIR   apex-image $APEX_IMAGE_REV in DIR, reopened (below), its updates-testing
              allowlist admitting the builds of ${WATCHED[*]} that
              updates-testing moves, for lane.sh's APEX_IMAGE_SRC: apex-lane then builds from
              updates-testing's SRPM on a buildroot that has them. Every build would overflow
              apex-lane's dnf5 arguments.
  allowlist FILE
              the builds of ${WATCHED[*]} that updates-testing moves, one per line, into
              FILE; none at all ("nothing moves") leaves it empty, and the lanes build the
              stable ones. A failed or empty query of either side dies instead
  reopen CONTAINERFILE
              sets ARG GA_REACHED=0 in that copy's Containerfile, adding the ARG if the admission
              cut deleted it: next-point keeps watching updates-testing after GA
  shim        installs $SHIM, which runs 'next-point.sh dnf5' ahead of $REAL_DNF5 on PATH
  dnf5 ARG... $REAL_DNF5 with updates-testing beside each --repo=updates and
              updates-testing-source beside each --repo=updates-source; with no --repo at all,
              --enable-repo=updates-testing. The scripts' own repositories stay as written.
  versions    a Markdown table of ${WATCHED[*]}: stable, and with updates-testing
  counts KIND LOG
              PASSED/FAILED from LOG, or ? when LOG has none: g2 and goldens read the last
              '# N passed, M failed' line (patched.sh's, goldens.sh's), tap counts the TAP
              lines (tests/shell/shoot.sh's, the only ones in signoff.sh's output, or
              tests/control-center/run.sh's and tests/nautilus/shoot.sh's); shoot is tap

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
    reopen "$dir/image/Containerfile"
    allowlist "$dir/image/packages/updates-testing-allowlist.txt"
}

# After F45's GA apex-image sets GA_REACHED=1 or deletes the ARG, and apex-lane then admits
# nothing from updates-testing; the next point release still waits there, so the copy reopens it.
reopen() {
    local containerfile=$1
    [[ -f $containerfile ]] || die "no $containerfile"
    if grep -Eq '^ARG GA_REACHED=' "$containerfile"; then
        sed -i -E 's/^ARG GA_REACHED=.*/ARG GA_REACHED=0/' "$containerfile"
    else
        sed -i '1i ARG GA_REACHED=0' "$containerfile"
    fi
    log "next-point: $containerfile admits updates-testing (GA_REACHED=0), as before GA"
}

shim() {
    printf '#!/bin/sh\nexec %q dnf5 "$@"\n' "$APEX_ROOT/.github/scripts/next-point.sh" >"$SHIM"
    chmod 0755 "$SHIM"
    [[ $(command -v dnf5) == "$SHIM" ]] || die "$SHIM is not the dnf5 on PATH ($(command -v dnf5))"
}

# newest PKG REPO...: PKG's newest NEVR there; fails when dnf5 fails or finds none.
newest() {
    local out
    out=$("$REAL_DNF5" -q repoquery "${@:2}" --latest-limit=1 --arch=x86_64,noarch --qf '%{name}-%{version}-%{release}\n' "$1") ||
        return 1
    out=$(tail -n 1 <<<"$out")
    [[ -n $out ]] && printf '%s\n' "$out"
}

moved() {
    local p stable testing
    for p in "${WATCHED[@]}"; do
        stable=$(newest "$p" --repo=fedora --repo=updates) ||
            die "cannot ask fedora and updates for $p: dnf5 failed or found no build"
        testing=$(newest "$p" --repo=fedora --repo=updates --repo=updates-testing) ||
            die "cannot ask updates-testing for $p: dnf5 failed or found no build"
        [[ $testing == "$stable" ]] || printf '%s\n' "$testing"
    done
}

# An empty allowlist is apex-lane's "admit nothing", so the lanes build the stable ones.
allowlist() {
    local file=$1 moved
    moved=$(moved)
    printf '%s' "${moved:+$moved$'\n'}" >"$file"
    if [[ -n $moved ]]; then
        log "next-point: updates-testing moves $(paste -sd ' ' <<<"$moved")"
    else
        log "next-point: updates-testing moves none of ${WATCHED[*]} (nothing moves): the lanes build the stable ones"
    fi
}

versions() {
    local p stable testing
    printf '| Package | Stable | With updates-testing |\n|---|---|---|\n'
    for p in "${WATCHED[@]}"; do
        stable=$(newest "$p" --repo=fedora --repo=updates) || stable=''
        testing=$(newest "$p" --repo=fedora --repo=updates --repo=updates-testing) || testing=''
        printf '| %s | %s | %s%s |\n' "$p" "${stable:-none}" "${testing:-none}" "$([[ $stable == "$testing" ]] || echo ' (moves)')"
    done
}

counts() {
    local kind=$1 log=$2
    case $kind in
        g2 | goldens)
            sed -nE 's/^# ([0-9]+) passed, ([0-9]+) failed.*/\1\/\2/p' "$log" 2>/dev/null | tail -n 1 | grep . || echo '?' ;;
        shoot | tap)
            awk '/^ok / { ok++ } /^not ok / { bad++ } END { print (ok + bad ? ok + 0 "/" bad + 0 : "?") }' "$log" 2>/dev/null || echo '?' ;;
        *) usage >&2; exit 2 ;;
    esac
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    dnf5) dnf5_ "${@:2}" ;;
    image) (($# == 2)) || { usage >&2; exit 2; }; image "$2" ;;
    allowlist) (($# == 2)) || { usage >&2; exit 2; }; allowlist "$2" ;;
    reopen) (($# == 2)) || { usage >&2; exit 2; }; reopen "$2" ;;
    shim) shim ;;
    versions) versions ;;
    counts) (($# == 3)) || { usage >&2; exit 2; }; counts "$2" "$3" ;;
    *) usage >&2; exit 2 ;;
esac
