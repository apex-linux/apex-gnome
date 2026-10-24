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

readonly APEX_PREFIX=/org/gnome/nautilus/apex
readonly SOURCE1_DIR=src/apex/

root=$CHECK_WORK/root
mkdir -p -- "$root"
shopt -s nullglob
for name in nautilus nautilus-extensions; do
    rpms=("$RPMS_DIR/$name"-[0-9]*.x86_64.rpm)
    ((${#rpms[@]} == 1)) || fail "expected one $name x86_64 RPM, found ${#rpms[@]}"
    (cd -- "$root" && rpm2cpio "${rpms[0]}" | cpio -idm --quiet --no-absolute-filenames) ||
        cannot "cannot unpack ${rpms[0]##*/}"
done

bin=$root/usr/bin/nautilus
[[ -f $bin ]] || fail "no /usr/bin/nautilus in the nautilus RPM"
resources=$(gresource list "$bin") || fail "gresource cannot read /usr/bin/nautilus"
grep -Fxq -- /org/gnome/nautilus/ui/nautilus-window.ui <<<"$resources" || fail "nautilus has lost upstream's resource"
ok "/usr/bin/nautilus holds upstream's resource"

# A file missing from apex.gresource.xml would otherwise fail only at runtime.
members=$(tar -tf "$SOURCE1") || cannot "cannot list $SOURCE1"
n=0
while IFS= read -r m; do
    [[ $m == "$SOURCE1_DIR"* && $m != */ ]] || continue
    case ${m##*/} in meson.build | *.gresource.xml | *.[ch]) continue ;; esac
    grep -Fxq -- "$APEX_PREFIX/${m#"$SOURCE1_DIR"}" <<<"$resources" ||
        fail "$m is in desktop/nautilus but not in the resource (apex.gresource.xml)"
    n=$((n + 1))
done <<<"$members"
((n > 0)) || fail "Source1 has no resource file under $SOURCE1_DIR"
ok "every resource file of Source1 ($n) is in $APEX_PREFIX"

css=$(gresource extract "$bin" "$APEX_PREFIX/apex.css") || fail "nautilus has no $APEX_PREFIX/apex.css"
grep -Fq '/*! apex-nautilus */' <<<"$css" || fail "$APEX_PREFIX/apex.css has no Apex marker"
ok "$APEX_PREFIX/apex.css carries the Apex marker"

grep -aFq org.gnome.Ptyxis "$bin" || fail "Fedora's default-terminal.patch is missing from /usr/bin/nautilus"
ok "Fedora's default-terminal.patch is still applied"

[[ -n $(compgen -G "$root/usr/lib64/libnautilus-extension.so.4*") ]] || fail "nautilus-extensions has no libnautilus-extension.so.4"
ok "nautilus-extensions still ships libnautilus-extension.so.4"
