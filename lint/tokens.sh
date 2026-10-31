#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The token rule: Apex's colours live in _apex-tokens.scss, and every token there is used.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
THEME=${APEX_TOKENS_THEME:-$REPO/desktop/shell/data/theme/apex}
ROOT=${APEX_TOKENS_ROOT:-$REPO}
ALLOW=${APEX_TOKENS_ALLOW:-$HERE/tokens.allow}
readonly TOKENS=_apex-tokens.scss

usage() {
    cat <<EOF
usage: lint/tokens.sh

Fails on a colour literal in an Apex SCSS file other than $TOKENS (a #hex colour, or an
rgb()/rgba() with a number in it rather than tokens alone) and on a token $TOKENS defines
that nothing in the repository uses. lint/tokens.allow lists the known exceptions, each
FILE:LINE or \$token, a tab, then why and whose; an entry that no longer matches fails too.
lint/theme.sh runs it first. APEX_TOKENS_THEME, APEX_TOKENS_ROOT and APEX_TOKENS_ALLOW
override the inputs, for tests.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
esac

# rgb_literal TEXT: true when an rgb() or rgba() in TEXT has a number among its arguments.
rgb_literal() {
    local s=$1 i depth args c
    while [[ $s =~ rgba?\( ]]; do
        s=${s#*"${BASH_REMATCH[0]}"}
        depth=1 args=''
        for ((i = 0; i < ${#s} && depth > 0; i++)); do
            c=${s:i:1}
            [[ $c == '(' ]] && depth=$((depth + 1))
            [[ $c == ')' ]] && depth=$((depth - 1))
            ((depth > 0)) && args+=$c
        done
        s=${s:i}
        args=$(sed -E 's/\$[a-zA-Z0-9_-]+//g' <<<"$args")
        [[ $args == *[0-9]* ]] && return 0
    done
    return 1
}

literals() {
    local f name n line
    for f in "$THEME"/*.scss; do
        name=${f##*/}
        [[ $name == "$TOKENS" ]] && continue
        n=0
        while IFS= read -r line || [[ -n $line ]]; do
            n=$((n + 1))
            line=${line%%//*}
            if [[ $line =~ \#[0-9a-fA-F]{3,8}([^0-9a-zA-Z_-]|$) ]] || rgb_literal "$line"; then
                printf '%s:%d\n' "$name" "$n"
            fi
        done <"$f"
    done
}

dead() {
    local token uses
    # shellcheck disable=SC2016 # a literal $ in the pattern
    sed -nE 's/^\$(apex_[a-z0-9_]+)[[:space:]]*:.*/\1/p' "$THEME/$TOKENS" | sort -u | while read -r token; do
        uses=$(grep -rnE --exclude-dir=.git --exclude-dir=_build --exclude-dir=node_modules \
            --include='*.scss' --include='*.js' --include='*.sh' --include='*.py' \
            -- "\\\$${token}([^a-zA-Z0-9_-]|\$)" "$ROOT" |
            grep -vE "^${THEME}/${TOKENS}:[0-9]+:\\\$${token}[[:space:]]*:" || :)
        [[ -n $uses ]] || printf '$%s\n' "$token"
    done
}

found=$( { literals; dead; } | LC_ALL=C sort -u)
allowed=$(sed -e '/^#/d' -e '/^[[:space:]]*$/d' -e 's/\t.*//' "$ALLOW" | LC_ALL=C sort -u)
new=$(LC_ALL=C comm -23 <(printf '%s\n' "$found" | sed '/^$/d') <(printf '%s\n' "$allowed" | sed '/^$/d'))
stale=$(LC_ALL=C comm -13 <(printf '%s\n' "$found" | sed '/^$/d') <(printf '%s\n' "$allowed" | sed '/^$/d'))

status=0
while read -r hit; do
    [[ -n $hit ]] || continue
    case $hit in
        '$'*) printf 'tokens: %s is defined in %s and used nowhere\n' "$hit" "$TOKENS" >&2 ;;
        *) printf 'tokens: %s: a colour literal outside %s; make it a token: %s\n' "$hit" "$TOKENS" \
            "$(sed -n "${hit##*:}p" "$THEME/${hit%%:*}" | sed 's/^[[:space:]]*//')" >&2 ;;
    esac
    status=1
done <<<"$new"
while read -r entry; do
    [[ -n $entry ]] || continue
    printf 'tokens: %s is in %s but no longer an exception; remove the entry\n' "$entry" "${ALLOW#"$REPO/"}" >&2
    status=1
done <<<"$stale"
((status == 0)) && printf 'tokens: no colour literal outside %s and no unused token, but the %d listed in %s\n' \
    "$TOKENS" "$(printf '%s\n' "$allowed" | sed '/^$/d' | wc -l)" "${ALLOW#"$REPO/"}" >&2
exit "$status"
