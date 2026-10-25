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
{"boards": {"NN": {"status", "shots", "approvedAt", "note"}}}. It takes each board whose
status is "approved" and whose shots hash (sha256 of the light PNG's bytes, then the dark
PNG's, first 12 hex) is its capture's, on top of the pinned commit (or as the branch's first
commit), and points goldens.lock at the new commit. A decision for another capture, or of
another shape, refuses the whole import. It never pushes: the commit is in GOLDENS_WORK
(default _build/goldens).

check compares each board of SIGNOFF_DIR that has a golden with it, pixel for pixel outside
golden-masks.json's masks, through compare.js; a board without one is awaiting sign-off.
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

shots_hash() {
    cat "$1" "$2" | sha256sum | cut -c 1-12
}

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
    jq -r --slurpfile signoff "$1/signoff.json" '
        ($signoff[0].boards | map(.board | tostring)) as $boards
        | if type != "object" or (keys != ["boards"]) or (.boards | type) != "object" then
              "DECISIONS.json is not {\"boards\": {...}}"
          else .boards | to_entries[] | .key as $n | .value
              | if ($boards | index($n)) == null then "board \($n): not in signoff.json"
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
    local signoff=$1 decisions=$2 errors=() approved=() board title light dark hash shots rev commit entries=()
    signoff_json "$signoff"
    [[ -s $decisions ]] || die "no decisions in $decisions"
    mapfile -t errors < <(decision_errors "$signoff" "$decisions")
    if ((${#errors[@]})); then
        printf 'goldens.sh: %s\n' "${errors[@]}" >&2
        die "nothing imported: ${#errors[@]} error(s)"
    fi
    mapfile -t approved < <(jq -r '.boards // {} | to_entries[] | select(.value.status == "approved") | .key' "$decisions" 2>/dev/null)
    for board in "${approved[@]}"; do
        title=$(jq -r --argjson n "$board" '.boards[] | select(.board == $n) | .title' "$signoff/signoff.json")
        light=$signoff/$(jq -r --argjson n "$board" '.boards[] | select(.board == $n) | .files.light' "$signoff/signoff.json")
        dark=$signoff/$(jq -r --argjson n "$board" '.boards[] | select(.board == $n) | .files.dark' "$signoff/signoff.json")
        if [[ ! -s $light || ! -s $dark ]]; then
            errors+=("board $board ($title): no capture in $signoff")
            continue
        fi
        hash=$(shots_hash "$light" "$dark")
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
        if ! cp "$light" "$GOLDENS_WORK/boards/board-$board-light.png" || ! cp "$dark" "$GOLDENS_WORK/boards/board-$board-dark.png"; then
            die "cannot copy board $board's captures"
        fi
        jq --argjson n "$board" --arg hash "$hash" --slurpfile signoff "$signoff/signoff.json" --slurpfile d "$decisions" '
            ($signoff[0] | .boards[] | select(.board == $n)) as $b
            | .boards[$n | tostring] = {
                title: $b.title, slug: $b.slug, source: $b.source, fixture: $b.fixture, scene: $b.scene, shots: $hash,
                files: {light: "boards/board-\($n)-light.png", dark: "boards/board-\($n)-dark.png"},
                pins: $signoff[0].pins, scale: $signoff[0].scale, monitor: $signoff[0].monitor,
                approval: ($d[0].boards[$n | tostring] | {status, approvedAt, shots} + (if has("note") then {note} else {} end))}' \
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
    local signoff=$1 goldens=${2:-} rev board title light dark expected plan results awaiting=()
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
    while IFS=$'\t' read -r board title light dark; do
        expected=$(jq -r --arg n "$board" '.boards[$n].shots // empty' "$goldens/manifest.json")
        if [[ -z $expected ]]; then
            awaiting+=("$board")
            echo "AWAIT board $board ($title): no approved golden, awaiting sign-off"
            continue
        fi
        if [[ $(shots_hash "$goldens/boards/board-$board-light.png" "$goldens/boards/board-$board-dark.png" 2>/dev/null) != "$expected" ]]; then
            fail "board $board ($title): the golden's files do not hash to its manifest's shots $expected"
            continue
        fi
        jq --arg n "$board" --arg title "$title" --arg signoff "$signoff" --arg goldens "$goldens" \
            --arg light "$light" --arg dark "$dark" --slurpfile masks "$GOLDENS_MASKS" '
            . + [{variant: "light", file: $light}, {variant: "dark", file: $dark}
                 | {name: "board \($n) (\($title)), \(.variant)", expected: "\($goldens)/boards/board-\($n)-\(.variant).png",
                    actual: "\($signoff)/\(.file)", diff: "\($signoff)/goldens-diff/board-\($n)-\(.variant).png",
                    masks: [$masks[0].boards[$n][]? | {name, x, y, width, height}]}]' "$plan" >"$plan.new" || die "cannot plan board $board"
        mv "$plan.new" "$plan" || die "cannot write $plan"
    done < <(jq -r '.boards[] | [.board, .title, .files.light, .files.dark] | @tsv' "$signoff/signoff.json")
    while IFS= read -r board; do
        fail "board $board ($(jq -r --arg n "$board" '.boards[$n].title' "$goldens/manifest.json")): a golden, but no such board in $signoff"
    done < <(jq -r --slurpfile s "$signoff/signoff.json" '.boards | keys[] | select(. as $n | $s[0].boards | map(.board | tostring) | index($n) | not)' \
        "$goldens/manifest.json")
    if [[ $(jq length "$plan") != 0 ]]; then
        compare_and_expect_equal "$plan" "$results"
    fi
    echo "# ${#awaiting[@]} board(s) awaiting sign-off${awaiting[*]:+: ${awaiting[*]}}"
    summary
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    import) (($# == 3)) || { usage >&2; exit 2; }; import "$2" "$3" ;;
    check) (($# == 2 || $# == 3)) || { usage >&2; exit 2; }; check "$2" "${3:-}" ;;
    *) usage >&2; exit 2 ;;
esac
