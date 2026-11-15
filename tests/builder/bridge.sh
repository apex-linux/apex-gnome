#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The toolbox bridge's own checks (E2): its socket, its start, and its process groups, with a fake podman.

set -euo pipefail

usage() {
    cat <<USAGE
usage: tests/builder/bridge.sh [LIBEXECDIR]

Runs the installed apex-toolbox-exec and apex-toolbox-bridge (LIBEXECDIR, /usr/libexec by
default) as root, with a fake podman first on PATH: its bridge start runs the real bridge
without /run/host, and its plain podman exec, the client's fallback, prints "fallback".
- a request runs, with its environment, working directory and exit status, and a second
  client reuses the one bridge;
- a socket in a directory others can enter, or owned by another user, is never used;
- a bridge that cannot start costs one start, then none for ten minutes;
- 160 clients killed and 280 sent SIGTERM within 2 ms of their spawn leave nothing running.
USAGE
}

case ${1:-} in -h | --help) usage; exit 0 ;; esac
((EUID == 0)) || { echo "bridge.sh: runs as root" >&2; exit 2; }
readonly LIBEXEC=${1:-/usr/libexec}
readonly EXEC=$LIBEXEC/apex-toolbox-exec
readonly ID=0123456789abcdef0123456789abcdef
readonly NOBODY=65534

fails=0
ok() { printf 'ok: %s\n' "$*"; }
not_ok() { printf 'not ok: %s\n' "$*"; fails=$((fails + 1)); }

