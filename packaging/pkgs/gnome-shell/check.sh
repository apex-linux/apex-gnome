#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# apex-lane runs it in the build container after rpmbuild and its generic checks, as
# root, with:
#   RPMS_DIR    the built binary RPMs (no debuginfo)
#   PRISTINE    Fedora's %prep tree without any Apex input
#   SOURCE1     the Source1 archive (desktop/shell/)
#   CHECK_WORK  a scratch directory to create
# These checks need gresource (glib2-devel), which the image lacks.
#
# Exit status: 0 every check passed; 1 a check failed (the family is held; the last
# line is the reason); 2 the checks could not run.

set -euo pipefail

ok() { printf 'ok %s\n' "$*"; }
fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
cannot() { printf 'check.sh cannot run: %s\n' "$*" >&2; exit 2; }

for v in RPMS_DIR PRISTINE SOURCE1 CHECK_WORK; do
    [[ -n ${!v:-} ]] || cannot "$v is not set"
done
command -v gresource >/dev/null || cannot "no gresource (glib2-devel) in the buildroot"

root=$CHECK_WORK/root
mkdir -p -- "$root"
shopt -s nullglob
main=("$RPMS_DIR"/gnome-shell-[0-9]*.x86_64.rpm)
((${#main[@]} == 1)) || fail "expected one gnome-shell x86_64 RPM, found ${#main[@]}"
(cd -- "$root" && rpm2cpio "${main[0]}" | cpio -idm --quiet --no-absolute-filenames) ||
    cannot "cannot unpack ${main[0]##*/}"

libs=("$root"/usr/lib64/gnome-shell/libshell-*.so)
((${#libs[@]} == 1)) || fail "expected one libshell in the package, found ${#libs[@]}"
lib=${libs[0]}
resources=$(gresource list "$lib") || fail "gresource cannot read ${lib##*/}"
for r in /org/gnome/shell/ui/apex/hooks.js /org/gnome/shell/ui/apex/layer.js \
    /org/gnome/shell/theme/stock/gnome-shell-light.css /org/gnome/shell/theme/stock/gnome-shell-dark.css; do
    grep -Fxq -- "$r" <<<"$resources" || fail "${lib##*/} has no $r"
done
ok "${lib##*/} holds the Apex layer and the stock sheets"

# Every JS module of Source1 is in the resource: a module missing from
# apex.gresource.xml would only fail at runtime.
while IFS= read -r m; do
    [[ $m == js/ui/apex/*.js ]] || continue
    grep -Fxq -- "/org/gnome/shell/ui/apex/${m#js/ui/apex/}" <<<"$resources" ||
        fail "$m is in desktop/shell but not in the resource (apex.gresource.xml)"
done < <(tar -tf "$SOURCE1")
ok "every js/ui/apex module of Source1 is in the resource"

# Each resource is read into a variable first: grep -q on a pipe could end the writer
# with SIGPIPE, which pipefail reports as a failure.
js=$(gresource extract "$lib" /org/gnome/shell/ui/main.js) || fail "${lib##*/} has no ui/main.js"
grep -Fq 'ApexHooks.loadLayer(' <<<"$js" || fail "main.js in ${lib##*/} does not load the Apex layer"
js=$(gresource extract "$lib" /org/gnome/shell/ui/sessionMode.js) || fail "${lib##*/} has no ui/sessionMode.js"
grep -Fq "ApexHooks.value('session-mode'" <<<"$js" || fail "sessionMode.js in ${lib##*/} has no session-mode hook"
ok "main.js loads the layer; sessionMode.js has the session-mode hook"

for v in light dark; do
    gresource extract "$lib" "/org/gnome/shell/theme/stock/gnome-shell-$v.css" >"$CHECK_WORK/stock-$v.css" ||
        fail "${lib##*/} has no theme/stock/gnome-shell-$v.css"
    cmp -s -- "$CHECK_WORK/stock-$v.css" "$PRISTINE/data/theme/gnome-shell-$v.css" ||
        fail "theme/stock/gnome-shell-$v.css differs from the gnome-shell-$v.css upstream ships"
done
ok "theme/stock/ holds upstream's shipped light and dark sheets"

theme=$root/usr/share/gnome-shell/gnome-shell-theme.gresource
[[ -f $theme ]] || fail "no ${theme#"$root"} in the package"
for v in light dark high-contrast; do
    gresource extract "$theme" "/org/gnome/shell/theme/gnome-shell-$v.css" >"$CHECK_WORK/$v.css" ||
        fail "gnome-shell-theme.gresource has no gnome-shell-$v.css"
done
for v in light dark; do
    grep -Fq "/*! apex-shell-theme $v */" "$CHECK_WORK/$v.css" || fail "the $v sheet has no Apex marker"
    grep -Eq '^\.apex-theme-marker[[:space:]]*\{' "$CHECK_WORK/$v.css" ||
        fail "the $v sheet has no .apex-theme-marker rule"
    if cmp -s -- "$CHECK_WORK/$v.css" "$PRISTINE/data/theme/gnome-shell-$v.css"; then
        fail "the $v sheet is the one upstream ships, not a sassc build"
    fi
done
grep -Fq '/*! apex-shell-structure */' "$CHECK_WORK/high-contrast.css" ||
    fail "the high-contrast sheet has no Apex structure marker"
ok "the light and dark sheets carry the Apex marker, the high-contrast sheet the structure marker"
