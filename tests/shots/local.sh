#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/local.sh [OUT_DIR]

The Apex shell's captures and metrics without the builder VM. In a throwaway Fedora 45
container it rebuilds Fedora's gnome-shell SRPM as the lane does (spec-edit, the series,
Source1 from this working tree, so uncommitted SCSS counts), then in a second one runs
direct.sh's apex part on that build, with Fedora's mutter, fixtures.py and clock.c, and
asserts the top bar and the shell surfaces from the token file. OUT_DIR (default
_build/local) gets the RPMs, the logs, captures/ with each case's desktop, overview and
surfaces scenes, and assert.txt. It exits 1 when an assertion fails.

It is not G2: the shells run on Fedora's packages, not the built image, and the build
is unsigned. It needs podman or docker, and network access to Fedora's repositories;
LOCAL_CA, a PEM file, is trusted inside the containers, for a TLS-intercepting proxy.
EOF
}

readonly FEDORA=registry.fedoraproject.org/fedora:45@sha256:1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb
readonly RUN_PACKAGES=(mesa-dri-drivers dbus-daemon python3-dbusmock gcc gjs jq gawk procps-ng)
readonly SCHEMA=io.github.apex_linux.Apex.Desktop.gschema.xml

# spec-edit's format (packaging/README.md in apex-image): "replace RE" or "after RE", then
# tab-indented lines up to "end"; each RE must match exactly one line of the spec.
apply_spec_edit() {
    local edits=$1 spec=$2
    awk -v edits="$edits" '
        BEGIN {
            while ((getline line < edits) > 0) {
                if (!open && (line ~ /^#/ || line ~ /^[ \t]*$/)) continue
                if (!open && match(line, /^(replace|after) /)) {
                    n++; kind[n] = substr(line, 1, RLENGTH - 1); re[n] = substr(line, RLENGTH + 1); open = 1; continue
                }
                if (open && line == "end") { open = 0; continue }
                sub(/^\t/, "", line); body[n] = body[n] (body[n] == "" ? "" : "\n") line
            }
        }
        {
            out = $0; extra = ""
            for (i = 1; i <= n; i++) if ($0 ~ re[i]) {
                hits[i]++
                if (kind[i] == "replace") out = body[i]; else extra = extra "\n" body[i]
            }
            print out extra
        }
        END {
            for (i = 1; i <= n; i++) if (hits[i] != 1) { printf "spec-edit: \"%s %s\" matched %d lines\n", kind[i], re[i], hits[i] > "/dev/stderr"; bad = 1 }
            exit bad
        }' "$spec"
}

trust_local_ca() {
    if [[ -f /run/local-ca.pem ]]; then
        cp /run/local-ca.pem /etc/pki/ca-trust/source/anchors/local-ca.pem
        update-ca-trust
    fi
    [[ -z ${HTTPS_PROXY:-} ]] || echo "proxy=$HTTPS_PROXY" >>/etc/dnf/dnf.conf
}

dnf_install() {
    dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install "$@"
}

inside_build() {
    local pkg=/src/packaging/pkgs/gnome-shell top=/out/rpmbuild n=1001 patch evr
    trust_local_ca
    dnf_install rpm-build dnf5-plugins sassc git-core
    rm -rf "$top" && mkdir -p "$top/SOURCES" "$top/SPECS"
    (cd "$top/SOURCES" && dnf5 -q download --source --repo=fedora --repo=updates gnome-shell)
    dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates builddep "$top"/SOURCES/gnome-shell-*.src.rpm
    (cd "$top/SOURCES" && rpm2cpio gnome-shell-*.src.rpm | cpio -id --quiet && rm gnome-shell-*.src.rpm)
    tar -C /src/desktop/shell -cf "$top/SOURCES/apex-shell.tar" .
    evr=$(rpm -q --qf '%{VERSION}-%{RELEASE}' mutter-devel)
    sed -e 's|@APEX_RELEASE@|.apex0|' -e 's|@SOURCE1@|apex-shell.tar|' -e "s|@PIN_EVR@|$evr|" \
        "$pkg/spec-edit" >/tmp/spec-edit
    apply_spec_edit /tmp/spec-edit "$top/SOURCES/gnome-shell.spec" >"$top/SPECS/gnome-shell.spec"
    # The lane numbers the series from Patch1001, after Fedora's own patches.
    while read -r patch; do
        [[ -z $patch || $patch == \#* ]] && continue
        cp "$pkg/patches/$patch" "$top/SOURCES/"
        sed -i "0,/^Source1:/s//Patch$n: $patch\n&/" "$top/SPECS/gnome-shell.spec"
        n=$((n + 1))
    done <"$pkg/series"
    rpmbuild -bb --nocheck --define "_topdir $top" "$top/SPECS/gnome-shell.spec" >/out/rpmbuild.log 2>&1 ||
        { tail -n 40 /out/rpmbuild.log >&2; exit 1; }
}

inside_run() {
    local rpms=(/out/rpmbuild/RPMS/*/gnome-shell-[0-9]*.x86_64.rpm /out/rpmbuild/RPMS/noarch/gnome-shell-common-*.rpm)
    trust_local_ca
    dnf_install --nogpgcheck "${rpms[@]}" "${RUN_PACKAGES[@]}"
    cp "/src/tests/layer/fixtures/$SCHEMA" /usr/share/glib-2.0/schemas/
    printf '[org.gnome.desktop.interface]\nclock-show-weekday=true\n' >/usr/share/glib-2.0/schemas/90_g2-local.gschema.override
    glib-compile-schemas /usr/share/glib-2.0/schemas
    rm -rf /out/captures /out/*.log && mkdir -p /out/captures
    ln -sfn /src/tests/shots /w
    bash /w/direct.sh apex
    set +e
    # shellcheck source=tests/shots/assert.sh
    . /w/assert.sh
    {
        no_js_error default /out/default.log
        top_bar default /out/default.log light
        shell_surfaces default /out/default.log light
        quick_settings default /out/default.log light
        no_js_error dark-style /out/dark-style.log
        top_bar dark-style /out/dark-style.log dark
        shell_surfaces dark-style /out/dark-style.log dark
        quick_settings dark-style /out/dark-style.log dark
        summary
    } >/out/assert.txt
    local status=$?
    grep -v '^PASS' /out/assert.txt
    return "$status"
}

container() {
    local engine=$1 out=$2 repo=$3
    shift 3
    local -a args=(run --rm --privileged --net=host --security-opt=label=disable
        -v "$repo:/src:ro" -v "$out:/out" -e HTTPS_PROXY="${HTTPS_PROXY:-}")
    [[ -z ${LOCAL_CA:-} ]] || args+=(-v "$LOCAL_CA:/run/local-ca.pem:ro")
    "$engine" "${args[@]}" "$FEDORA" bash /src/tests/shots/local.sh "$@"
}

main() {
    case ${1:-} in
        -h | --help) usage; exit 0 ;;
        --inside-build) inside_build; exit ;;
        --inside-run) inside_run; exit ;;
    esac
    local here repo out engine
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    repo=$(cd -- "$here/../.." && pwd)
    out=${1:-$repo/_build/local}
    engine=$(command -v podman || command -v docker) || { echo "local.sh: needs podman or docker" >&2; exit 2; }
    [[ -z ${LOCAL_CA:-} || -f $LOCAL_CA ]] || { echo "local.sh: LOCAL_CA=$LOCAL_CA is not a file" >&2; exit 2; }
    mkdir -p "$out"
    out=$(cd -- "$out" && pwd)
    echo "# local.sh: building gnome-shell with this tree's desktop/shell/ ($out/rpmbuild.log)"
    container "$engine" "$out" "$repo" --inside-build
    echo "# local.sh: the apex cases, then the assertions ($out/assert.txt)"
    container "$engine" "$out" "$repo" --inside-run
}

main "$@"
