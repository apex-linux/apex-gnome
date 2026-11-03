#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Software Updates page's and the Power group's logic (cc-apex-updates-state.c, cc-apex-power-state.c) under
# GLib's test framework.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

if ! command -v gcc >/dev/null || ! command -v xgettext >/dev/null || ! pkg-config --exists glib-2.0 2>/dev/null; then
    [[ -z ${APEX_CONTROL_CENTER_TESTS_NO_SKIP:-} ]] || die "state-test.sh: gcc, gettext and glib2-devel are required"
    warn "state-test.sh: skipped, no gcc, gettext or glib2-devel"
    exit 0
fi

src=$APEX_ROOT/desktop/control-center/panels/apex
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
printf '#define GETTEXT_PACKAGE "gnome-control-center-2.0"\n' >"$work/config.h"
# shellcheck disable=SC2046 # pkg-config prints separate flags
gcc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -o "$work/state-test" \
    "$APEX_ROOT/tests/control-center/state-test.c" "$src/cc-apex-updates-state.c" "$src/cc-apex-power-state.c" \
    -I"$src" -I"$work" -lm \
    $(pkg-config --cflags --libs glib-2.0)
TZ=UTC "$work/state-test"

# English shows the same words with or without the mapping, so the kinds' C_() markers are checked as xgettext sees them.
xgettext --from-code=UTF-8 --keyword=C_:1c,2 -o "$work/state.pot" "$src/cc-apex-updates-state.c"
for kind in added removed upgraded downgraded; do
    grep -Pzq "msgctxt \"package change\"\nmsgid \"$kind\"\n" "$work/state.pot" ||
        die "state-test.sh: the change kind \"$kind\" is not marked for translation"
done
