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

# Spotlight keys' times are measurements, which assert.sh holds to their budgets; a run compares only that each was taken.
# shellcheck disable=SC2016 # jq programs, not shell expansions
readonly MEASURED='reduce (paths(numbers) | select(.[0:2] == ["surfaces", "spotlightKeys"])
    | select(.[-1] == "ms" or .[-1] == "askedMs" or .[-1] == "cancelledMs")) as $p (.; setpath($p; "measured"))' \
    DIFFERING='def leaves: [paths(type != "object" and type != "array") as $p | {key: ($p | map(tostring) | join(".")), value: getpath($p)}] | from_entries;
    def shown($r; $k): if $r | has($k) then $r[$k] | tojson else "absent" end;
    ($a[0] | leaves) as $x | ($b[0] | leaves) as $y
    | [$x + $y | keys[] | select(. as $k | ($x | has($k)) != ($y | has($k)) or $x[$k] != $y[$k])]
    | "\(length) differ: " + (.[:6] | map(. as $k | "\($k) \(shown($x; $k)) → \(shown($y; $k))") | join("; "))'

same_report() {
    local label=$1 first_log=$2 other_log=$3 tag=$4 first_report other_report first other differing
    first_report=$(report_of "$first_log" "$tag")
    other_report=$(report_of "$other_log" "$tag")
    if [[ -z $first_report || -z $other_report ]]; then
        fail "$label: a run has no $tag report"
        return
    fi
    if ! first=$(jq -S "$MEASURED" <<<"$first_report") || ! other=$(jq -S "$MEASURED" <<<"$other_report"); then
        fail "$label: a run's $tag report is not JSON jq can read"
    elif [[ $first == "$other" ]]; then
        pass "$label: both runs report the same ($tag)"
    else
        differing=$(jq -rn --slurpfile a <(printf '%s' "$first") --slurpfile b <(printf '%s' "$other") "$DIFFERING")
        fail "$label: the runs report differently ($tag): ${differing:-the reports differ in shape, not in any value}"
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
