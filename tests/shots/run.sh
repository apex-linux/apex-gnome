#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/run.sh [IMAGE]

G2, the headless shell, in the builder VM as the builder user, with rootful podman.
IMAGE defaults to localhost/apex:build (just vm-image).

Runs G2 G2_RUNS times (default 2) against IMAGE, each run into
_build/g2/<UTC time>/run-N, then asserts each run (assert.sh) and that every run agrees
with the first (stable.sh). Exit 0 when every assertion passed; result.txt names the
image, the number of runs, the sha256 of the lane lock the image carries and the status.
The newest 5 <UTC time> directories are kept.

Environment: G2_IMAGE_DIR, the image/ directory of an apex-image checkout, and
G2_REPOS_BASE, the REPOS_BASE of its Containerfile (both required); G2_RUNS; G2_OUT_DIR
(default _build/g2).
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
esac

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
readonly HERE REPO
readonly IMAGE_DIR=${G2_IMAGE_DIR:-}
readonly REPOS_BASE=${G2_REPOS_BASE:-}
readonly OUT_DIR=${G2_OUT_DIR:-$REPO/_build/g2}
readonly IMAGE=${1:-localhost/apex:build}
readonly RUNS=${G2_RUNS:-2}
# ROADMAP S2b's 5 minutes of glass stress; patched.sh's runs take direct.sh's 60 s.
readonly VM_GLASS_STRESS_SECONDS=300
# The image has no dbus-daemon, which dbus-run-session and the direct cases' system bus
# need, nor the fixtures' python3-dbusmock and the gcc that builds clock.c.
readonly BUS_IMAGE=localhost/apex-g2-bus
readonly FIXTURE_PACKAGES=(python3-dbusmock gcc glib2-devel)
readonly FEDORA_BUS_IMAGE=localhost/apex-g2-fedora
readonly SHELL_PACKAGES=(gnome-shell gnome-shell-common mutter mutter-common apex-desktop)
readonly FEDORA_KEY=/usr/share/pki/rpm-gpg/RPM-GPG-KEY-fedora-45-primary
readonly KERNEL_FIXTURE='BOOT_IMAGE=(hd0,gpt2)/boot/ostree/apex/vmlinuz root=UUID=0 rw apex.safe=1 rhgb quiet'
readonly GUARD_TIMEOUT=900
readonly DIRECT_HUNG=3
readonly KEEP_G2_STAMPS=5
# glycin decodes and encodes images in bwrap sandboxes, whose devpts mount SELinux denies
# to a container; the shell's startup then sometimes never completes.
readonly NO_SELINUX_LABELS=--security-opt=label=disable

log() { printf '== %s\n' "$*"; }
die() { printf 'run.sh: %s\n' "$*" >&2; exit 1; }

[[ $RUNS =~ ^[1-9][0-9]*$ ]] || die "G2_RUNS must be a positive number, got '$RUNS'"
[[ -f $IMAGE_DIR/Containerfile ]] || die "G2_IMAGE_DIR must be the image/ directory of an apex-image checkout, got '$IMAGE_DIR'"
[[ -n $REPOS_BASE ]] || die "G2_REPOS_BASE must be set (the REPOS_BASE of $IMAGE_DIR/Containerfile)"
sudo podman image exists "$IMAGE" || die "no image $IMAGE in root's container storage (just vm-image builds it)"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
root=$OUT_DIR/$stamp
mkdir -p "$root"
ln -sfn "$stamp" "$OUT_DIR/latest"
guard_containers=()

# shellcheck disable=SC2329 # the EXIT trap calls it
remove_leftovers() {
    sudo podman rm -f "g2-bus-$stamp" "g2-fedora-$stamp" "${guard_containers[@]}" >/dev/null 2>&1 || true
    sudo podman rmi "$FEDORA_BUS_IMAGE" "$BUS_IMAGE" >/dev/null 2>&1 || true
}

prune_old_runs() {
    local old
    find "$OUT_DIR" -mindepth 1 -maxdepth 1 -type d -name '2*Z' -printf '%f\n' | LC_ALL=C sort -r |
        tail -n +$((KEEP_G2_STAMPS + 1)) | while IFS= read -r old; do
            sudo rm -rf -- "${OUT_DIR:?}/$old"
        done
}

