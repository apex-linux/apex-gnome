#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# apex-lane's container half on a recipe of packaging/pkgs, as the builder VM runs it, without signing or the store.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"
# shellcheck source=SCRIPTDIR/pins.sh
. "$(dirname "${BASH_SOURCE[0]}")/pins.sh"

readonly SOURCE1_MTIME=@946684800
readonly LANE_PATHS=(/src /recipes /work /store)

usage() {
    cat <<EOF
usage: tests/lib/lane.sh PKG

Builds apex-lane from apex-image $APEX_IMAGE_REV (or APEX_IMAGE_SRC, a checkout) and
runs 'apex-lane in-container build PKG' on packaging/pkgs/PKG: Fedora 45's SRPM,
spec-edit, the series with fuzz 0, the exact-tree check, rpmbuild -ba with %check, the
lane checks and check.sh. Source1 is the working tree's source1= directory, so a local
run needs no commit. Runs as root in a throwaway fedora:45 container, as the lane does:
it creates ${LANE_PATHS[*]}. The RPMs land in _build/PKG/out/.

APEX_LANE_CACHE names a directory kept between runs (CI's actions/cache): the apex-lane
binary, dnf's package cache, and the last build by its apex-lane content key.
When 'apex-lane in-container key' gives a key the cache holds, and every RPM matches its
manifest sha256, that build is reused, as the builder VM reuses a stored key.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    "" | -*) usage >&2; exit 2 ;;
esac
readonly PKG=$1
readonly RECIPE=$APEX_ROOT/packaging/pkgs/$PKG
[[ -f $RECIPE/pkg.env ]] || die "no $RECIPE/pkg.env"
SOURCE1_DIR=$(sed -n 's/^source1=//p' "$RECIPE/pkg.env")
readonly SOURCE1_DIR

((EUID == 0)) || die "lane.sh runs as root in a fedora:$APEX_FEDORA container (just pkg-lane $PKG)"
for p in "${LANE_PATHS[@]}"; do
    [[ ! -e $p || -L $p ]] || die "$p exists and is not a link; run lane.sh in a throwaway container"
done

git_() { git -c safe.directory='*' "$@"; }

cache=${APEX_LANE_CACHE:-}
if [[ -n $cache ]]; then
    mkdir -p -- "$cache/bin" "$cache/dnf" "$cache/builds"
    cache=$(cd -- "$cache" && pwd)
    # dnf keeps what it downloads in the cache: the tools, the build dependencies, the SRPM.
    rm -rf /var/cache/libdnf5 && ln -s -- "$cache/dnf" /var/cache/libdnf5
    grep -q '^keepcache=' /etc/dnf/dnf.conf || printf 'keepcache=True\n' >>/etc/dnf/dnf.conf
fi

group "Tools"
dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install \
    gcc git-core tar >/dev/null
endgroup

build=$APEX_ROOT/_build/$PKG
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
lane=$build/cargo/release/apex-lane
if [[ -n $cache && -x $cache/bin/apex-lane-$lane_tree ]]; then
    lane=$cache/bin/apex-lane-$lane_tree
else
    dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install rust cargo >/dev/null
    CARGO_TARGET_DIR=$build/cargo APEX_LANE_TREE=$lane_tree \
        cargo build -q --release --locked -p apex-lane --manifest-path "$src/Cargo.toml"
    [[ -z $cache ]] || cp -- "$lane" "$cache/bin/apex-lane-$lane_tree"
fi
"$lane" --version
endgroup

image_lines=$("$APEX_ROOT/tests/lib/image-args.sh" "$src/image/Containerfile") || die "cannot read apex-image's Containerfile"
mapfile -t image_args <<<"$image_lines"

work=$build/work
rm -rf -- "$work" "$build/store"
mkdir -p -- "$work/in" "$build/store"
source1_args=()
if [[ -n $SOURCE1_DIR ]]; then
    # The working tree's Source1 directory, so a local run needs no commit; CI's tree is HEAD's.
    index=$(mktemp)
    trap 'rm -f -- "$index"' EXIT
    GIT_INDEX_FILE=$index git_ -C "$APEX_ROOT" read-tree HEAD
    GIT_INDEX_FILE=$index git_ -C "$APEX_ROOT" add -A -- "$SOURCE1_DIR"
    tree=$(GIT_INDEX_FILE=$index git_ -C "$APEX_ROOT" write-tree --prefix="$SOURCE1_DIR/")
    archive=apex-${SOURCE1_DIR##*/}-${tree:0:12}.tar
    git_ -C "$APEX_ROOT" archive --format=tar --mtime="$SOURCE1_MTIME" -o "$work/in/$archive" "$tree"
    source1_args=(--source1 "$archive" --source1-tree "$tree")
fi

ln -sfn -- "$src" /src
ln -sfn -- "$APEX_ROOT" /recipes
ln -sfn -- "$work" /work
ln -sfn -- "$build/store" /store

common=("$PKG" --n 1 --tool "lane.sh-$APEX_IMAGE_REV" "${image_args[@]}" "${source1_args[@]}")
in_github_actions && common+=(--github)

# reusable KEY: the cache's build of KEY, if its key and every file the manifest lists check out.
reusable() {
    local dir=$cache/builds/$PKG/$1 kind sha file
    [[ -f $dir/manifest.txt && $(cat -- "$dir/key.txt" 2>/dev/null) == "$1" ]] || return 1
    while read -r kind _ sha file; do
        [[ $kind == built || $kind == apex-srpm ]] || continue
        [[ $(sha256sum -- "$dir/$file" 2>/dev/null | cut -d' ' -f1) == "$sha" ]] || return 1
    done < <(grep -v '^#' "$dir/manifest.txt")
}

key=
if [[ -n $cache ]]; then
    key=$("$lane" in-container key "${common[@]}" | tail -n 1)
    log "lane.sh: $PKG's content key is $key"
fi
rm -rf -- "$build/out"
if [[ -n $key ]] && reusable "$key"; then
    cp -a -- "$cache/builds/$PKG/$key" "$build/out"
    log "lane.sh: $PKG reused the build of $key: the key covers every input but the buildroot, as on the builder VM"
    [[ -z ${GITHUB_OUTPUT:-} ]] || echo "built=false" >>"$GITHUB_OUTPUT"
    exit 0
fi

status=0
"$lane" in-container build "${common[@]}" || status=$?

cp -a -- "$work/out" "$build/out"
if ((status == 0)) && [[ -n $cache ]]; then
    rm -rf -- "${cache:?}/builds/$PKG" && mkdir -p -- "$cache/builds/$PKG"
    cp -a -- "$build/out" "$cache/builds/$PKG/$(cat -- "$build/out/key.txt")"
    [[ -z ${GITHUB_OUTPUT:-} ]] || echo "built=true" >>"$GITHUB_OUTPUT"
fi
case $status in
    0) log "lane.sh: $PKG built; RPMs and logs in ${build#"$APEX_ROOT/"}/out" ;;
    3) die "lane.sh: no shippable build: $(sed -n '1p' "$build/out/failed.txt" 2>/dev/null)" ;;
    *) die "lane.sh: apex-lane exited $status" ;;
esac
