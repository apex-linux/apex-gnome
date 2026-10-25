#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/backdrops.sh

G2's default backdrops, as root in a throwaway container: apex-desktop's Facets wallpapers,
light and dark, at /usr/share/backgrounds/apex/apex-facets-{light,dark}.png, where an Apex
image (and signoff.sh's apex-desktop) installs them. When both are already there it does
nothing; otherwise it renders them from the apex-desktop of tests/lib/pins.sh, or from
APEX_DESKTOP_SRC (a checkout), as apex-desktop.spec's %build does. direct.sh sets them on
every case and refuses to run without them.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
esac
[[ -e /run/.containerenv || -e /.dockerenv ]] || { echo "backdrops.sh: only inside a throwaway container" >&2; exit 2; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
# shellcheck source=tests/lib/pins.sh
. "$REPO/tests/lib/pins.sh"
readonly BACKGROUNDS=/usr/share/backgrounds/apex
readonly WIDTH=3840
readonly HEIGHT=2400

die() { echo "backdrops.sh: $*" >&2; exit 1; }

if [[ -s $BACKGROUNDS/apex-facets-light.png && -s $BACKGROUNDS/apex-facets-dark.png ]]; then
    echo "backdrops.sh: the Facets backdrops are already in $BACKGROUNDS"
    exit 0
fi
command -v rsvg-convert >/dev/null && command -v git >/dev/null ||
    dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install librsvg2-tools git-core ||
    die "cannot install librsvg2-tools and git-core"
desktop=${APEX_DESKTOP_SRC:-$(mktemp -d)}
if [[ -z ${APEX_DESKTOP_SRC:-} ]]; then
    git -c safe.directory='*' init -q "$desktop"
    git -c safe.directory='*' -C "$desktop" fetch -q --depth 1 "$APEX_DESKTOP_URL" "$APEX_DESKTOP_REV" ||
        die "cannot fetch apex-desktop $APEX_DESKTOP_REV"
    git -c safe.directory='*' -C "$desktop" checkout -q --detach FETCH_HEAD
fi
mkdir -p "$BACKGROUNDS"
for variant in light dark; do
    rsvg-convert -w "$WIDTH" -h "$HEIGHT" -o "$BACKGROUNDS/apex-facets-$variant.png" \
        "$desktop/desktop/wallpapers/apex-facets-$variant.svg" || die "cannot render the $variant Facets wallpaper"
done
echo "backdrops.sh: rendered the Facets backdrops of apex-desktop ${APEX_DESKTOP_SRC:-$APEX_DESKTOP_REV} into $BACKGROUNDS"
