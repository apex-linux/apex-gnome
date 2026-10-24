#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# apex-lane's contract (packaging/README.md): exit 1 holds the family, the last line
# giving the reason; exit 2 means the checks could not run.

set -euo pipefail

ok() { printf 'ok %s\n' "$*"; }
fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
cannot() { printf 'check.sh cannot run: %s\n' "$*" >&2; exit 2; }

for v in RPMS_DIR CHECK_WORK; do
    [[ -n ${!v:-} ]] || cannot "$v is not set"
done
command -v gresource >/dev/null || cannot "no gresource (glib2-devel) in the buildroot"
command -v readelf >/dev/null || cannot "no readelf (binutils) in the buildroot"

readonly LIB=/usr/lib64/libadwaita-1.so.0

root=$CHECK_WORK/root
mkdir -p -- "$root"
shopt -s nullglob
main=("$RPMS_DIR"/libadwaita-[0-9]*.x86_64.rpm)
((${#main[@]} == 1)) || fail "expected one libadwaita x86_64 RPM, found ${#main[@]}"
(cd -- "$root" && rpm2cpio "${main[0]}" | cpio -idm --quiet --no-absolute-filenames) ||
    cannot "cannot unpack ${main[0]##*/}"

lib=$root$LIB
[[ -e $lib ]] || fail "no $LIB in ${main[0]##*/}"
lib=$(readlink -f -- "$lib")

symbols=$(readelf --dyn-syms --wide -- "$lib") || fail "readelf cannot read $LIB"
grep -Eq ' FUNC +GLOBAL +DEFAULT +[0-9]+ adw_style_manager_get_default(@@[A-Z0-9_]+)?$' <<<"$symbols" ||
    fail "$LIB no longer exports adw_style_manager_get_default"
ok "$LIB exports adw_style_manager_get_default"

resources=$(gresource list "$lib") || fail "gresource cannot read $LIB"
grep -Fxq -- /org/gnome/Adwaita/styles/gtk.css <<<"$resources" || fail "$LIB has lost the Adwaita stylesheet"
ok "$LIB holds the Adwaita stylesheet"

grep -Faq -- gtk-4.0/apex.css "$lib" || fail "$LIB does not load gtk-4.0/apex.css (0001-apex-css)"
ok "$LIB loads gtk-4.0/apex.css"
