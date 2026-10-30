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
dark-style, their shell surfaces, every Apex surface's contrast and Large Text layout,
and the glass case. Before that, Fedora's gnome-shell of
the same version runs direct.sh's fedora part, the baseline of the glass case's unlock
blur. A probe imported after startup is counted in the log and the job summary. The lane's own checks, signing and the mutter pin's mirror are apex-image's. -e G2_SURFACE_SCENES=1 also captures the surfaces' scenes.

  PATCHED_RPMS=DIR   install the gnome-shell RPMs in DIR instead of building them
  PATCHED_OUT=DIR    keep the RPMs and the run's logs in DIR (default: a temporary one)
  PATCHED_PART=signoff  only direct.sh's signoff part, for signoff.sh: no Fedora baseline, no assertions
  PATCHED_PART=pr       direct.sh's pr part (CI's cases for a pull request) and the fedora part's
                        fedora-light and fedora-dark; only those cases' assertions, and each of
                        them must have run and reported

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
# direct.sh's exit when a case hangs.
readonly DIRECT_HUNG=3

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
    # malcontent-libs, as the image's flatpak-libs brings it: the shells then read parental controls.
    quietly dnf5 -y "${REPOS[@]}" install "gnome-shell-$fedora_vr" mesa-dri-drivers dbus-daemon python3-dbusmock gcc glib2-devel gjs jq procps-ng \
        malcontent-libs
    G2_PR=$([[ ${PATCHED_PART:-} == pr ]] && echo 1 || :) bash /w/direct.sh fedora || echo "# direct.sh fedora: exit $?"
    # direct.sh main starts the system bus and the fixtures afresh.
    pkill -f /w/fixtures.py || true
    pkill -x dbus-daemon || true
    rm -f /run/dbus/pid
}

# What the image gives both shells, so Fedora's baseline and safe mode see the same desktop: its apps
# and, from 90_apex's override, the weekday and the input source's keys, which leave Super+Space to Spotlight.
image_inputs() {
    local keys
    step "the image's apps and overrides, for both shells"
    # Clocks and Weather, as in the image: the calendar shows their rows only when they are installed.
    quietly dnf5 -y "${REPOS[@]}" install nautilus gnome-clocks gnome-weather ibus ibus-m17n m17n-db
    # shellcheck disable=SC2016 # expanded by the inner bash
    keys=$(bash -c '. "$1/parts.sh"; printf "switch-input-source=%s\nswitch-input-source-backward=%s\n" \
        "$INPUT_SOURCE_KEYS" "$INPUT_SOURCE_BACKWARD_KEYS"' _ "$HERE")
    printf '%s\n' '[org.gnome.desktop.interface]' 'clock-show-weekday=true' '[org.gnome.desktop.wm.keybindings]' "$keys" \
        >/usr/share/glib-2.0/schemas/90_g2-patched.gschema.override
    quietly glib-compile-schemas --strict /usr/share/glib-2.0/schemas
}

install_shell() {
    local rpms
    rpms=("$PATCHED_RPMS"/gnome-shell-[0-9]*.x86_64.rpm "$PATCHED_RPMS"/gnome-shell-common-*.noarch.rpm)
    [[ -f ${rpms[0]} && -f ${rpms[1]} ]] || die "no gnome-shell and gnome-shell-common RPMs in $PATCHED_RPMS"
    step "the patched shell, the fixtures' services, gjs and jq"
    quietly dnf5 -y "${REPOS[@]}" install "${rpms[@]}" mesa-dri-drivers dbus-daemon python3-dbusmock gcc glib2-devel gjs jq malcontent-libs
    rpm -q gnome-shell | grep -q "\.apex" ||
        die "the installed gnome-shell is not an Apex build: $(rpm -q gnome-shell)"
    # What apex-desktop ships besides: the schema, the layer's fixture.
    cp "$REPO/tests/layer/fixtures/io.github.apex_linux.Apex.Desktop.gschema.xml" /usr/share/glib-2.0/schemas/
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
step "the Facets backdrops"
bash "$HERE/backdrops.sh" >>"$OUT/dnf.log" 2>&1 || { tail -n 5 "$OUT/dnf.log"; die "backdrops.sh failed; the log is $OUT/dnf.log"; }
image_inputs
if [[ ${PATCHED_PART:-} == signoff ]]; then
    install_shell
    step "direct.sh signoff"
    bash /w/direct.sh signoff
    exit
fi
fedora_part
install_shell

part=${PATCHED_PART:-main}
[[ $part == main || $part == pr ]] || die "PATCHED_PART is signoff, pr or unset, not $part"
step "direct.sh $part"
rc=0
bash /w/direct.sh "$part" || rc=$?
echo "# direct.sh $part: exit $rc"
for p in fedora "$part"; do
    [[ -f $run/late-$p.txt ]] || continue
    late="direct.sh $p: $(wc -l <"$run/late-$p.txt") of $(wc -l <"$run/results-$p.txt") cases' probes were imported after startup: $(paste -sd' ' "$run/late-$p.txt")"
    echo "# $late"
    [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || printf -- '- %s\n' "$late" >>"$GITHUB_STEP_SUMMARY"
done

# The assertions count their own failures; summary's status is the script's.
set +e
# shellcheck source=tests/shots/assert.sh
. "$HERE/assert.sh"
# A hung case stops direct.sh's part, as run.sh stops G2: the cases after it never ran, so one
# failure names it rather than a "no report" for each of them.
if ((rc == DIRECT_HUNG)); then
    hung_part "$run" "$part"
    summary
    exit
fi
patched_assertions "$run" "$part"
echo "# logs and captures: $run"
summary
