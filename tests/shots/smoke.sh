#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/smoke.sh

G2's harness on Fedora's own gnome-shell, as root in a throwaway Fedora container (CI's
shots-smoke job): direct.sh's fedora part with clock.c, fixtures.py and probe.js, then the
assertions that need no Apex build. A harness change that keeps the shell from starting or
reporting fails here in minutes, before a builder VM spends a G2 run on it.

It needs gnome-shell, mesa-dri-drivers, dbus-daemon, python3-dbusmock, gcc, glib2-devel, gjs
and jq.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
esac
[[ -e /run/.containerenv || -e /.dockerenv ]] || { echo "smoke.sh: only inside a throwaway container" >&2; exit 2; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
out=$(mktemp -d)
mkdir -p "$out/captures"
# direct.sh reads the harness at /w and writes its results to /out, as run.sh mounts them.
ln -sfn "$HERE" /w
ln -sfn "$out" /out

# The Apex image's vendor override (apex-desktop) shows the weekday, which fixed_clock expects.
printf '[org.gnome.desktop.interface]\nclock-show-weekday=true\n' >/usr/share/glib-2.0/schemas/90_g2-smoke.gschema.override
glib-compile-schemas /usr/share/glib-2.0/schemas

start=$SECONDS
bash /w/direct.sh fedora
rc=$?
echo "# direct.sh fedora: exit $rc after $((SECONDS - start)) s"

# shellcheck source=tests/shots/assert.sh
. "$HERE/assert.sh"
for variant in light dark; do
    c=fedora-$variant
    exits "$out" "$c" 0
    no_js_error "$c" "$out/$c.log"
    fixed_clock "$c" "$out/$c.log"
    scenes_captured "$out" "$c"
    overview_below_bar "$c" "$out/$c.log"
done
no_js_error fedora-glass "$out/fedora-glass.log"
fedora_glass "$out"
fixtures_on_the_bus "$out" fedora
if ! summary; then
    for log in "$out"/fedora-*.log; do
        echo "## the last lines of $log"
        tail -n 25 "$log"
    done
    exit 1
fi
