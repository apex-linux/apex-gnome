#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/patched.sh

The patched shell before a builder VM sees it, as root in a throwaway Fedora 45 container:
rebuilds Fedora's gnome-shell SRPM with this checkout's recipe (spec-edit, the series and
desktop/shell/ from the working tree as Source1), installs it with the layer's schema
fixture, runs direct.sh's main part, then asserts what needs no image: each case's log and
the top bar's metrics, today's pins and the known gaps of default, default-scale1 and
dark-style, their shell surfaces, and the glass case. Before that, Fedora's gnome-shell of
the same version runs direct.sh's fedora part, the baseline of the glass case's unlock
blur. The lane's own checks, signing and the mutter pin's mirror are apex-image's. -e G2_SURFACE_SCENES=1 also captures the surfaces' scenes.

  PATCHED_RPMS=DIR   install the gnome-shell RPMs in DIR instead of building them
  PATCHED_OUT=DIR    keep the RPMs and the run's logs in DIR (default: a temporary one)

  docker run --rm --network=host -v "$PWD:/src:ro" registry.fedoraproject.org/fedora:45 \
      /src/tests/shots/patched.sh
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
esac
# It replaces the system's gnome-shell and stops logind's seats: never outside a container.
[[ -e /run/.containerenv || -e /.dockerenv ]] || { echo "patched.sh: only inside a throwaway container" >&2; exit 2; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
RECIPE=$REPO/packaging/pkgs/gnome-shell
OUT=${PATCHED_OUT:-$(mktemp -d)}
REPOS=(--repo=fedora --repo=updates)
readonly LOCAL_RELEASE=.apex0.local
readonly SOURCE1=apex-shell-local.tar
readonly PATCH_BASE=1001

die() { echo "patched.sh: $*" >&2; exit 1; }
step() { echo "## $* ($((SECONDS))s)"; }
quietly() {
    "$@" >>"$OUT/dnf.log" 2>&1 || { tail -n 20 "$OUT/dnf.log"; die "$* failed; the log is $OUT/dnf.log"; }
}

# spec-edit's format (packaging/README.md in apex-image): "replace RE" or "after RE",
# tab-indented lines, "end"; each RE must match exactly one line of the spec.
apply_spec_edit() {
    local spec=$1 edits=$2 pin_evr=$3
    awk -v pin="$pin_evr" -v release="$LOCAL_RELEASE" -v source1="$SOURCE1" '
        function fail(msg) { print "spec-edit: " msg > "/dev/stderr"; failed = 1; exit 1 }
        FNR == NR {
            if ($0 ~ /^(#|$)/ && !inblock) next
            if (!inblock && match($0, /^(replace|after) /)) {
                n++; op[n] = $1; re[n] = substr($0, RLENGTH + 1); body[n] = ""; inblock = 1; next
            }
            if (inblock && $0 == "end") { inblock = 0; next }
            if (inblock && /^\t/) {
                line = substr($0, 2)
                gsub(/@APEX_RELEASE@/, release, line); gsub(/@SOURCE1@/, source1, line)
                gsub(/@PIN_EVR@/, pin, line)
                if (line ~ /@[A-Z0-9_]+@/) fail("unknown placeholder in: " line)
                body[n] = body[n] line "\n"; next
            }
            fail("cannot read line " FNR ": " $0)
        }
        { spec[++lines] = $0 }
        END {
            if (failed) exit 1
            if (inblock) fail("a block has no end")
            for (i = 1; i <= n; i++) {
                hits = 0
                for (j = 1; j <= lines; j++) if (spec[j] ~ re[i]) { hits++; at[i] = j }
                if (hits != 1) fail(re[i] " matches " hits " lines of the spec, not 1")
            }
            for (j = 1; j <= lines; j++) {
                done = 0
                for (i = 1; i <= n; i++) if (at[i] == j && op[i] == "replace") { printf "%s", body[i]; done = 1 }
                if (!done) print spec[j]
                for (i = 1; i <= n; i++) if (at[i] == j && op[i] == "after") printf "%s", body[i]
            }
        }' "$edits" "$spec" >"$spec.edited"
    mv "$spec.edited" "$spec"
}

build_rpms() {
    local top=$OUT/rpmbuild spec pin_evr patch n=$PATCH_BASE patch_lines=''
    step "Fedora's gnome-shell SRPM"
    quietly dnf5 -y "${REPOS[@]}" install dnf5-plugins rpm-build git-core tar gawk
    mkdir -p "$OUT/srpm" "$top"
    (cd "$OUT/srpm" && dnf5 -q --repo=fedora-source --repo=updates-source download --source gnome-shell)
    rpm -i --define "_topdir $top" "$OUT"/srpm/gnome-shell-*.src.rpm
    spec=$top/SPECS/gnome-shell.spec

    step "the recipe: spec-edit, the series and Source1"
    pin_evr=$(dnf5 -q "${REPOS[@]}" repoquery --latest-limit=1 --qf '%{evr}\n' mutter-devel | tail -n 1)
    [[ -n $pin_evr ]] || die "no mutter-devel in ${REPOS[*]}"
    apply_spec_edit "$spec" "$RECIPE/spec-edit" "$pin_evr"
    while read -r patch; do
        [[ -z $patch || $patch == \#* ]] && continue
        cp "$RECIPE/patches/$patch" "$top/SOURCES/"
        patch_lines+="Patch$n: $patch"$'\n'
        n=$((n + 1))
    done <"$RECIPE/series"
    [[ $(grep -c '^Patch:' "$spec") == 1 ]] || die "the spec has no single unnumbered Patch: line to follow"
    awk -v add="$patch_lines" '{ print } /^Patch:/ { printf "%s", add }' "$spec" >"$spec.edited"
    mv "$spec.edited" "$spec"
    read -ra paths <<<"$(sed -n 's/^source1_paths=//p' "$RECIPE/pkg.env")"
    tar -C "$REPO/desktop/shell" -cf "$top/SOURCES/$SOURCE1" "${paths[@]}"

    step "the build dependencies"
    quietly dnf5 -y "${REPOS[@]}" builddep "$spec"
    step "rpmbuild (patches with git apply, no fuzz)"
    rpmbuild -bb --nocheck --define "_topdir $top" "$spec" >"$OUT/rpmbuild.log" 2>&1 ||
        { tail -n 40 "$OUT/rpmbuild.log"; die "rpmbuild failed; the log is $OUT/rpmbuild.log"; }
    mkdir -p "$OUT/rpms"
    cp "$top"/RPMS/*/gnome-shell-[0-9]*.rpm "$top"/RPMS/noarch/gnome-shell-common-*.rpm "$OUT/rpms/"
    PATCHED_RPMS=$OUT/rpms
}

# Fedora's own shell of the same version first, for the glass case's unlock blur.
fedora_part() {
    local fedora_vr
    fedora_vr=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$PATCHED_RPMS"/gnome-shell-[0-9]*.x86_64.rpm | sed -E 's/\.apex[0-9.]*(\.local)?$//')
    step "Fedora's gnome-shell $fedora_vr: direct.sh fedora"
    quietly dnf5 -y "${REPOS[@]}" install "gnome-shell-$fedora_vr" mesa-dri-drivers dbus-daemon python3-dbusmock gcc glib2-devel gjs jq procps-ng
    bash /w/direct.sh fedora || echo "# direct.sh fedora: exit $?"
    # direct.sh main starts the system bus and the fixtures afresh.
    pkill -f /w/fixtures.py || true
    pkill -x dbus-daemon || true
    rm -f /run/dbus/pid
}

install_shell() {
    local rpms
    rpms=("$PATCHED_RPMS"/gnome-shell-[0-9]*.x86_64.rpm "$PATCHED_RPMS"/gnome-shell-common-*.noarch.rpm)
    [[ -f ${rpms[0]} && -f ${rpms[1]} ]] || die "no gnome-shell and gnome-shell-common RPMs in $PATCHED_RPMS"
    step "the patched shell, the fixtures' services, gjs and jq"
    quietly dnf5 -y "${REPOS[@]}" install "${rpms[@]}" mesa-dri-drivers dbus-daemon python3-dbusmock gcc glib2-devel gjs jq nautilus
    rpm -q gnome-shell | grep -q "\.apex" ||
        die "the installed gnome-shell is not an Apex build: $(rpm -q gnome-shell)"
    # What apex-desktop ships: the schema (the layer's fixture) and the weekday override.
    cp "$REPO/tests/layer/fixtures/io.github.apex_linux.Apex.Desktop.gschema.xml" /usr/share/glib-2.0/schemas/
    printf '[org.gnome.desktop.interface]\nclock-show-weekday=true\n' >/usr/share/glib-2.0/schemas/90_g2-patched.gschema.override
    quietly glib-compile-schemas --strict /usr/share/glib-2.0/schemas
}

mkdir -p "$OUT"
if [[ -z ${PATCHED_RPMS:-} ]]; then
    build_rpms
fi
run=$OUT/run
rm -rf "$run"
mkdir -p "$run/captures"
ln -sfn "$HERE" /w
ln -sfn "$run" /out
fedora_part
install_shell

step "direct.sh main"
rc=0
bash /w/direct.sh main || rc=$?
echo "# direct.sh main: exit $rc"

# The assertions count their own failures; summary's status is the script's.
set +e
# shellcheck source=tests/shots/assert.sh
. "$HERE/assert.sh"
for c in default default-scale1 dark-style stock-light stock-dark safe-env layer-disabled layer-cycles motion; do
    no_js_error "$c" "$run/$c.log"
    fixed_clock "$c" "$run/$c.log"
done
for c in default default-scale1 dark-style; do
    exits "$run" "$c" 0
    no_apex_failure "$c" "$run/$c.log"
done
search_hint default "$run/default.log" true
search_hint safe-env "$run/safe-env.log" false
top_bar default "$run/default.log" light
top_bar_today default "$run/default.log" light
top_bar_gaps default "$run/default.log" light
top_bar default-scale1 "$run/default-scale1.log" light
top_bar_today default-scale1 "$run/default-scale1.log" light
top_bar dark-style "$run/dark-style.log" dark
top_bar_today dark-style "$run/dark-style.log" dark
top_bar_gaps dark-style "$run/dark-style.log" dark
dock_metrics default "$run/default.log" light
dock_metrics default-scale1 "$run/default-scale1.log" light
dock_metrics dark-style "$run/dark-style.log" dark
for c in dock-intellihide dock-intellihide-dark; do
    exits "$run" "$c" 0
    no_js_error "$c" "$run/$c.log"
    no_apex_failure "$c" "$run/$c.log"
    dock_intellihide "$c" "$run/$c.log" "$run"
done
no_dock stock-light "$run/stock-light.log"
no_dock stock-dark "$run/stock-dark.log"
for c in default:light default-scale1:light dark-style:dark; do
    shell_surfaces "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    quick_settings "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    quick_settings_layer "${c%:*}" "$run/${c%:*}.log" apex
    window_switcher "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    modal_dialog "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    date_menu "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    overview_style "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    app_grid "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    overview_layer "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    derived_surfaces "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    tile_preview "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    spotlight_style "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
    screenshot_ui "${c%:*}" "$run/${c%:*}.log" "${c#*:}"
done
for c in stock-light stock-dark; do
    quick_settings_layer "$c" "$run/$c.log" stock
done
layer_cycles "$run"
motion_curve "$run"
no_js_error glass "$run/glass.log"
glass_frames glass "$run/glass.log"
glass_manager glass "$run/glass.log" light
glass_unlock_vs_fedora "$run"
echo "# logs and captures: $run"
summary
