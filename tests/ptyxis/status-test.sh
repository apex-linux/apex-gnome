#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The sessions' status logic (apex-session-state.c) under GLib's test framework.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

if ! command -v gcc >/dev/null || ! pkg-config --exists glib-2.0 2>/dev/null; then
    [[ -z ${APEX_PTYXIS_TESTS_NO_SKIP:-} ]] || die "status-test.sh: gcc and glib2-devel are required"
    warn "status-test.sh: skipped, no gcc or glib2-devel"
    exit 0
fi

src=$APEX_ROOT/desktop/ptyxis/src/apex
bin=$(mktemp)
trap 'rm -f -- "$bin"' EXIT
# shellcheck disable=SC2046 # pkg-config prints separate flags
gcc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -o "$bin" \
    "$APEX_ROOT/tests/ptyxis/status-test.c" "$src/apex-session-state.c" -I"$src" \
    $(pkg-config --cflags --libs glib-2.0)
"$bin"
