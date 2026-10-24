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

readonly APEX_PREFIX=/org/gnome/Settings/apex
readonly SOURCE1_DIR=panels/apex/

root=$CHECK_WORK/root
mkdir -p -- "$root"
shopt -s nullglob
unpack() {
    local what=$1
    shift
    (($# == 1)) || fail "expected one $what RPM, found $#"
    (cd -- "$root" && rpm2cpio "$1" | cpio -idm --quiet --no-absolute-filenames) ||
        cannot "cannot unpack ${1##*/}"
}
unpack "gnome-control-center x86_64" "$RPMS_DIR"/gnome-control-center-[0-9]*.x86_64.rpm
unpack "gnome-control-center-filesystem noarch" "$RPMS_DIR"/gnome-control-center-filesystem-[0-9]*.noarch.rpm

bin=$root/usr/bin/gnome-control-center
[[ -f $bin ]] || fail "no /usr/bin/gnome-control-center"
resources=$(gresource list "$bin") || fail "gresource cannot read /usr/bin/gnome-control-center"
grep -Fxq -- /org/gnome/Settings/gtk/cc-window.ui <<<"$resources" ||
    fail "gnome-control-center has lost upstream's resource"
ok "/usr/bin/gnome-control-center holds upstream's resource"

# A file missing from apex.gresource.xml would otherwise fail only at runtime.
members=$(tar -tf "$SOURCE1") || cannot "cannot list $SOURCE1"
n=0
while IFS= read -r m; do
    [[ $m == "$SOURCE1_DIR"* && $m != */ ]] || continue
    case ${m##*/} in meson.build | *.gresource.xml | *.[ch] | *.desktop.in) continue ;; esac
    grep -Fxq -- "$APEX_PREFIX/${m#"$SOURCE1_DIR"}" <<<"$resources" ||
        fail "$m is in desktop/control-center but not in the resource (apex.gresource.xml)"
    n=$((n + 1))
done <<<"$members"
((n > 0)) || fail "Source1 has no resource file under $SOURCE1_DIR"
ok "every resource file of Source1 ($n) is in $APEX_PREFIX"

css=$(gresource extract "$bin" "$APEX_PREFIX/apex.css") ||
    fail "gnome-control-center has no $APEX_PREFIX/apex.css"
grep -Fq '/*! apex-control-center */' <<<"$css" || fail "$APEX_PREFIX/apex.css has no Apex marker"
ok "$APEX_PREFIX/apex.css carries the Apex marker"

for d in /usr/share/gnome-control-center/keybindings /usr/share/gnome/wm-properties; do
    [[ -d $root$d ]] || fail "gnome-control-center-filesystem has lost $d"
done
[[ -f $root/usr/share/applications/org.gnome.Settings.desktop ]] || fail "no org.gnome.Settings.desktop"
ok "the -filesystem directories and org.gnome.Settings.desktop are installed"
