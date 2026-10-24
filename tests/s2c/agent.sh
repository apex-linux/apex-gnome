#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"
# shellcheck source=SCRIPTDIR/../lib/pins.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/pins.sh"

usage() {
    cat <<EOF
usage: tests/s2c/agent.sh

Builds apex-session-agent from apex-system $APEX_SYSTEM_REV (or APEX_SYSTEM_SRC, a
checkout) with cargo --locked --release, as root in a throwaway fedora:$APEX_FEDORA
container. The binary lands in _build/s2c/apex-session-agent.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 2 ;;
esac
((EUID == 0)) || die "agent.sh runs as root in a fedora:$APEX_FEDORA container"

git_() { git -c safe.directory='*' "$@"; }

group "Tools"
dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install \
    rust cargo gcc git-core glib2-devel pkgconf-pkg-config >/dev/null
endgroup

build=$APEX_ROOT/_build/s2c
mkdir -p -- "$build"
src=${APEX_SYSTEM_SRC:-$build/apex-system}
if [[ -z ${APEX_SYSTEM_SRC:-} ]]; then
    group "apex-system $APEX_SYSTEM_REV"
    [[ -d $src/.git ]] || git_ init -q "$src"
    if [[ $(git_ -C "$src" rev-parse -q --verify HEAD 2>/dev/null) != "$APEX_SYSTEM_REV" ]]; then
        git_ -C "$src" fetch -q --depth 1 "$APEX_SYSTEM_URL" "$APEX_SYSTEM_REV"
        git_ -C "$src" checkout -q --detach "$APEX_SYSTEM_REV"
    fi
    endgroup
fi

group "apex-session-agent"
CARGO_TARGET_DIR=$build/cargo cargo build -q --locked --release -p apex-session-agent \
    --manifest-path "$src/Cargo.toml"
install -m 755 "$build/cargo/release/apex-session-agent" "$build/apex-session-agent"
endgroup
log "agent.sh: ${build#"$APEX_ROOT/"}/apex-session-agent"
