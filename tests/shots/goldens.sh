#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/goldens.sh import SIGNOFF_DIR DECISIONS.json
       tests/shots/goldens.sh check SIGNOFF_DIR [GOLDENS_DIR]

The owner's approved sign-off boards, kept as goldens on the orphan branch goldens, at the
commit tests/shots/goldens.lock pins (README, "Approved goldens").

import writes a goldens commit from signoff.sh's OUT and the sign-off page's decisions,
{"boards": {"NN-SLUG": {"status", "shots", "approvedAt", "note"}}}, keyed by row (a legacy NN
only for a board of one row). It takes each row whose status is "approved" and whose shots
hash (sha256 of the light PNG's bytes, then the dark PNG's if the row has one, first 12 hex)
is its capture's, on top of the pinned commit (or as the branch's first commit), and points
goldens.lock at the new commit. A decision for another capture, or of another shape, refuses
the whole import. It never pushes: the commit is in GOLDENS_WORK (default _build/goldens).

check compares each row of SIGNOFF_DIR that has a golden with it, pixel for pixel outside
golden-masks.json's masks, through compare.js; a row without one is awaiting sign-off.
GOLDENS_DIR is a goldens checkout; without it, the pinned commit is fetched. Exit 1 when a
board differs from its golden, 2 when the goldens cannot be read.

