#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat <<'EOF'
usage: lanes.sh

direct.sh's main part in lanes, inside the same container direct.sh main would run in: first
glass-stress (G2_LANE=stress) beside the cases that read no elapsed time and count no frames
(quiet), each with llvmpipe on half the cores; then, alone and on every core, the cases that do
(timed). parts.sh's STRESS_CASES, QUIET_CASES and TIMED_CASES name them. Each lane is a direct.sh
with G2_LANE set: a system bus and fixtures of its own, and its own /out files, joined afterwards
under main's names (results-main.txt, late-main.txt, cmdline-main.txt) so assert.sh reads one main
part; fixtures-main-LANE.txt stay apart. Exits 3 when a case hung, as direct.sh does, and then
before the timed lane when the hung case was in the first two.
run.sh runs it for the VM's main part, and patched.sh with PATCHED_LANES=1.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
(($# == 0)) || { usage >&2; exit 2; }
[[ -e /run/.containerenv || -e /.dockerenv ]] || { echo "lanes.sh: only inside run.sh's or patched.sh's container" >&2; exit 2; }

readonly LANES=(quiet stress timed)
readonly EXIT_HUNG=3
threads=$(($(nproc) / 2))
((threads > 0)) || threads=1
readonly threads

lane() {
    local name=$1
    shift
    env G2_LANE="$name" "$@" bash /w/direct.sh main
}

join_lanes() {
    local file name
    for file in results late; do
        for name in "${LANES[@]}"; do
            cat "/out/$file-main-$name.txt" 2>/dev/null
        done >"/out/$file-main.txt"
    done
    cp "/out/cmdline-main-timed.txt" "/out/cmdline-main.txt" 2>/dev/null ||
        cp "/out/cmdline-main-quiet.txt" "/out/cmdline-main.txt"
}

lane stress LP_NUM_THREADS="$threads" &
stress=$!
lane quiet LP_NUM_THREADS="$threads"
quiet_rc=$?
wait "$stress"
stress_rc=$?
echo "lanes.sh: the stress lane exited $stress_rc, the quiet lane $quiet_rc"
if ((stress_rc == EXIT_HUNG || quiet_rc == EXIT_HUNG)); then
    join_lanes
    exit "$EXIT_HUNG"
fi
lane timed
timed_rc=$?
echo "lanes.sh: the timed lane exited $timed_rc"
join_lanes
for rc in "$timed_rc" "$stress_rc" "$quiet_rc"; do
    ((rc == 0)) || exit "$rc"
done
