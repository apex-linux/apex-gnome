#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/stable.sh RUN_DIR OTHER_RUN_DIR

G2 runs twice per build: two runs of one image must report the same and capture the
same pixels; the direct cases' clock stands still. One PASS or FAIL line each, then a
count, and exit 1 when one fails.
EOF
}

# shellcheck source=tests/shots/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# Not fault-abort: its report races the abort.
readonly REPORTED=(default default-scale1 dark-style stock-light stock-dark safe-env layer-disabled
    layer-cycles fault-configure fault-enable kernel-safe fedora-light fedora-dark)
readonly CAPTURED=(default default-scale1 dark-style stock-light stock-dark fedora-light fedora-dark)
readonly GUARD_PHASES=(window next back-on dark-off)

same_report() {
    local label=$1 first_log=$2 other_log=$3 tag=$4 first_report other_report
    first_report=$(report_of "$first_log" "$tag")
    other_report=$(report_of "$other_log" "$tag")
    if [[ -z $first_report || -z $other_report ]]; then
        fail "$label: a run has no $tag report"
    elif [[ $(jq -S . <<<"$first_report") == "$(jq -S . <<<"$other_report")" ]]; then
        pass "$label: both runs report the same ($tag)"
    else
        fail "$label: the runs report differently ($tag): $(diff <(jq -S . <<<"$first_report") <(jq -S . <<<"$other_report") | grep '^[<>]' | head -n 6 | paste -sd'|' -)"
    fi
}

main() {
    case ${1:-} in
        -h | --help) usage; exit 0 ;;
    esac
    [[ -n ${1:-} && -n ${2:-} ]] || { usage >&2; exit 2; }
    local first_run=$1 other_run=$2 case_name scene
    echo "# G2 stability: $first_run against $other_run"
    if [[ $(sed -n 's/^id //p' "$first_run/image.txt") == "$(sed -n 's/^id //p' "$other_run/image.txt")" ]]; then
        pass "both runs tested one image ($(sed -n 's/^id //p' "$first_run/image.txt" | cut -c1-12))"
    else
        fail "the runs tested different images"
    fi
    for case_name in "${REPORTED[@]}"; do
        same_report "$case_name" "$first_run/$case_name.log" "$other_run/$case_name.log" APEXG2
    done
    for case_name in "${CAPTURED[@]}"; do
        same_report "$case_name" "$first_run/$case_name.log" "$other_run/$case_name.log" APEXG2-SCENES
    done
    same_report layer-cycles "$first_run/layer-cycles.log" "$other_run/layer-cycles.log" APEXG2-CYCLES
    for case_name in "${GUARD_PHASES[@]}"; do
        same_report "guard $case_name" "$first_run/guard-$case_name.journal" "$other_run/guard-$case_name.journal" APEXG2
    done

    local dir=$other_run/compare
    mkdir -p "$dir"
    for case_name in "${CAPTURED[@]}"; do
        for scene in desktop overview; do
            plan_entry "$case_name-$scene-run-to-run" "$first_run" "$case_name" "$other_run" "$case_name" "$scene" "$dir"
        done
    done | jq -s . >"$dir/stable-plan.json"
    compare_and_expect_equal "$dir/stable-plan.json" "$dir/stable-results.json"
    summary
}

main "$@"
