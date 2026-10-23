#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compiles the three sheets as the rebuilt gnome-shell's meson does: sassc -a on upstream's
# entry files, with 0001-build's @import hooks and desktop/shell/data/theme/apex/ in place.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
NO_SKIP=${APEX_LINT_NO_SKIP:-0}
SHEETS=(gnome-shell-light gnome-shell-dark gnome-shell-high-contrast)

skip() {
    [[ $NO_SKIP == 1 ]] && { printf 'theme: %s, but APEX_LINT_NO_SKIP=1\n' "$*" >&2; exit 1; }
    printf 'theme: SKIP (%s)\n' "$*" >&2
    exit 0
}

tools=(sassc git)
[[ -z ${GNOME_SHELL_SRC:-} ]] && tools+=(dnf5 rpm2cpio cpio tar xz)
for tool in "${tools[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || skip "$tool not found"
done

T=$(mktemp -d "${TMPDIR:-/tmp}/apex-theme.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir "$T/srpm" "$T/tree"

if [[ -n ${GNOME_SHELL_SRC:-} ]]; then
    cp -R "$GNOME_SHELL_SRC/data" "$T/tree/"
else
    (cd "$T/srpm" && dnf5 -q download --source --repo=fedora --repo=updates gnome-shell)
    srpm=("$T"/srpm/gnome-shell-*.src.rpm)
    printf 'theme: %s\n' "${srpm[0]##*/}" >&2
    (cd "$T/srpm" && rpm2cpio "${srpm[0]}" | cpio -i --quiet 'gnome-shell-*.tar.*' '*.patch')
    tar -xf "$T"/srpm/gnome-shell-*.tar.* -C "$T/tree" --strip-components=1 --wildcards '*/data/theme/*'
    # Fedora's own patches come first in %prep; only their theme hunks matter here.
    for patch in "$T"/srpm/*.patch; do
        [[ -e $patch ]] || continue
        if [[ -n $(git apply --numstat --include='data/theme/*' "$patch") ]]; then
            printf 'theme: applying the data/theme/ hunks of %s\n' "${patch##*/}" >&2
            (cd "$T/tree" && git apply --include='data/theme/*' "$patch")
        fi
    done
fi

theme=$T/tree/data/theme
[[ -d $theme/apex ]] && { printf 'theme: upstream already has data/theme/apex/\n' >&2; exit 1; }
cp -R "$REPO/desktop/shell/data/theme/apex" "$theme/apex"
(cd "$T/tree" && git apply --include='data/theme/*.scss' "$REPO/packaging/pkgs/gnome-shell/patches/0001-build.patch")

failed=0
for sheet in "${SHEETS[@]}"; do
    rc=0
    (cd "$theme" && sassc -a "$sheet.scss" "$T/$sheet.css") 2>"$T/$sheet.err" || rc=$?
    if ((rc != 0)) || [[ -s $T/$sheet.err ]]; then
        printf 'theme: %s.scss: sassc exited %d, or warned\n' "$sheet" "$rc" >&2
        cat "$T/$sheet.err" >&2
        failed=1
    else
        printf 'theme: %s.css, %d bytes\n' "$sheet" "$(wc -c <"$T/$sheet.css")" >&2
    fi
done
exit "$failed"
