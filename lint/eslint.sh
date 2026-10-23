#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
NO_SKIP=${APEX_LINT_NO_SKIP:-0}

for tool in node npm git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        [[ $NO_SKIP == 1 ]] && { printf 'eslint: %s not found, but APEX_LINT_NO_SKIP=1\n' "$tool" >&2; exit 1; }
        printf 'eslint: SKIP (%s not found)\n' "$tool" >&2
        exit 0
    fi
done

if [[ ! -e $HERE/node_modules/.package-lock.json || $HERE/package-lock.json -nt $HERE/node_modules/.package-lock.json ]]; then
    npm ci --prefix "$HERE" --ignore-scripts --no-audit --no-fund
fi

cd "$REPO"
"$HERE/node_modules/.bin/eslint" --config lint/eslint.config.js --max-warnings 0 \
    desktop/shell/js tests/layer/*.js tests/shots/*.js
printf 'eslint: clean\n' >&2
