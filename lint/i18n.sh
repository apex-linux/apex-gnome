#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Each Apex gettext domain: a current template, every marking source in POTFILES.in, and each
# LINGUAS language translating every string, none fuzzy, placeholders kept (msgfmt --check-format).
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
NO_SKIP=${APEX_LINT_NO_SKIP:-0}
SPDX='# SPDX-License-Identifier: GPL-2.0-or-later'

# domain|source root|po dir under it|sources it covers|what marks a file's strings|xgettext's extra arguments
DOMAINS=(
    "apex-control-center|desktop/control-center|panels/apex/po|panels/apex|\bN?C?_\(|--keyword=_ --keyword=N_ --keyword=C_:1c,2 --keyword=NC_:1c,2"
)

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
body() { grep -v '^"POT-Creation-Date: ' "$1"; }
entries() { grep -v '^#' "$1" | sed '/^$/d'; }

for entry in "${DOMAINS[@]}"; do
    IFS='|' read -r domain root po covers marked args <<<"$entry"
    src=$REPO/$root
    podir=$src/$po
    pot=$T/$domain.pot
    listed=$(entries "$podir/POTFILES.in")

    while IFS= read -r f; do
        grep -Fxq -- "${f#"$src"/}" <<<"$listed" || fail "$domain: ${f#"$REPO"/} marks strings but is not in POTFILES.in"
    done < <(grep -rlE "$marked" "$src/$covers" --include='*.c' --include='*.blp' --include='*.js'; ls "$src/$covers"/*.desktop.in 2>/dev/null)

    # shellcheck disable=SC2086 # the extra arguments are words
    (cd "$src" && xgettext --from-code=UTF-8 --add-comments --sort-by-file --package-name="$domain" \
        -f "$podir/POTFILES.in" -o - $args 2>"$T/$domain.xgettext") | { printf '%s\n' "$SPDX"; cat; } >"$pot"
    grep -v "extension 'blp' is unknown; will try C" "$T/$domain.xgettext" >&2 || true
    [[ ${1:-} == --update ]] && cp "$pot" "$podir/$domain.pot"
    [[ $(body "$pot") == "$(body "$podir/$domain.pot")" ]] ||
        fail "$domain: $po/$domain.pot is stale; regenerate it (lint/i18n.sh --update)"

    while IFS= read -r lingua; do
        merged=$T/$domain.$lingua.po
        msgmerge --quiet --no-fuzzy-matching -o "$merged" "$podir/$lingua.po" "$pot"
        missing=$(msgattrib --untranslated --no-obsolete "$merged" | grep -c '^msgid ' || true)
        fuzzy=$(msgattrib --only-fuzzy --no-obsolete "$merged" | grep -c '^msgid ' || true)
        # msgattrib prints the header's empty msgid when anything else is listed.
        ((missing > 1)) && fail "$domain: $lingua.po leaves $((missing - 1)) string(s) untranslated"
        ((fuzzy > 1)) && fail "$domain: $lingua.po has $((fuzzy - 1)) fuzzy string(s)"
        msgfmt --check-format --check-header -o /dev/null "$merged" 2>"$T/msgfmt" ||
            fail "$domain: $lingua.po: $(cat "$T/msgfmt")"
        printf 'i18n: %s %s: %s strings\n' "$domain" "$lingua" "$(grep -c '^msgid ' "$pot")" >&2
    done < <(entries "$podir/LINGUAS")
done

exit "$failed"
