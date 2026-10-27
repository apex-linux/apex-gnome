#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# signoff.yml's pull-request gate: touches=true when a changed path on stdin can change what signoff.sh
# captures (the shell, its recipe, the scenes, fixtures and pins); the matches go to the job log.

set -euo pipefail

readonly RENDERED='^(desktop/shell/|packaging/pkgs/gnome-shell/|tests/shots/|tests/shell/|tests/lib/|tests/layer/fixtures/|\.github/workflows/signoff\.yml$)'
readonly NOT_RENDERED='^tests/shots/(README\.md|selftest\.sh|assert\.sh|stable\.sh)$'

rendered=$(grep -E "$RENDERED" | grep -Ev "$NOT_RENDERED" || true)
if [[ -n $rendered ]]; then
    printf 'signoff-paths: the captures may change with:\n%s\n' "$rendered" >&2
    echo touches=true
else
    echo 'signoff-paths: nothing the captures render changed' >&2
    echo touches=false
fi
