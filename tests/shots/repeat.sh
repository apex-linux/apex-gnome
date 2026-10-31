#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/repeat.sh N
       tests/shots/repeat.sh compare LOG LOG...

G2 run to run: N runs of patched.sh on one build, each in its own throwaway Fedora 45
container, then every assertion whose verdict differs between them. The first run builds
the RPMs (or PATCHED_RPMS=DIR names them) and the rest install that build. compare reads
patched.sh logs and prints, per differing assertion, each run's verdict (P pass, F fail,
G known gap, - absent) and its text; it exits 1 when any assertion differs.

  REPEAT_OUT=DIR          the runs' logs and outputs (default: _build/repeat)
  REPEAT_ENGINE=CMD       the container engine (default: podman, else docker)
  REPEAT_ENGINE_ARGS=...  more arguments for the engine's run, split on spaces
  REPEAT_PRELUDE=CMD      a command the container runs before patched.sh

  tests/shots/repeat.sh 5
EOF
}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
readonly IMAGE=registry.fedoraproject.org/fedora:45

die() {
    echo "repeat.sh: $*" >&2
    exit 2
}

# A failure's detail ("(got …)", "(no report)", "(no line matches …)") is cut, so it shares its pass's row.
compare() {
    (($# >= 2)) || die "compare needs two logs or more"
    local log
    for log in "$@"; do
        [[ -r $log ]] || die "cannot read $log"
    done
    awk -v runs=$# '
        FNR == 1 { run++; delete times }
        /^(PASS|FAIL|GAP ) / {
            verdict = substr($0, 1, 1)
            text = substr($0, 6)
            if (verdict != "P")
                sub(/ \((got |no report\)|no line matches ).*$/, "", text)
            # A pass may close on what this run saw ("(late)", "(on time)"): the verdict is what compares.
            sub(/ \([^()]*\)$/, "", text)
            # An assertion a run makes twice gets a row per time, so a mixed pair cannot hide.
            if (++times[text] > 1)
                text = text " [" times[text] "]"
            if (!(text in seen)) { seen[text] = 1; order[++rows] = text }
            got[text, run] = verdict
        }
        END {
            differ = 0
            for (r = 1; r <= rows; r++) {
                text = order[r]
                line = ""
                same = 1
                for (i = 1; i <= runs; i++) {
                    v = ((text, i) in got) ? got[text, i] : "-"
                    if (i > 1 && v != first) same = 0
                    if (i == 1) first = v
                    line = line v " "
                }
                if (!same) { differ++; print line " " text }
            }
            printf "repeat: %d runs, %d assertions, %d differ\n", runs, rows, differ
            exit differ > 0
        }' "$@"
}

repeat_runs() {
    local n=$1 out=${REPEAT_OUT:-$REPO/_build/repeat} engine rpms=${PATCHED_RPMS:-} i args logs=()
    if [[ ! $n =~ ^[0-9]+$ ]] || ((n < 2)); then
        die "N is a number of runs, 2 or more, not $n"
    fi
    engine=${REPEAT_ENGINE:-$(command -v podman || command -v docker || :)}
    [[ -n $engine ]] || die "no podman or docker, and no REPEAT_ENGINE"
    mkdir -p "$out"
    for ((i = 1; i <= n; i++)); do
        mkdir -p "$out/$i"
        args=(run --rm --privileged --network=host -v "$REPO:/src:ro" -v "$out/$i:/keep" -e PATCHED_OUT=/keep)
        [[ -z $rpms ]] || args+=(-v "$(cd -- "$rpms" && pwd):/rpms:ro" -e PATCHED_RPMS=/rpms)
        # shellcheck disable=SC2086 # the extra arguments split on spaces, as documented
        "$engine" "${args[@]}" ${REPEAT_ENGINE_ARGS:-} "$IMAGE" \
            bash -c "${REPEAT_PRELUDE:-:} && /src/tests/shots/patched.sh" >"$out/$i.log" 2>&1 ||
            echo "repeat.sh: run $i: patched.sh exited $?"
        [[ -n $rpms ]] || rpms=$out/1/rpms
        [[ -d $rpms ]] || die "run 1 left no RPMs in $rpms; see $out/1.log"
        logs+=("$out/$i.log")
    done
    compare "${logs[@]}"
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    compare) shift; compare "$@" ;;
    '') usage >&2; exit 2 ;;
    *) repeat_runs "$1" ;;
esac
