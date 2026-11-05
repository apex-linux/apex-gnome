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

root=$CHECK_WORK/root
mkdir -p -- "$root"
shopt -s nullglob
main=("$RPMS_DIR"/gnome-builder-[0-9]*.x86_64.rpm)
((${#main[@]} == 1)) || fail "expected one gnome-builder x86_64 RPM, found ${#main[@]}"
(cd -- "$root" && rpm2cpio "${main[0]}" | cpio -idm --quiet --no-absolute-filenames) ||
    cannot "cannot unpack ${main[0]##*/}"

bin=$root/usr/bin/gnome-builder
[[ -f $bin ]] || fail "no /usr/bin/gnome-builder in ${main[0]##*/}"
resources=$(gresource list "$bin") || fail "gresource cannot read /usr/bin/gnome-builder"
grep -Fxq -- /plugins/podman/podman.plugin <<<"$resources" || fail "gnome-builder has lost upstream's podman plugin"
ok "/usr/bin/gnome-builder holds upstream's podman plugin"

# The marker: the Apex Code plugin's resource, from Source1's src/plugins/apex/.
plugin=$(gresource extract "$bin" /plugins/apex/apex.plugin) || fail "gnome-builder has no /plugins/apex/apex.plugin"
grep -Fxq 'Module=apex' <<<"$plugin" || fail "/plugins/apex/apex.plugin is not the Apex Code plugin"
grep -Fxq 'Embedded=_gbp_apex_register_types' <<<"$plugin" || fail "the Apex Code plugin is not built in"
ok "/usr/bin/gnome-builder carries the Apex Code plugin (/plugins/apex/apex.plugin)"

desktop=$root/usr/share/applications/org.gnome.Builder.desktop
[[ -f $desktop ]] || fail "no org.gnome.Builder.desktop: the app id must stay org.gnome.Builder"
grep -Fxq 'Name=Apex Code' "$desktop" || fail "org.gnome.Builder.desktop is not named Apex Code"
! grep -q '^Name\[' <(sed -n '/^\[Desktop Entry\]/,/^\[/p' "$desktop") || fail "org.gnome.Builder.desktop translates its Name"
ok "org.gnome.Builder.desktop is named Apex Code, untranslated"

[[ -f $root/usr/share/locale/vi/LC_MESSAGES/apex-builder.mo ]] || fail "the gnome-builder RPM has no vi apex-builder.mo"
ok "the gnome-builder RPM carries Apex's vi catalogue"
