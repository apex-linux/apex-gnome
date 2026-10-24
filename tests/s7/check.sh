#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2016 # jq programs throughout, not shell expansions
set -uo pipefail

usage() {
    cat <<'EOF'
usage: tests/s7/check.sh main|control RUN_JSON

Asserts one accent-test.sh run: RUN_JSON holds the accents (each with its folder front and
tab colours), the deadline, the folder's name and the probe's result. main: the agent
followed each accent and Files, the file chooser and Spotlight drew the new folder colour
within the deadline. control: without the agent, all three still drew the first accent's
folders. Prints PASS or FAIL per assertion; exits 1 on any FAIL.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    main | control) mode=$1 ;;
    *) usage >&2; exit 2 ;;
esac
(($# == 2)) || { usage >&2; exit 2; }
run=$(cat -- "$2") || exit 2

readonly JQ_DEFS='
def rgb: [.[1:3], .[3:5], .[5:7]] | map(explode | map(if . >= 97 then . - 87 else . - 48 end) | .[0] * 16 + .[1]);
def near($hex): . != null and ([., ($hex | rgb)] | transpose | all(.[0] - .[1] | fabs <= 8));
def surfaces: ["files", "chooser", "spotlight"];
.accents[0] as $first | .result as $r
'

fails=0
assert() {
    if jq -e "$JQ_DEFS | $2" <<<"$run" >/dev/null 2>&1; then
        printf 'PASS %s: %s\n' "$mode" "$1"
    else
        fails=$((fails + 1))
        printf 'FAIL %s: %s (got %s)\n' "$mode" "$1" "$(jq -c "$JQ_DEFS | ${3:-\$r}" <<<"$run" 2>&1 | head -c 400)"
    fi
}

assert 'the probe ran to the end' '$r != null and $r.error == null' '$r.error'
assert "the folder's own Spotlight row was found" '$r.spotlightRow == .folder' '$r.spotlightRow'
if [[ $mode == main ]]; then
    assert 'apex-session-agent ran throughout and set the first accent'"'"'s folder theme' \
        '$r.agentRunning and $r.agentRunningAfter and $r.themeBefore == "Apex-\($first.name)"' \
        '{agentRunning: $r.agentRunning, agentRunningAfter: $r.agentRunningAfter, themeBefore: $r.themeBefore}'
    assert 'each accent change set its folder theme' \
        '($r.changes | length) == (.accents | length) - 1 and [$r.changes[].theme] == [.accents[1:][] | "Apex-\(.name)"]' \
        '[$r.changes[].theme]'
else
    assert 'the control ran without apex-session-agent, on the base theme' \
        '$r.control and ($r.agentRunning | not) and $r.themeBefore == "Apex"' \
        '{control: $r.control, agentRunning: $r.agentRunning, themeBefore: $r.themeBefore}'
fi
for surface in files chooser spotlight; do
    case $surface in
        files) label=Files ;;
        chooser) label='the file chooser' ;;
        spotlight) label=Spotlight ;;
    esac
    got="{before: \$r.surfaces.$surface.before, changes: [\$r.changes[]? | {accent, ms: .ms.$surface, after: .after.$surface}]}"
    if [[ $mode == main ]]; then
        assert "$label drew the first accent's folder, then each new accent's within the deadline, and kept it" \
            ".deadlineMs as \$d | (\$r.surfaces.$surface.before | near(\$first.front)) and
                ([.accents[1:] as \$a | \$r.changes | to_entries[] | .key as \$i | .value
                    | (.ms.$surface | . != null and . <= \$d) and (.after.$surface | near(\$a[\$i].front))] | all)" "$got"
    else
        assert "$label drew the first accent's folder and kept it through both changes" \
            "(\$r.surfaces.$surface.before | near(\$first.front)) and
                ([\$r.changes[] | .ms.$surface == null and (.after.$surface | near(\$first.front))] | all)" "$got"
    fi
done
jq -r 'select(.result.changes) | .result.changes[] | "accent \(.accent): " +
    (.ms | to_entries | map("\(.key) \(.value // "-") ms") | join(", "))' <<<"$run" 2>/dev/null
((fails == 0))