prepare_bus_image() {
    local ctr=g2-bus-$stamp
    log "the bus image: $IMAGE plus dbus-daemon and the fixtures' ${FIXTURE_PACKAGES[*]}, the shell's packages verified before and after"
    sudo podman rm -f "$ctr" >/dev/null 2>&1 || true
    # shellcheck disable=SC2016,SC2024 # expanded by the container's bash; builder owns the results
    sudo podman run --name "$ctr" --env G2_FIXTURE_PACKAGES="${FIXTURE_PACKAGES[*]}" --entrypoint /bin/bash "$IMAGE" -c '
        set -u
        echo "# before dbus-daemon"
        rpm -q "$@"
        rpm -V --nomtime "$@"
        echo "rpm -V rc=$?"
        IFS=" " read -ra fixtures <<<"$G2_FIXTURE_PACKAGES"
        same=dbus-daemon-$(rpm -q --qf "%{EPOCHNUM}:%{VERSION}-%{RELEASE}" dbus-libs)
        dnf5 -y --setopt=install_weak_deps=False install "$same" "${fixtures[@]}" ||
            dnf5 -y --setopt=install_weak_deps=False install dbus-daemon "${fixtures[@]}" || exit 1
        dnf5 clean all >/dev/null
        echo "# after dbus-daemon"
        rpm -q "$@" dbus-daemon "${fixtures[@]}"
        rpm -V --nomtime "$@"
        echo "rpm -V rc=$?"
    ' _ "${SHELL_PACKAGES[@]}" >"$root/bus-image.txt" 2>&1 ||
        { tail -n 20 "$root/bus-image.txt" >&2; die "cannot install dbus-daemon into a container of $IMAGE"; }
    sudo podman commit -q "$ctr" "$BUS_IMAGE" >/dev/null
    sudo podman rm "$ctr" >/dev/null
}

prepare_fedora_image() {
    local ctr=g2-fedora-$stamp rpms=$root/fedora-rpms apex_vr fedora_vr
    apex_vr=$(sudo podman run --rm --entrypoint rpm "$BUS_IMAGE" -q --qf '%{VERSION}-%{RELEASE}' gnome-shell)
    fedora_vr=$(sed -E 's/\.apex[0-9]+(\.[0-9]+)?$//' <<<"$apex_vr")
    log "the baseline: Fedora's gnome-shell $fedora_vr in place of $apex_vr"
    mkdir -p "$rpms"
    # shellcheck disable=SC2024 # builder owns the results
    sudo podman run --rm --net=host -v "$rpms:/rpms:z" "$REPOS_BASE" \
        dnf5 -q download --destdir /rpms --repo fedora --repo updates --repo updates-testing \
        "gnome-shell-$fedora_vr.x86_64" "gnome-shell-common-$fedora_vr.noarch" >"$root/fedora-download.txt" 2>&1 ||
        { cat "$root/fedora-download.txt" >&2; die "cannot download Fedora's gnome-shell $fedora_vr"; }
    sudo podman rm -f "$ctr" >/dev/null 2>&1 || true
    # shellcheck disable=SC2016,SC2024 # expanded by the container's bash; builder owns the results
    sudo podman run --name "$ctr" -v "$rpms:/rpms:ro,z" --entrypoint /bin/bash "$BUS_IMAGE" -c '
        set -eu
        fedora_key_only=$(mktemp -d)
        rpmkeys --root "$fedora_key_only" --import "$1"
        for package in /rpms/*.rpm; do
            verdict=$(rpmkeys --root "$fedora_key_only" --checksig "$package") || true
            echo "$verdict"
            [[ $verdict == "$package: digests signatures OK" ]] ||
                { echo "$package is not signed with the only key in this keyring, Fedora 45'\''s"; exit 1; }
        done
        rpmkeys --import "$1"
        rpm -U --oldpackage /rpms/*.rpm
        rpm -q gnome-shell gnome-shell-common
        rpm -q --qf "%{NAME} %|RSAHEADER?{%{RSAHEADER:pgpsig}}:{unsigned}|\n" gnome-shell gnome-shell-common
        rpm -V --nomtime gnome-shell gnome-shell-common
        echo "baseline: Fedora-signed"
    ' _ "$FEDORA_KEY" >"$root/fedora-image.txt" 2>&1 ||
        { tail -n 20 "$root/fedora-image.txt" >&2; die "cannot put Fedora's gnome-shell $fedora_vr into the bus image"; }
    sudo podman commit -q "$ctr" "$FEDORA_BUS_IMAGE" >/dev/null
    sudo podman rm "$ctr" >/dev/null
}

working_tree_object() {
    local index
    index=$(mktemp -d)/index
    GIT_INDEX_FILE=$index git -C "$REPO" add -A . && GIT_INDEX_FILE=$index git -C "$REPO" write-tree
    rm -rf -- "${index%/index}"
}

# A hung shell would make every later case, and the next run, wait out the timeout as well.
direct_failed() {
    local part=$1 out=$2 rc=$3
    ((rc != DIRECT_HUNG)) || die "direct.sh $part hung in ${out##*/}, so G2 stops here: $(grep -m1 ': no report within' "$out/direct-$part.txt")"
    echo "direct.sh $part: exit $rc"
}

