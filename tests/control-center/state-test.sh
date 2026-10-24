#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Software Updates page's logic (cc-apex-updates-state.c) under GLib's test framework.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

if ! command -v gcc >/dev/null || ! pkg-config --exists glib-2.0 2>/dev/null; then
    [[ -z ${APEX_CONTROL_CENTER_TESTS_NO_SKIP:-} ]] || die "state-test.sh: gcc and glib2-devel are required"
    warn "state-test.sh: skipped, no gcc or glib2-devel"
    exit 0
fi

src=$APEX_ROOT/desktop/control-center/panels/apex
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
printf '#define GETTEXT_PACKAGE "gnome-control-center-2.0"\n' >"$work/config.h"
# shellcheck disable=SC2046 # pkg-config prints separate flags
gcc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -o "$work/state-test" \
    "$APEX_ROOT/tests/control-center/state-test.c" "$src/cc-apex-updates-state.c" -I"$src" -I"$work" \
    $(pkg-config --cflags --libs glib-2.0)
TZ=UTC "$work/state-test"
