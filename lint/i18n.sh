#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Each Apex gettext domain, as its po/ ships it: the committed template matches the sources,
# every source that marks a string is in POTFILES.in, and vi.po translates every string,
# none fuzzy, each keeping its format placeholders (msgfmt --check-format).
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
NO_SKIP=${APEX_LINT_NO_SKIP:-0}

# domain|source root|po dir under it|xgettext's extra arguments
DOMAINS=(
    "apex-control-center|desktop/control-center|panels/apex/po|--keyword=_ --keyword=N_ --keyword=C_:1c,2 --keyword=NC_:1c,2"
)
# What marks a string for each kind of source.
MARKED='\b(_|N_|C_|NC_)\('

for tool in xgettext msgmerge msgfmt msgattrib; do
    command -v "$tool" >/dev/null 2>&1 && continue
    [[ $NO_SKIP == 1 ]] && { printf 'i18n: %s not found, but APEX_LINT_NO_SKIP=1\n' "$tool" >&2; exit 1; }
    printf 'i18n: SKIP (%s not found)\n' "$tool" >&2
    exit 0
done

T=$(mktemp -d "${TMPDIR:-/tmp}/apex-i18n.XXXXXX")
trap 'rm -rf "$T"' EXIT
failed=0
fail() { printf 'i18n: %s\n' "$*" >&2; failed=1; }

# The template without its creation date, which changes on every run.
body() { grep -v '^"POT-Creation-Date: ' "$1"; }

for entry in "${DOMAINS[@]}"; do
    IFS='|' read -r domain root po args <<<"$entry"
    src=$REPO/$root
    podir=$src/$po
    apex_dir=${po%/po}
    listed=$(grep -v '^#' "$podir/POTFILES.in" | sed '/^$/d')

    while IFS= read -r f; do
        grep -Fxq -- "${f#"$src"/}" <<<"$listed" || fail "$domain: ${f#"$REPO"/} marks strings but is not in POTFILES.in"
    done < <(grep -rlE "$MARKED" "$src/$apex_dir" --include='*.c' --include='*.blp' --include='*.js'; ls "$src/$apex_dir"/*.desktop.in 2>/dev/null)

    # shellcheck disable=SC2086 # the extra arguments are words
    (cd "$src" && xgettext --from-code=UTF-8 --add-comments --sort-by-file --package-name="$domain" \
        -f "$podir/POTFILES.in" -o "$T/$domain.pot" $args 2>"$T/$domain.xgettext")
    grep -v "extension 'blp' is unknown; will try C" "$T/$domain.xgettext" >&2 || true
    [[ ${1:-} == --update ]] && cp "$T/$domain.pot" "$podir/$domain.pot"
    [[ $(body "$T/$domain.pot") == "$(body "$podir/$domain.pot")" ]] ||
        fail "$domain: $po/$domain.pot is stale; regenerate it (lint/i18n.sh --update)"

    for lingua in $(cat "$podir/LINGUAS"); do
        merged=$T/$domain.$lingua.po
        msgmerge --quiet --no-fuzzy-matching -o "$merged" "$podir/$lingua.po" "$T/$domain.pot"
        missing=$(msgattrib --untranslated --no-obsolete "$merged" | grep -c '^msgid ' || true)
        fuzzy=$(msgattrib --only-fuzzy --no-obsolete "$merged" | grep -c '^msgid ' || true)
        # msgattrib prints the header's empty msgid when anything else is listed.
        ((missing > 1)) && fail "$domain: $lingua.po leaves $((missing - 1)) string(s) untranslated"
        ((fuzzy > 1)) && fail "$domain: $lingua.po has $((fuzzy - 1)) fuzzy string(s)"
        msgfmt --check-format --check-header -o /dev/null "$merged" 2>"$T/msgfmt" ||
            fail "$domain: $lingua.po: $(cat "$T/msgfmt")"
        printf 'i18n: %s %s: %s strings\n' "$domain" "$lingua" "$(grep -c '^msgid ' "$T/$domain.pot")" >&2
    done

done

exit "$failed"
