# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later

SHOTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOKEN_FILE=${G2_TOKEN_FILE:-$SHOTS_DIR/../../desktop/shell/data/theme/apex/_apex-tokens.scss}
G2_GJS=${G2_GJS:-gjs}
# A mask that hides more than this of a capture hides the comparison, not a region.
MAX_MASKED_PERCENT=5
COMPARE_COULD_NOT_COMPARE=2

npass=0
nfail=0
ngap=0
gaps=()
gap_until=
pass() {
    if [[ -n $gap_until ]]; then
        nfail=$((nfail + 1))
        printf 'FAIL %s (a known gap until %s, but it holds now: make it a plain assertion)\n' "$*" "$gap_until"
    else
        npass=$((npass + 1))
        printf 'PASS %s\n' "$*"
    fi
}
fail() {
    if [[ -n $gap_until ]]; then
        ngap=$((ngap + 1))
        gaps+=("$gap_until: $*")
        printf 'GAP  %s: %s\n' "$gap_until" "$*"
    else
        nfail=$((nfail + 1))
        printf 'FAIL %s\n' "$*"
    fi
}
# pass and fail read gap_until through bash's dynamic scope.
known_gap() {
    local gap_until=$1
    shift
    "$@"
}
check() {
    local desc=$1
    shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
summary() {
    local g
    printf '# %d passed, %d failed, %d known gaps\n' "$npass" "$nfail" "$ngap"
    for g in "${gaps[@]}"; do
        printf '# gap %s\n' "$g"
    done
    ((nfail == 0))
}

report_of() {
    local log=$1 tag=${2:-APEXG2}
    [[ -f $log ]] || return 0
    sed -n "s/.*$tag \\({.*}\\)\$/\\1/p" "$log" | head -n 1
}

expect() {
    local label=$1 report=$2 expr=$3 desc=$4
    if [[ -z $report ]]; then
        fail "$label: $desc (no report)"
    elif jq -e "$JQ_DEFS $expr" <<<"$report" >/dev/null 2>&1; then
        pass "$label: $desc"
    else
        fail "$label: $desc (got $(jq -c "$JQ_DEFS $expr" <<<"$report" 2>&1 | head -c 300))"
    fi
}

expect_report() {
    local label=$1 log=$2 expr=$3 desc=$4 tag=${5:-APEXG2}
    expect "$label" "$(report_of "$log" "$tag")" "$expr" "$desc"
}

# shellcheck disable=SC2016 # jq variables, not shell ones
JQ_DEFS='
def nibble: if . >= 97 then . - 87 else . - 48 end;
def byte: ascii_downcase | explode | map(nibble) | .[0] * 16 + .[1];
def num: if startswith(".") then "0" + . elif startswith("-.") then "-0" + .[1:] else . end | tonumber;
def rgba:
  ascii_downcase as $c
  | if ($c | test("^#[0-9a-f]{8}$")) then [$c[1:3], $c[3:5], $c[5:7], $c[7:9]] | map(byte)
    elif ($c | test("^#[0-9a-f]{6}$")) then ([$c[1:3], $c[3:5], $c[5:7]] | map(byte)) + [255]
    elif ($c | test("^#[0-9a-f]{3}$")) then ([$c[1:2], $c[2:3], $c[3:4]] | map(. + . | byte)) + [255]
    elif $c == "transparent" then [0, 0, 0, 0]
    elif ($c | test("^rgba?\\(")) then
      ($c | capture("^rgba?\\(\\s*(?<r>[0-9]+)\\s*,\\s*(?<g>[0-9]+)\\s*,\\s*(?<b>[0-9]+)\\s*(,\\s*(?<a>[0-9.]+)\\s*)?\\)$")
          // error("\($c) is not a colour"))
      | [(.r | tonumber), (.g | tonumber), (.b | tonumber), ((.a // "1") | num * 255 | round)]
    else error("\($c) is not a colour") end;
def px:
  if type == "number" then .
  elif test("^-?[0-9]*\\.?[0-9]+px$") then rtrimstr("px") | num
  elif test("^-?[0-9]*\\.?[0-9]+$") then num
  else error("\(.) is not a length in px") end;
def colour_is($want): (. | rgba) as $got | [$got, ($want | rgba)] | transpose | all(.[0] - .[1] | fabs <= 1);
def px_is($want): (. - ($want | px)) | fabs < 0.01;
def luminance: map(. / 255 | if . <= 0.04045 then . / 12.92 else pow((. + 0.055) / 1.055; 2.4) end) | .[0] * 0.2126 + .[1] * 0.7152 + .[2] * 0.0722;
def contrast_on($bg): (rgba) as $f | ($bg | rgba) as $b | ($f[3] / 255) as $a
  | ([range(3) as $i | $f[$i] * $a + $b[$i] * (1 - $a)] | luminance) as $l | ($b[0:3] | luminance) as $m
  | (([$l, $m] | max) + 0.05) / (([$l, $m] | min) + 0.05);
'

tokens_json() {
    local token_file=${1:-$TOKEN_FILE}
    awk '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function split_top(s, parts,    n, depth, i, c, cur) {
            n = 0; depth = 0; cur = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "(") depth++
                if (c == ")") depth--
                if (c == "," && depth == 0) { parts[++n] = trim(cur); cur = ""; continue }
                cur = cur c
            }
            parts[++n] = trim(cur)
            return n
        }
        /^\$[A-Za-z0-9_-]+[ \t]*:/ {
            line = $0
            sub(/[ \t]+\/\/[^"'\'']*$/, "", line)
            name = line; sub(/^\$/, "", name); sub(/[ \t]*:.*$/, "", name)
            value = line; sub(/^[^:]*:[ \t]*/, "", value); sub(/[ \t]*(!default)?[ \t]*;[ \t]*$/, "", value)
            light = value; dark = value
            if (value ~ /^if\(/ && split_top(substr(value, 4, length(value) - 4), arg) == 3) {
                if (arg[1] ~ /^\$variant[ \t]*==[ \t]*["'\'']light["'\'']$/) { light = arg[2]; dark = arg[3] }
                else if (arg[1] ~ /^\$variant[ \t]*==[ \t]*["'\'']dark["'\'']$/) { light = arg[3]; dark = arg[2] }
            }
            printf "%s\t%s\t%s\n", name, light, dark
        }
    ' "$token_file" | jq -Rn '[inputs | split("\t") | {key: .[0], value: {light: .[1], dark: .[2]}}] | from_entries'
}

tokens_for() {
    local variant=$1 token_file=${2:-}
    tokens_json "$token_file" | jq --arg v "$variant" 'map_values(.[$v])'
}

plan_entry() {
    local name=$1 expected_dir=$2 expected_case=$3 actual_dir=$4 actual_case=$5 scene=$6 diff_dir=$7
    shift 7
    local expected_scenes actual_scenes
    expected_scenes=$(report_of "$expected_dir/$expected_case.log" APEXG2-SCENES)
    actual_scenes=$(report_of "$actual_dir/$actual_case.log" APEXG2-SCENES)
    # A scenes report outgrows an argument; one that never reaches the plan still has its pair, failing by name.
    jq -cn --arg name "$name" --arg scene "$scene" \
        --slurpfile expected_scenes <(printf '%s\n' "${expected_scenes:-null}") \
        --slurpfile actual_scenes <(printf '%s\n' "${actual_scenes:-null}") \
        --arg expected "$expected_dir/captures/$expected_case-$scene.png" \
        --arg actual "$actual_dir/captures/$actual_case-$scene.png" \
        --arg diff "$diff_dir/$name.png" --args '
        {name: $name, expected: $expected, actual: $actual, diff: $diff,
         masks: [$ARGS.positional[] as $mask_actor
                 | [$expected_scenes[0], $actual_scenes[0]] | map(.scenes[$scene].boxes[$mask_actor] // empty)
                 | select(length > 0)
                 | {name: $mask_actor, x: (map(.x) | min), y: (map(.y) | min),
                    x1: (map(.x + .width) | max), y1: (map(.y + .height) | max)}
                 | {name, x, y, width: (.x1 - .x), height: (.y1 - .y)}]}' "$@" ||
        printf '{"name": "%s", "planError": "jq could not write its plan entry (exit %s)"}\n' "$name" "$?"
}

compare_captures() {
    local plan=$1 results=$2
    local -a gjs_command
    read -ra gjs_command <<<"$G2_GJS"
    "${gjs_command[@]}" -m "$SHOTS_DIR/compare.js" "$plan" "$results"
}

compare_and_expect_equal() {
    local plan=$1 results=$2 status=0 planned compared unplanned pair
    rm -f -- "$results"
    if ! unplanned=$(jq -r '.[] | select(has("planError")) | "\(.name): \(.planError)"' "$plan") ||
        ! jq '[.[] | select(has("planError") | not)]' "$plan" >"$plan.pairs"; then
        fail "captures: the plan $plan is not JSON jq can read"
        return
    fi
    while IFS= read -r pair; do
        [[ -z $pair ]] || fail "captures ${pair%%: *}: not compared (${pair#*: })"
    done <<<"$unplanned"
    compare_captures "$plan.pairs" "$results" || status=$?
    planned=$(jq length "$plan.pairs" 2>/dev/null) || planned=0
    compared=$(jq length "$results" 2>/dev/null) || compared=none
    if ((status > COMPARE_COULD_NOT_COMPARE || planned == 0)) || [[ $compared != "$planned" ]]; then
        fail "captures: compare.js compared $compared of $planned planned pairs (exit $status, G2_GJS=$G2_GJS)"
        return
    fi
    expect_equal_captures "$results"
}

expect_equal_captures() {
    local results=$1 pair name error differing masked total
    while IFS= read -r pair; do
        name=$(jq -r .name <<<"$pair")
        error=$(jq -r '.error // empty' <<<"$pair")
        if [[ -n $error ]]; then
            fail "captures $name: not compared ($error)"
            continue
        fi
        differing=$(jq -r .differing <<<"$pair")
        masked=$(jq -r .masked <<<"$pair")
        total=$(jq -r '.width * .height' <<<"$pair")
        if ((masked * 100 > total * MAX_MASKED_PERCENT)); then
            fail "captures $name: the masks $(jq -c .masks <<<"$pair") cover $masked of $total pixels, more than $MAX_MASKED_PERCENT %"
        elif ((differing == 0)); then
            pass "captures $name: equal outside the masks $(jq -c .masks <<<"$pair") ($masked of $total pixels masked)"
        else
            fail "captures $name: $differing pixel(s) differ outside the masks $(jq -c .masks <<<"$pair"), within $(jq -c .box <<<"$pair"); difference image $(jq -r .diff <<<"$pair")"
        fi
    done < <(jq -c '.[]' "$results")
}
