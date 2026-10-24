#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# apex-lane's container half on packaging/pkgs/nautilus, as the builder VM runs it, without signing or the store.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

readonly APEX_IMAGE_URL=https://github.com/apex-linux/apex-image
readonly APEX_IMAGE_REV=3b1ba1ec31d424d9cc6d63918d60e0abf8ceebbc
readonly PKG=nautilus
readonly SOURCE1_DIR=desktop/nautilus
readonly SOURCE1_MTIME=@946684800
readonly LANE_PATHS=(/src /recipes /work /store)

usage() {
    cat <<EOF
usage: tests/nautilus/lane.sh

Builds apex-lane from apex-image $APEX_IMAGE_REV (or APEX_IMAGE_SRC, a checkout) and
runs 'apex-lane in-container build $PKG': Fedora 45's SRPM, spec-edit, the series with
fuzz 0, the exact-tree check, rpmbuild -ba with %check, the lane checks and check.sh.
Runs as root in a throwaway fedora:45 container, as the lane does: it creates
${LANE_PATHS[*]}. The RPMs land in _build/nautilus/out/.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 2 ;;
esac

((EUID == 0)) || die "lane.sh runs as root in a fedora:$APEX_FEDORA container (just nautilus-lane)"
for p in "${LANE_PATHS[@]}"; do
    [[ ! -e $p || -L $p ]] || die "$p exists and is not a link; run lane.sh in a throwaway container"
done

git_() { git -c safe.directory='*' "$@"; }

group "Tools"
dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install \
    rust cargo gcc git-core tar >/dev/null
endgroup

build=$APEX_ROOT/_build/nautilus
mkdir -p -- "$build"

src=${APEX_IMAGE_SRC:-$build/apex-image}
if [[ -z ${APEX_IMAGE_SRC:-} ]]; then
    group "apex-image $APEX_IMAGE_REV"
    [[ -d $src/.git ]] || git_ init -q "$src"
    if [[ $(git_ -C "$src" rev-parse -q --verify HEAD 2>/dev/null) != "$APEX_IMAGE_REV" ]]; then
        git_ -C "$src" fetch -q --depth 1 "$APEX_IMAGE_URL" "$APEX_IMAGE_REV"
        git_ -C "$src" checkout -q --detach "$APEX_IMAGE_REV"
    fi
    endgroup
fi

group "apex-lane"
lane_tree=$(git_ -C "$src" rev-parse HEAD:crates/apex-lane)
CARGO_TARGET_DIR=$build/cargo APEX_LANE_TREE=$lane_tree \
    cargo build -q --release --locked -p apex-lane --manifest-path "$src/Cargo.toml"
lane=$build/cargo/release/apex-lane
"$lane" --version
endgroup

containerfile_arg() { sed -n "s/^ARG $1=//p" "$src/image/Containerfile"; }
repos_base=$(containerfile_arg REPOS_BASE)
ga_reached=$(containerfile_arg GA_REACHED)
[[ -n $repos_base && $ga_reached =~ ^[01]$ ]] || die "cannot read REPOS_BASE and GA_REACHED from apex-image"

# The working tree's desktop/nautilus, so a local run needs no commit; CI's tree is HEAD's.
index=$(mktemp)
trap 'rm -f -- "$index"' EXIT
GIT_INDEX_FILE=$index git_ -C "$APEX_ROOT" read-tree HEAD
GIT_INDEX_FILE=$index git_ -C "$APEX_ROOT" add -A -- "$SOURCE1_DIR"
tree=$(GIT_INDEX_FILE=$index git_ -C "$APEX_ROOT" write-tree --prefix="$SOURCE1_DIR/")
archive=apex-${SOURCE1_DIR##*/}-${tree:0:12}.tar

work=$build/work
rm -rf -- "$work" "$build/store"
mkdir -p -- "$work/in" "$build/store"
git_ -C "$APEX_ROOT" archive --format=tar --mtime="$SOURCE1_MTIME" -o "$work/in/$archive" "$tree"

ln -sfn -- "$src" /src
ln -sfn -- "$APEX_ROOT" /recipes
ln -sfn -- "$work" /work
ln -sfn -- "$build/store" /store

args=(in-container build "$PKG" --n 1 --tool "lane.sh-$APEX_IMAGE_REV"
    --repos-base "$repos_base" --ga-reached "$ga_reached"
    --source1 "$archive" --source1-tree "$tree")
in_github_actions && args+=(--github)
status=0
"$lane" "${args[@]}" || status=$?

rm -rf -- "$build/out"
cp -a -- "$work/out" "$build/out"
case $status in
    0) log "lane.sh: $PKG built; RPMs and logs in ${build#"$APEX_ROOT/"}/out" ;;
    3) die "lane.sh: no shippable build: $(sed -n '1p' "$build/out/failed.txt" 2>/dev/null)" ;;
    *) die "lane.sh: apex-lane exited $status" ;;
esac
