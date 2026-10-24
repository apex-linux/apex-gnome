#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# apex-lane's contract (packaging/README.md): exit 1 holds the family, the last line
# giving the reason; exit 2 means the checks could not run.

set -euo pipefail

ok() { printf 'ok %s\n' "$*"; }
fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
cannot() { printf 'check.sh cannot run: %s\n' "$*" >&2; exit 2; }

for v in RPMS_DIR PRISTINE SOURCE1 CHECK_WORK; do
    [[ -n ${!v:-} ]] || cannot "$v is not set"
done
command -v gresource >/dev/null || cannot "no gresource (glib2-devel) in the buildroot"

readonly APEX_PREFIX=/org/gnome/Ptyxis/apex
readonly SOURCE1_DIR=src/apex/

root=$CHECK_WORK/root
mkdir -p -- "$root"
shopt -s nullglob
main=("$RPMS_DIR"/ptyxis-[0-9]*.x86_64.rpm)
((${#main[@]} == 1)) || fail "expected one ptyxis x86_64 RPM, found ${#main[@]}"
(cd -- "$root" && rpm2cpio "${main[0]}" | cpio -idm --quiet --no-absolute-filenames) ||
    cannot "cannot unpack ${main[0]##*/}"

bin=$root/usr/bin/ptyxis
[[ -f $bin ]] || fail "no /usr/bin/ptyxis in ${main[0]##*/}"
resources=$(gresource list "$bin") || fail "gresource cannot read /usr/bin/ptyxis"
grep -Fxq -- /org/gnome/Ptyxis/ptyxis-window.ui <<<"$resources" || fail "ptyxis has lost upstream's resource"
ok "/usr/bin/ptyxis holds upstream's resource"

# A file missing from apex.gresource.xml would otherwise fail only at runtime.
members=$(tar -tf "$SOURCE1") || cannot "cannot list $SOURCE1"
n=0
while IFS= read -r m; do
    [[ $m == "$SOURCE1_DIR"* && $m != */ ]] || continue
    case ${m##*/} in meson.build | *.gresource.xml | *.[ch]) continue ;; esac
    grep -Fxq -- "$APEX_PREFIX/${m#"$SOURCE1_DIR"}" <<<"$resources" ||
        fail "$m is in desktop/ptyxis but not in the resource (apex.gresource.xml)"
    n=$((n + 1))
done <<<"$members"
((n > 0)) || fail "Source1 has no resource file under $SOURCE1_DIR"
ok "every resource file of Source1 ($n) is in $APEX_PREFIX"

css=$(gresource extract "$bin" "$APEX_PREFIX/apex.css") || fail "ptyxis has no $APEX_PREFIX/apex.css"
grep -Fq '/*! apex-ptyxis */' <<<"$css" || fail "$APEX_PREFIX/apex.css has no Apex marker"
grep -Fq '.apex-sessions' <<<"$css" || fail "$APEX_PREFIX/apex.css has no sessions sidebar"
ok "$APEX_PREFIX/apex.css carries the Apex marker and the sidebar's sheet"

override=$root/usr/share/glib-2.0/schemas/org.gnome.Ptyxis.fedora.gschema.override
[[ -f $override ]] || fail "Fedora's gschema override (its Source1) is missing"
ok "Fedora's gschema override is still installed"