GOLDENS_URL (default apex-gnome's GitHub repository), GOLDENS_LOCK, GOLDENS_MASKS and
GOLDENS_WORK override the inputs, for tests.
EOF
}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
GOLDENS_URL=${GOLDENS_URL:-https://github.com/apex-linux/apex-gnome}
GOLDENS_LOCK=${GOLDENS_LOCK:-$HERE/goldens.lock}
GOLDENS_MASKS=${GOLDENS_MASKS:-$HERE/golden-masks.json}
GOLDENS_WORK=${GOLDENS_WORK:-$REPO/_build/goldens}

die() { echo "goldens.sh: $*" >&2; exit 2; }

locked_rev() {
    sed -n 's/^GOLDENS_REV=\([0-9a-f]*\)$/\1/p' "$GOLDENS_LOCK" | head -n 1
}

# A row's light PNG, then its dark one if it has one.
shots_hash() {
    cat "$@" | sha256sum | cut -c 1-12
}

# signoff.json's rows with their keys and how many rows their board has; an older signoff.json has no keys.
# shellcheck disable=SC2016 # a jq program
readonly ROWS='.boards | map(. + {key: (.key // "\(.board)-\(.slug)")}) | group_by(.board) | map(length as $n | map(. + {rows: $n})) | add // []'
# The row a decision key names: NN-SLUG, or a legacy NN for a board of one row.
# shellcheck disable=SC2016 # a jq program
readonly ROW_OF='def row_of($k): map(select(.key == $k or (.rows == 1 and (.board | tostring) == $k)))[0];'

fetch_goldens() {
    local dir=$1 rev=$2
    rm -rf "$dir"
    git init -q "$dir" || die "cannot create $dir"
    [[ -n $rev ]] || return 0
    if ! git -C "$dir" fetch -q --depth 1 "$GOLDENS_URL" "$rev" || ! git -C "$dir" checkout -q --detach FETCH_HEAD; then
        die "cannot fetch the goldens at $rev from $GOLDENS_URL"
    fi
}

signoff_json() {
    jq -e '.boards | length > 0' "$1/signoff.json" >/dev/null 2>&1 || die "no signoff.json with boards in $1"
}

# Every key and value is checked, so a page export of another shape never half-imports.
decision_errors() {
    jq -r --slurpfile signoff "$1/signoff.json" "$ROW_OF"'
        ($signoff[0] | '"$ROWS"') as $rows
        | if type != "object" or (keys != ["boards"]) or (.boards | type) != "object" then
              "DECISIONS.json is not {\"boards\": {...}}"
          else .boards | to_entries[] | .key as $n | .value
              | if ($n | test("^[0-9]+$")) and ($rows | map(select((.board | tostring) == $n)) | length) > 1 then
                    "board \($n): a number alone keys a board of one row; its rows are \($rows | map(select((.board | tostring) == $n) | .key) | join(", "))"
                elif ($rows | row_of($n)) == null then "board \($n): not in signoff.json"
                elif type != "object" then "board \($n): the decision is not an object"
                elif (keys - ["approvedAt", "note", "shots", "status"]) != [] then
                    "board \($n): unknown field(s) \(keys - ["approvedAt", "note", "shots", "status"] | join(", "))"
                elif (.status | type) != "string" then "board \($n): no status"
                elif (.shots | type) != "string" or (.shots | test("^[0-9a-f]{12}$") | not) then
                    "board \($n): shots is not 12 hex digits"
                elif .status == "approved" and ((.approvedAt | type) != "string" or
                    (.approvedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T") | not)) then
                    "board \($n): approved without an ISO 8601 approvedAt"
                elif has("note") and (.note | type) != "string" then "board \($n): note is not a string"
                else empty end
          end' "$2" 2>/dev/null || echo "DECISIONS.json is not JSON"
}

import() {
    local signoff=$1 decisions=$2 errors=() approved=() board row title light dark hash shots rev commit entries=() variant from
    signoff_json "$signoff"
    [[ -s $decisions ]] || die "no decisions in $decisions"
    mapfile -t errors < <(decision_errors "$signoff" "$decisions")
    if ((${#errors[@]})); then
        printf 'goldens.sh: %s\n' "${errors[@]}" >&2
        die "nothing imported: ${#errors[@]} error(s)"
    fi
    mapfile -t approved < <(jq -r '.boards // {} | to_entries[] | select(.value.status == "approved") | .key' "$decisions" 2>/dev/null)
    for board in "${approved[@]}"; do
        row=$(jq -c --arg k "$board" "$ROW_OF ${ROWS} | row_of(\$k)" "$signoff/signoff.json")
        title=$(jq -r .title <<<"$row")
        light=$signoff/$(jq -r .files.light <<<"$row")
        dark=$(jq -r '.files.dark // empty' <<<"$row")
        if [[ ! -s $light || ( -n $dark && ! -s $signoff/$dark ) ]]; then
            errors+=("board $board ($title): no capture in $signoff")
            continue
        fi
        [[ -z $dark ]] || dark=$signoff/$dark
        hash=$(shots_hash "$light" ${dark:+"$dark"})
        shots=$(jq -r --arg n "$board" '.boards[$n].shots' "$decisions")
        [[ $shots == "$hash" ]] ||
            errors+=("board $board ($title): approved shots $shots, but its captures hash to $hash: a stale approval")
        entries+=("$board|$hash|$light|$dark")
    done
    ((${#approved[@]})) || errors+=("no board is approved")
    if ((${#errors[@]})); then
        printf 'goldens.sh: %s\n' "${errors[@]}" >&2
        die "nothing imported: ${#errors[@]} error(s)"
    fi

    rev=$(locked_rev)
    fetch_goldens "$GOLDENS_WORK" "$rev"
    mkdir -p "$GOLDENS_WORK/boards"
    [[ -s $GOLDENS_WORK/manifest.json ]] || echo '{"boards": {}}' >"$GOLDENS_WORK/manifest.json"
    for entry in "${entries[@]}"; do
        IFS='|' read -r board hash light dark <<<"$entry"
        for variant in light dark; do
            [[ $variant == light ]] && from=$light || from=$dark
            [[ -n $from ]] || continue
            cp "$from" "$GOLDENS_WORK/boards/board-$board-$variant.png" || die "cannot copy board $board's captures"
        done
        jq --arg k "$board" --arg hash "$hash" --slurpfile signoff "$signoff/signoff.json" --slurpfile d "$decisions" "$ROW_OF"'
            ($signoff[0] | '"$ROWS"' | row_of($k)) as $b
            | .boards[$k] = {
                board: $b.board, title: $b.title, slug: $b.slug, source: $b.source, fixture: $b.fixture, scene: $b.scene, shots: $hash,
                files: {light: "boards/board-\($k)-light.png", dark: (if $b.files.dark == null then null else "boards/board-\($k)-dark.png" end)},
                pins: $signoff[0].pins, scale: $signoff[0].scale, monitor: $signoff[0].monitor,
                approval: ($d[0].boards[$k] | {status, approvedAt, shots} + (if has("note") then {note} else {} end))}' \
            "$GOLDENS_WORK/manifest.json" >"$GOLDENS_WORK/manifest.json.new" || die "cannot write board $board's manifest entry"
        mv "$GOLDENS_WORK/manifest.json.new" "$GOLDENS_WORK/manifest.json" || die "cannot write $GOLDENS_WORK/manifest.json"
    done
    git -C "$GOLDENS_WORK" add -A || die "cannot stage the goldens in $GOLDENS_WORK"
    git -C "$GOLDENS_WORK" commit -q -m "goldens: board(s) ${approved[*]} from apex-gnome $(jq -r .commit "$signoff/signoff.json")" ||
        die "cannot commit the goldens in $GOLDENS_WORK"
    commit=$(git -C "$GOLDENS_WORK" rev-parse HEAD)
    sed -i "s/^GOLDENS_REV=.*/GOLDENS_REV=$commit/" "$GOLDENS_LOCK" || die "cannot pin $commit in $GOLDENS_LOCK"
    echo "goldens.sh: board(s) ${approved[*]} imported as $commit; $GOLDENS_LOCK pins it"
    echo "goldens.sh: push it first: git -C $GOLDENS_WORK push $GOLDENS_URL HEAD:refs/heads/goldens"
}

check() {
    local signoff=$1 goldens=${2:-} rev row key label golden expected plan results matched=() awaiting=() files
    # shellcheck source=tests/shots/lib.sh
    . "$HERE/lib.sh"
    signoff_json "$signoff"
    jq -e '.boards | type == "object"' "$GOLDENS_MASKS" >/dev/null 2>&1 || die "no masks in $GOLDENS_MASKS"
    if [[ -z $goldens ]]; then
        rev=$(locked_rev)
        goldens=$(mktemp -d "${TMPDIR:-/tmp}/apex-goldens.XXXXXX") || die "cannot create a goldens checkout"
        # shellcheck disable=SC2064 # this checkout, not whatever the variable holds at exit
        trap "rm -rf '$goldens'" EXIT
        fetch_goldens "$goldens" "$rev"
    fi
    [[ -s $goldens/manifest.json ]] || echo '{"boards": {}}' >"$goldens/manifest.json"
    jq -e '.boards | type == "object"' "$goldens/manifest.json" >/dev/null || die "$goldens/manifest.json has no boards"
    plan=$signoff/goldens-plan.json results=$signoff/goldens-results.json
    rm -rf "$signoff/goldens-diff" && mkdir -p "$signoff/goldens-diff"
    echo '[]' >"$plan"
    while IFS= read -r row; do
        key=$(jq -r .key <<<"$row")
        label=$(jq -r 'if .rows == 1 then "board \(.board) (\(.title))" else "board \(.key) (\(.title))" end' <<<"$row")
        # A legacy golden keyed NN stands for a board of one row, matched by its recorded slug.
        golden=$(jq -r --argjson row "$row" '.boards | if has($row.key) then $row.key
            elif $row.rows == 1 and (.[$row.board | tostring].slug == $row.slug) then $row.board | tostring else empty end' \
            "$goldens/manifest.json")
        if [[ -z $golden ]]; then
            awaiting+=("$key")
            echo "AWAIT $label: no approved golden, awaiting sign-off"
            continue
        fi
        matched+=("$golden")
        expected=$(jq -r --arg g "$golden" '.boards[$g].shots // empty' "$goldens/manifest.json")
        mapfile -t files < <(jq -r --arg g "$golden" '.boards[$g].files | .light, (.dark // empty)' "$goldens/manifest.json")
        if [[ $(jq -r --arg g "$golden" '.boards[$g].files.dark == null' "$goldens/manifest.json") != $(jq -r '.files.dark == null' <<<"$row") ]]; then
            fail "$label: the golden and the capture differ in which variants they have"
            continue
        fi
        if [[ $(cd -- "$goldens" && shots_hash "${files[@]}" 2>/dev/null) != "$expected" ]]; then
            fail "$label: the golden's files do not hash to its manifest's shots $expected"
            continue
        fi
        jq --argjson row "$row" --arg label "$label" --arg g "$golden" --arg signoff "$signoff" --arg goldens "$goldens" \
            --slurpfile manifest "$goldens/manifest.json" --slurpfile masks "$GOLDENS_MASKS" '
            . + [{variant: "light"}, {variant: "dark"} | select($row.files[.variant] != null)
                 | {name: "\($label), \(.variant)", expected: "\($goldens)/\($manifest[0].boards[$g].files[.variant])",
                    actual: "\($signoff)/\($row.files[.variant])", diff: "\($signoff)/goldens-diff/board-\($g)-\(.variant).png",
                    masks: [($masks[0].boards[$row.key] // (if $row.rows == 1 then $masks[0].boards[$row.board | tostring] else null end))[]?
                            | {name, x, y, width, height}]}]' "$plan" >"$plan.new" || die "cannot plan $label"
        mv "$plan.new" "$plan" || die "cannot write $plan"
    done < <(jq -c "$ROWS | .[]" "$signoff/signoff.json")
    # A golden of a source this sign-off did not collect is out of its scope, not missing from it.
    while IFS=$'\t' read -r golden label; do
        fail "board $golden ($label): a golden, but no such board in $signoff"
    done < <(jq -r --slurpfile s "$signoff/signoff.json" --args '
        .boards | to_entries[] | select(.key as $k | $ARGS.positional | index($k) | not)
        | select($s[0].sources == null or (.value.source as $src | $s[0].sources | index($src)))
        | [.key, .value.title] | @tsv' "${matched[@]}" <"$goldens/manifest.json")
    if [[ $(jq length "$plan") != 0 ]]; then
        compare_and_expect_equal "$plan" "$results"
    fi
    echo "# ${#awaiting[@]} row(s) awaiting sign-off${awaiting[*]:+: ${awaiting[*]}}"
    summary
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    import) (($# == 3)) || { usage >&2; exit 2; }; import "$2" "$3" ;;
    check) (($# == 2 || $# == 3)) || { usage >&2; exit 2; }; check "$2" "${3:-}" ;;
    *) usage >&2; exit 2 ;;
esac
