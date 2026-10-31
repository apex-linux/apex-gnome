#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib.sh"

PTYXIS_TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly PTYXIS_TESTS
readonly SHOTS=(light dark split-light split-dark large split-large)
# GNOME's Large Text, and how much it must at least grow the rows' titles to have taken.
readonly LARGE=1.25 GROWN=1.15

usage() {
    cat <<EOF
usage: tests/ptyxis/layout-test.sh [SHOTS_DIR]

Boards 32 and 33's layout in shoot.sh's captures, at the design's text size and with GNOME's
Large Text ($LARGE, the large and split-large scenes), which APEX_PTYXIS_TARGETS=1 has it take
with contrast-atspi.py's targets (SHOTS_DIR, by default _build/ptyxis/shots). layout.py fails
a session's title, a time, a count, a group heading or a header label cut short, two of a
row's or a header's labels over each other, and a label outside the window. A row's subtitle
may end in an ellipsis: the design cuts it. Large Text must grow the rows' titles by
${GROWN}x, so apex.css's sizes follow it. It needs python3 and jq.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
shots=${1:-$APEX_ROOT/_build/ptyxis/shots}

python3 "$PTYXIS_TESTS/layout.py" --selftest || die "layout-test.sh: layout.py's selftest failed"

failures=0
fail() {
    failures=$((failures + 1))
    log "FAIL - $*"
}
frame() {
    sed -n 's/.*APEXPTYXIS \({.*}\)$/\1/p' "$shots/$1.log" | jq -r ".frame[$2]"
}
# layout SHOT [TARGETS]: layout.py's problems with SHOT, on its own targets or on TARGETS.
layout() {
    python3 "$PTYXIS_TESTS/layout.py" "$shots/$1.png" "${2:-$shots/$1.targets.json}" "$(frame "$1" 2)" "$(frame "$1" 3)"
}
for shot in "${SHOTS[@]}"; do
    [[ -s $shots/$shot.targets.json && $(frame "$shot" 2) =~ ^[0-9]+$ ]] ||
        die "layout-test.sh: no targets for $shot; run shoot.sh with APEX_PTYXIS_TARGETS=1"
    jq -e '[.targets[] | select(.kind == "text")] | length > 0 and all(.text != null)' \
        "$shots/$shot.targets.json" >/dev/null || fail "$shot: a label has no laid-out text"
    problems=$(layout "$shot")
    if [[ -z $problems ]]; then
        log "ok - $shot: nothing cut short, over another label or outside the window"
    else
        while IFS= read -r line; do fail "$shot: $line"; done <<<"$problems"
    fi
done

titles() {
    jq '[.targets[] | select(.slot == "title") | .text[3]] | add / length' "$shots/$1.targets.json"
}
light=$(titles light) large=$(titles large)
if jq -en "$large >= $light * $GROWN" >/dev/null; then
    log "ok - large: Large Text grows the rows' titles from $light px to $large px"
else
    fail "large: Large Text leaves the rows' titles at $large px against $light px"
fi

# The checks themselves: a session's title whose text runs to its box's edge must fail.
if layout large <(jq '(first(.targets[] | select(.slot == "title"))) |= (.text[2] = .box[0] + .box[2] - .text[0])' \
    "$shots/large.targets.json") | grep -q 'is cut short$'; then
    log "ok - a session's title cut short fails"
else
    fail "a session's title cut short passes the checks"
fi

((failures == 0)) || die "layout-test.sh: $failures check(s) failed; see ${shots#"$APEX_ROOT/"}/*.targets.json"
log "layout-test.sh: boards 32 and 33 lay out at the design's text size and under Large Text"
