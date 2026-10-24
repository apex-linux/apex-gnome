#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE

usage() {
    cat <<'EOF'
usage: tests/s7/selftest.sh

check.sh against recorded runs, without a shell: a passing main run and a passing control
pass every assertion, and each change below fails exactly one. Needs jq.
EOF
}
case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac

# shellcheck disable=SC2016 # a jq program
readonly ACCENTS='[{name: "blue", front: "#3584e4", tab: "#245a9b"},
    {name: "green", front: "#3a944a", tab: "#276532"}, {name: "pink", front: "#d56199", tab: "#914268"}]'
readonly BLUE='[53, 132, 228]' GREEN='[58, 148, 74]' PINK='[213, 97, 153]'
readonly MAIN_RUN="{accents: $ACCENTS, deadlineMs: 1000, folder: \"apexs7\", result: {
    control: false, agentRunning: true, agentRunningAfter: true, themeBefore: \"Apex-blue\", spotlightRow: \"apexs7\",
    surfaces: {files: {icon: 96, before: $BLUE}, chooser: {icon: 16, before: $BLUE}, spotlight: {icon: 32, before: $BLUE}},
    changes: [
        {accent: \"green\", theme: \"Apex-green\", ms: {files: 212, chooser: 230, spotlight: 118},
            after: {files: $GREEN, chooser: $GREEN, spotlight: $GREEN}},
        {accent: \"pink\", theme: \"Apex-pink\", ms: {files: 205, chooser: 221, spotlight: 109},
            after: {files: $PINK, chooser: $PINK, spotlight: $PINK}}]}}"
readonly CONTROL_RUN="{accents: $ACCENTS, deadlineMs: 1000, folder: \"apexs7\", result: {
    control: true, agentRunning: false, agentRunningAfter: false, themeBefore: \"Apex\", spotlightRow: \"apexs7\",
    surfaces: {files: {icon: 96, before: $BLUE}, chooser: {icon: 16, before: $BLUE}, spotlight: {icon: 32, before: $BLUE}},
    changes: [
        {accent: \"green\", theme: \"Apex\", ms: {files: null, chooser: null, spotlight: null},
            after: {files: $BLUE, chooser: $BLUE, spotlight: $BLUE}},
        {accent: \"pink\", theme: \"Apex\", ms: {files: null, chooser: null, spotlight: null},
            after: {files: $BLUE, chooser: $BLUE, spotlight: $BLUE}}]}}"

T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
tests=0
fails=0
ok() { tests=$((tests + 1)); printf 'ok %d - %s\n' "$tests" "$1"; }
not_ok() { tests=$((tests + 1)); fails=$((fails + 1)); printf 'not ok %d - %s\n' "$tests" "$1"; }

recorded() { if [[ $1 == control ]]; then echo "$CONTROL_RUN"; else echo "$MAIN_RUN"; fi; }

# failures MODE RUN CHANGE: how many of check.sh's assertions the changed run fails.
failures() {
    jq -nc "$2 | $3" >"$T/run.json" || return 1
    "$HERE/check.sh" "$1" "$T/run.json" >"$T/out" 2>&1
    grep -c '^FAIL' "$T/out"
}

for mode in main control; do
    if [[ $(failures "$mode" "$(recorded "$mode")" .) == 0 ]]; then
        ok "$mode: the recorded run passes every assertion"
    else
        not_ok "$mode: the recorded run passes every assertion: $(grep '^FAIL' "$T/out" | head -n 3 | paste -sd'|' -)"
    fi
done

while IFS='|' read -r mode change what; do
    count=$(failures "$mode" "$(recorded "$mode")" "$change")
    if [[ $count == 1 ]]; then
        ok "$mode: $what fails one assertion"
    else
        not_ok "$mode: $what fails one assertion (it failed ${count:-none}: $(grep '^FAIL' "$T/out" | paste -sd'|' -))"
    fi
done <<EOF
main|.result.error = "Spotlight is off"|a probe that stopped early
main|.result.spotlightRow = "Downloads"|another folder's Spotlight row
main|.result.agentRunningAfter = false|an agent that died during the run
main|.result.changes[1].theme = "Apex-blue"|a theme that missed the second change
main|.result.surfaces.chooser.before = [255, 255, 255]|a chooser that drew no blue folder
main|.result.changes[0].ms.spotlight = 1200|Spotlight 200 ms late
main|.result.changes[1].ms.files = null|Files never recoloured
main|.result.changes[1].after.chooser = $GREEN|a chooser that fell back to the first change's colour
main|(.result.surfaces.spotlight.before, .result.changes[].ms.spotlight, .result.changes[].after.spotlight) = null|Spotlight drawing no Apex folder at all
control|.result.control = false|a control that ran the agent
control|.result.themeBefore = "Apex-blue"|a control already on a folder theme
control|.result.changes[0].ms.files = 640|a control whose Files recoloured
control|.result.changes[1].after.spotlight = $PINK|a control whose Spotlight drew the new colour
EOF

printf '# %d tests, %d failed\n' "$tests" "$fails"
((fails == 0))