work=$(mktemp -d)
# The second user's case reaches the fake podman and its log; each case's runtime directory keeps its own mode.
chmod 755 "$work"
listener=
cleanup() {
    [[ -n $listener ]] && kill "$listener" 2>/dev/null
    pkill -f "apex-toolbox-bridge --daemonize $work" 2>/dev/null || true
    pkill -x -f 'sleep 4242' 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

# The fake podman: "exec ... BRIDGE --daemonize /run/host/SOCKET" starts the bridge, unless
# FAKE_START=fail; any other exec is the client's fallback.
mkdir -p "$work/bin"
cat >"$work/bin/podman" <<FAKE
#!/bin/bash
printf '%s\n' "\$*" >>"\${FAKE_LOG:?}"
for ((i = 1; i <= \$#; i++)); do
    if [[ \${!i} == --daemonize ]]; then
        [[ \${FAKE_START:-} == fail ]] && exit 127
        [[ \${FAKE_START:-} == stopped ]] && exit 125
        next=\$((i + 1))
        exec "$LIBEXEC/apex-toolbox-bridge" --daemonize "\${!next#/run/host}"
    fi
done
echo fallback
FAKE
chmod 755 "$work/bin/podman"
export PATH=$work/bin:$PATH

# fresh_dir NAME [OWNER [MODE]]: a runtime directory for one case.
fresh_dir() {
    local dir=$work/$1
    mkdir -p "$dir"
    chown "${2:-0}" "$dir"
    chmod "${3:-700}" "$dir"
    printf '%s\n' "$dir"
}
client() { "$EXEC" --container "$ID" --user root --cwd "${CWD:-/}" --fds 3 "$@"; }
starts() { grep -c -- --daemonize "$FAKE_LOG" || true; }

# A request, and the bridge it starts.
export XDG_RUNTIME_DIR FAKE_LOG
XDG_RUNTIME_DIR=$(fresh_dir run) FAKE_LOG=$work/run.log
# shellcheck disable=SC2016 # the inner shell expands it, in the toolbox
out=$(CWD=/tmp client --env APEX_TEST=yes -- sh -c 'echo "$APEX_TEST $(pwd)"; exit 7') && rc=0 || rc=$?
if [[ $out == "yes /tmp" && $rc == 7 ]]; then
    ok "a request runs with its environment, directory and status"
else
    not_ok "a request gave '$out', exit $rc"
fi
out=$(client -- true) && rc=0 || rc=$?
if [[ $rc == 0 && $(starts) == 1 && -z $out ]]; then
    ok "a second client reuses the bridge"
else
    not_ok "a second client: exit $rc, '$out', $(starts) starts"
fi

# Never a socket where another user could have bound it.
listen() {
    python3 -I -c '
import os, socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); os.chmod(sys.argv[1], 0o777); s.listen(8)
while True:
    c, _ = s.accept(); data = c.recv(65536); c.close()
    open(sys.argv[2], "a").write(f"{len(data)}\n")
' "$1" "$2" &
    listener=$!
    for _ in $(seq 50); do [[ -S $1 ]] && return; sleep 0.1; done
}
shared=$(fresh_dir shared 0 755)
listen "$shared/apex-toolbox-${ID:0:12}.sock" "$work/shared.got"
out=$(XDG_RUNTIME_DIR=$shared FAKE_LOG=$work/shared.log client -- true)
if [[ $out == fallback && ! -s $work/shared.got ]]; then
    ok "a runtime directory others can enter is never used"
else
    not_ok "a mode 755 runtime directory: '$out', the listener got '$(cat "$work/shared.got" 2>/dev/null)'"
fi
kill "$listener"
listener=

theirs=$(fresh_dir theirs "$NOBODY")
listen "$theirs/apex-toolbox-${ID:0:12}.sock" "$work/theirs.got"
touch "$work/theirs.log" && chmod 666 "$work/theirs.log"
out=$(XDG_RUNTIME_DIR=$theirs FAKE_LOG=$work/theirs.log FAKE_START=fail python3 -I -c '
import os, sys
os.setgroups([]); os.setgid(int(sys.argv[1])); os.setuid(int(sys.argv[1])); os.execv(sys.argv[2], sys.argv[2:])
' "$NOBODY" "$EXEC" --container "$ID" --user nobody --cwd / --fds 3 -- true)
got=$(cat "$work/theirs.got" 2>/dev/null || true)
if [[ $out == fallback && ( -z $got || $got == 0 ) ]]; then
    ok "a socket another user listens on gets nothing"
else
    not_ok "another user's socket: '$out', the listener got '$got' bytes"
fi
kill "$listener"
listener=

# A bridge that cannot start: one try, then straight to podman exec.
XDG_RUNTIME_DIR=$(fresh_dir failing) FAKE_LOG=$work/failing.log
out=$(FAKE_START=fail client -- true)
start=$(date +%s%N)
out2=$(FAKE_START=fail client -- true)
ms=$((($(date +%s%N) - start) / 1000000))
if [[ $out == fallback && $out2 == fallback && $(starts) == 1 && $ms -lt 300 ]]; then
    ok "a bridge that cannot start is tried once; the next client falls back in $ms ms"
else
    not_ok "a failing bridge: '$out' '$out2', $(starts) starts, the second client took $ms ms"
fi

# A toolbox not running yet (podman's 125) says nothing about the bridge: no stamp.
XDG_RUNTIME_DIR=$(fresh_dir stopped) FAKE_LOG=$work/stopped.log
out=$(FAKE_START=stopped client -- true)
out2=$(FAKE_START=stopped client -- true)
if [[ $out == fallback && $out2 == fallback && $(starts) == 2 && ! -e $XDG_RUNTIME_DIR/apex-toolbox-${ID:0:12}.sock.failed ]]; then
    ok "a toolbox that is not running yet leaves no stamp; the next client tries the bridge again"
else
    not_ok "a stopped toolbox: '$out' '$out2', $(starts) starts, stamp: $(ls "$XDG_RUNTIME_DIR")"
fi

# Killed or signalled right after the spawn, a client leaves nothing running.
XDG_RUNTIME_DIR=$(fresh_dir stress) FAKE_LOG=$work/stress.log
client -- true
# stress SIGNAL N: "LEFT HUNG", the processes still running and the clients still waiting a
# second after their signal (a lost SIGTERM leaves the client waiting for good).
stress() {
    local signal=$1 n=$2 pid hung=0
    for ((i = 0; i < n; i++)); do
        client -- sleep 4242 &
        pid=$!
        sleep "0.00$((RANDOM % 3))"
        kill "-$signal" "$pid" 2>/dev/null || true
        for _ in $(seq 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$pid" 2>/dev/null; then
            hung=$((hung + 1))
            kill -9 "$pid"
        fi
        wait "$pid" 2>/dev/null || true
    done
    sleep 1
    echo "$({ pgrep -x -f 'sleep 4242' || true; } | wc -l) $hung"
}
read -r left hung < <(stress KILL 160)
if [[ $left == 0 && $hung == 0 ]]; then
    ok "160 clients killed after their spawn leave no process"
else
    not_ok "SIGKILL: $left of 160 left running, $hung clients hung"
fi
read -r left hung < <(stress TERM 280)
if [[ $left == 0 && $hung == 0 ]]; then
    ok "280 clients sent SIGTERM after their spawn end, and leave no process"
else
    not_ok "SIGTERM: $left of 280 left running, $hung clients hung"
fi

((fails == 0)) || { echo "bridge.sh: $fails check(s) failed" >&2; exit 1; }
echo "bridge.sh: every check passed"