one_run() {
    local out=$1 name rc
    name=g2-$stamp-${out##*/}
    mkdir -p "$out/captures"
    cp "$root/bus-image.txt" "$out/rpm.txt"
    cp "$root/fedora-image.txt" "$out/fedora-image.txt"
    printf '%s\n' "$KERNEL_FIXTURE" >"$out/cmdline-safe"
    {
        echo "image: $IMAGE"
        sudo podman image inspect --format 'id {{.Id}}' "$IMAGE"
        sudo podman image inspect --format 'digest {{.Digest}}' "$IMAGE"
        echo "checkout: HEAD $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)," \
            "working tree $(working_tree_object 2>/dev/null || echo unknown)," \
            "$(git -C "$REPO" status --porcelain 2>/dev/null | wc -l) path(s) differ from HEAD"
        echo "started: $(date -u +%FT%TZ)"
    } >"$out/image.txt"

    log "${out##*/}: G1's desktop checks on the tested image"
    rc=0
    # shellcheck disable=SC2024 # builder owns the results
    sudo podman run --rm --net=none -v "$IMAGE_DIR:/run/apex-image:ro,z" --entrypoint /bin/sh "$IMAGE" \
        -c 'ROOT=/ APEX_IMAGE_DIR=/run/apex-image sh /run/apex-image/checks/desktop.sh' \
        >"$out/g1-desktop.txt" 2>&1 || rc=$?
    echo "$rc" >"$out/g1-desktop.rc"

    log "${out##*/}: the direct cases"
    sudo podman run --rm --name "$name-direct" "$NO_SELINUX_LABELS" -v "$HERE:/w:ro,z" -v "$out:/out:z" \
        --env G2_GLASS_STRESS_SECONDS="${G2_GLASS_STRESS_SECONDS:-$VM_GLASS_STRESS_SECONDS}" \
        --entrypoint /bin/bash "$BUS_IMAGE" /w/direct.sh main 2>&1 | tee "$out/direct-main.txt" ||
        direct_failed main "$out" $?

    log "${out##*/}: apex.safe=1 on the kernel command line (a fixture bound over /proc/cmdline)"
    sudo podman run --rm --name "$name-kernel" "$NO_SELINUX_LABELS" -v "$HERE:/w:ro,z" -v "$out:/out:z" \
        -v "$out/cmdline-safe:/proc/cmdline:ro,z" \
        --entrypoint /bin/bash "$BUS_IMAGE" /w/direct.sh kernel 2>&1 | tee "$out/direct-kernel.txt" ||
        direct_failed kernel "$out" $?

    log "${out##*/}: Fedora's own gnome-shell build, the baseline of the captures"
    sudo podman run --rm --name "$name-fedora" "$NO_SELINUX_LABELS" -v "$HERE:/w:ro,z" -v "$out:/out:z" \
        --entrypoint /bin/bash "$FEDORA_BUS_IMAGE" /w/direct.sh fedora 2>&1 | tee "$out/direct-fedora.txt" ||
        direct_failed fedora "$out" $?

    log "${out##*/}: the crash guard (the image's systemd and a user's systemd --user)"
    sudo podman rm -f "$name-guard" >/dev/null 2>&1 || true
    guard_containers+=("$name-guard")
    sudo podman run -d --name "$name-guard" "$NO_SELINUX_LABELS" --net=none -v "$HERE:/w:ro,z" -v "$out:/out:z" \
        "$IMAGE" /sbin/init --unit=multi-user.target >/dev/null
    sleep 3
    rc=0
    # shellcheck disable=SC2024 # builder owns the results
    sudo timeout "$GUARD_TIMEOUT" podman exec "$name-guard" /w/guard.sh >"$out/guard.log" 2>&1 || rc=$?
    echo "guard.sh: exit $rc"
    sudo podman rm -f "$name-guard" >/dev/null

    sudo chown -R "$(id -u):$(id -g)" "$out"
    echo "finished: $(date -u +%FT%TZ)" >>"$out/image.txt"
}

t0=$SECONDS
trap remove_leftovers EXIT
prune_old_runs
prepare_bus_image
prepare_fedora_image
for i in $(seq 1 "$RUNS"); do
    one_run "$root/run-$i"
done

# The image's /home links to var/home, which only a boot creates.
G2_GJS="sudo podman run --rm --net=none --user $(id -u):$(id -g) --tmpfs /var/home -v $HERE:$HERE:ro,z -v $root:$root:z --entrypoint gjs $IMAGE"
export G2_GJS

status=0
for i in $(seq 1 "$RUNS"); do
    log "run-$i: assertions"
    "$HERE/assert.sh" "$root/run-$i" | tee "$root/run-$i/assert.txt" || status=1
done
for i in $(seq 2 "$RUNS"); do
    log "run-$i against run-1: stability"
    "$HERE/stable.sh" "$root/run-1" "$root/run-$i" | tee "$root/run-$i/stable.txt" || status=1
done

{
    sudo podman image inspect --format 'image-id {{.Id}}' "$IMAGE"
    echo "runs $RUNS"
    echo "lock-sha256 $(sudo podman run --rm --net=none --entrypoint sha256sum "$IMAGE" /usr/share/apex/rpms.lock | cut -d' ' -f1)"
    echo "status $( ((status == 0)) && echo passed || echo failed )"
} >"$root/result.txt"

echo
grep -h '^# [0-9]* passed' "$root"/run-*/assert.txt "$root"/run-*/stable.txt 2>/dev/null | sed 's/^/  /' || true
grep -h '^# gap ' "$root/run-1/assert.txt" 2>/dev/null | sed 's/^# gap /  known gap until /' || true
echo "G2 $( ((status == 0)) && echo passed || echo FAILED ) after $((SECONDS - t0)) s: $root (also $OUT_DIR/latest)"
exit "$status"
