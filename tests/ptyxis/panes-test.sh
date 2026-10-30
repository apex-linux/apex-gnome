#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/headless.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/headless.sh"

PTYXIS_TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly PTYXIS_TESTS

readonly SHELL_TIMEOUT=240
# apex.css: an unfocused pane's header at .7, its body at .62.
readonly HEADER_ALPHA=0.7 BODY_ALPHA=0.62 ALPHA_SLACK=0.02

usage() {
    cat <<EOF
usage: tests/ptyxis/panes-test.sh [RPM_DIR]

Board 33's panes in a real Ptyxis, in a headless gnome-shell at scale 2, as root in a
throwaway fedora:$APEX_FEDORA container (just ptyxis-panes). RPM_DIR holds the lane's built
RPMs (_build/ptyxis/out); without it the installed ptyxis is tested. A user '$USER_NAME'
splits a session right and down from the header's toggles (over AT-SPI) and from
Ctrl+Alt+R and Ctrl+Alt+D; focuses each pane by a click, the other dimmed ($HEADER_ALPHA
header, $BODY_ALPHA body); runs board 32's programs (fixture.c, sessions.sh) in the two
panes, whose statuses come from bash's shell integration, and checks each pane's own:
the running command, OSC 9;4 progress, exit status and the bell's needs-you, which focus
clears. The footer's counts show the session at the stronger of its two panes. Close
Pane, on the second pane's header, ends the split. It needs gnome-shell, mesa-dri-drivers,
dbus-daemon, python3-dbusmock, python3-gobject, at-spi2-core, gcc, util-linux, jq and the
Apex fonts; the log and result land in _build/ptyxis/panes/.
EOF
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
esac
headless_require_container panes-test.sh

out=$APEX_ROOT/_build/ptyxis/panes
rm -rf -- "$out"
mkdir -p -- "$out"
chmod 777 "$out"
[[ -z ${1:-} ]] || headless_install_rpm "$1" ptyxis
rpm -q ptyxis >"$out/ptyxis.txt"

# CI runs the palette test before this one in the same container, and its palette and settings would stay.
if id "$USER_NAME" >/dev/null 2>&1; then
    pkill -u "$USER_NAME" 2>/dev/null
    userdel -r "$USER_NAME" 2>/dev/null
    ! id "$USER_NAME" >/dev/null 2>&1 || die "panes-test.sh: cannot remove the earlier test's user $USER_NAME"
fi
headless_user
home=$HEADLESS_HOME
fixtures=$home/.apex-fixtures
install -d -o "$USER_NAME" "$home/bin" "$fixtures"
gcc -O2 -Wall -Werror -o "$home/bin/fixture" "$PTYXIS_TESTS/fixture.c" || die "cannot build fixture.c"
for program in claude just cargo rpmbuild; do
    cp "$home/bin/fixture" "$home/bin/$program"
done
"$PTYXIS_TESTS/sessions.sh" "$fixtures"
cat >>"$home/.bashrc" <<'EOF'
export PATH=$HOME/bin:$PATH APEX_FIXTURES=$HOME/.apex-fixtures
PS1='\[\e[34m\]\w\[\e[2m\] $ \[\e[0m\]'
__apex_postexec() { printf '\e]666;vte.shell.postexec=%s\e\\' "$?"; }
__vte_precmd() { __vte_termprop_signal vte.shell.precmd; }
PROMPT_COMMAND=(__apex_postexec "${PROMPT_COMMAND[@]}")
EOF
chown -R "$USER_NAME:" "$home"

# The probe asks this helper, a separate process, so no AT-SPI call ever waits on the shell itself.
atspi=$out/panes-atspi.py
cat >"$atspi" <<'EOF'
import json
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib  # noqa: E402

R = Atspi.Role
S = Atspi.StateType


def walk(node):
    yield node
    for i in range(node.get_child_count()):
        child = node.get_child_at_index(i)
        if child is not None:
            yield from walk(child)


def kids(node):
    return [c for c in (node.get_child_at_index(i) for i in range(node.get_child_count())) if c is not None]


def showing(node):
    return node.get_state_set().contains(S.SHOWING)


def box(node):
    e = node.get_extents(Atspi.CoordType.WINDOW)
    return [e.x, e.y, e.width, e.height]


def app():
    end = time.monotonic() + 30
    while time.monotonic() < end:
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            a = desktop.get_child_at_index(i)
            if a is not None and a.get_name() == "ptyxis":
                return a
        time.sleep(0.2)
    sys.exit("panes-atspi: Ptyxis is not on the accessibility bus")


def prompted(terminal):
    """The shell has drawn its first prompt: PROMPT_COMMAND has set the title, user@host:dir."""
    return ":" in (terminal.get_description() or "")


def pane(terminal):
    """The terminal's pane: its header (a title, a path and a tag) above it, when split."""
    node = terminal.get_parent()
    while node is not None and node.get_role() != R.FRAME:
        parts = kids(node)
        if parts and sum(k.get_role() == R.LABEL for k in kids(parts[0])) == 3 and \
                abs(box(parts[0])[0] - box(terminal)[0]) <= 1:
            header = parts[0]
            labels = [k for k in kids(header) if k.get_role() == R.LABEL]
            return {
                "title": labels[0].get_name(), "path": labels[1].get_name(), "tag": labels[2].get_name(),
                "header": box(header), "body": box(terminal),
                "needsYou": any(k.get_role() == R.IMAGE and showing(k) for k in kids(header)),
                "close": any(k.get_name() == "Close Pane" and showing(k) for k in kids(header)),
                "focused": terminal.get_state_set().contains(S.FOCUSED), "prompted": prompted(terminal),
            }
        node = node.get_parent()
    return None


def state(root):
    nodes = list(walk(root))
    terminals = [n for n in nodes if n.get_role() == R.TERMINAL and showing(n)]
    panes = [p for p in (pane(t) for t in terminals) if p is not None]
    toggles = {n.get_name(): n.get_state_set().contains(S.PRESSED) for n in nodes
               if n.get_role() == R.TOGGLE_BUTTON and n.get_name() in ("Split Right", "Split Down")}
    row = next(n for n in nodes if n.get_role() == R.LIST_ITEM and n.get_state_set().contains(S.SELECTED))
    row_labels = [n.get_name() for n in walk(row) if n.get_role() == R.LABEL]
    bar = next((n for n in walk(row) if n.get_role() == R.PROGRESS_BAR), None)
    counts = [n for n in nodes if [k.get_role() for k in kids(n)] == [R.IMAGE, R.LABEL]
              and kids(n)[1].get_name().isdigit()]
    counts.sort(key=lambda n: box(n)[0])
    footer = dict(zip(("needsYou", "running", "failed", "done"),
                      (int(kids(n)[1].get_name()) for n in counts)))
    progress = bar.get_value_iface().get_current_value() if bar is not None and showing(bar) else None
    return {
        "terminals": len(terminals), "prompted": [prompted(t) for t in terminals],
        "panes": sorted(panes, key=lambda p: (p["body"][0], p["body"][1])),
        "toggles": toggles,
        "row": dict(zip(("title", "subtitle", "when"), row_labels), progress=progress),
        "footer": footer,
    }


def click(root, name, index):
    buttons = [n for n in walk(root) if n.get_name() == name and showing(n)
               and n.get_role() in (R.PUSH_BUTTON, R.TOGGLE_BUTTON)]
    buttons.sort(key=lambda n: box(n)[0])
    buttons[index].get_action_iface().do_action(0)


def settled_state(root):
    """The tree, read again while a split or close is still changing it under the walk."""
    for _ in range(20):
        try:
            return state(root)
        except (GLib.Error, StopIteration, IndexError):
            time.sleep(0.1)
    return state(root)


Atspi.init()
root = app()
if sys.argv[1] == "click":
    click(root, sys.argv[2], int(sys.argv[3]))
    print("{}", flush=True)
else:
    print(json.dumps(settled_state(root)), flush=True)
EOF
chmod 644 "$atspi"
headless_bus "$out"

# The virtual pointer starts in the top-left corner, where a hot corner would open the overview.
headless_run "$out/panes.log" "$PTYXIS_TESTS/panes-probe.js" "$SHELL_TIMEOUT" \
    "org.gnome.desktop.interface enable-hot-corners false" \
    APEX_PANES_ATSPI="$atspi" APEX_PANES_OUT="$out"
log "panes-test.sh: shell exit $?"

result=$(sed -n 's/.*APEXPANES //p' "$out/panes.log" | tail -n 1)
[[ -n $result ]] || die "panes-test.sh: no result; see ${out#"$APEX_ROOT/"}/panes.log"
printf '%s\n' "$result" >"$out/panes.json"
jq -e '.error == null' <<<"$result" >/dev/null ||
    die "panes-test.sh: the probe failed: $(jq -r .error <<<"$result")"

failures=0
# check WHAT JQ: one fact about the run, against panes.json.
check() {
    if jq -e --argjson h "$HEADER_ALPHA" --argjson b "$BODY_ALPHA" --argjson slack "$ALPHA_SLACK" \
        "def near(x; y): (x - y) | fabs <= \$slack; $2" "$out/panes.json" >/dev/null; then
        log "ok - $1"
    else
        failures=$((failures + 1))
        log "FAIL - $1"
    fi
}
check "one terminal at start, no pane header, neither toggle pressed" \
    '.start | .terminals == 1 and (.panes | length == 0)
     and .toggles == {"Split Right": false, "Split Down": false}'
check "true, which ends within one VTE batch, leaves the session done" \
    '.fast | .row.subtitle == "done" and .footer == {"needsYou": 0, "running": 0, "failed": 0, "done": 1}'
check "Split Right (the header toggle): two panes side by side, the toggle pressed, the new pane focused" \
    '.toggleRight | (.panes | length == 2 and .[1].body[0] > .[0].body[0] and .[1].body[1] == .[0].body[1]
     and .[1].focused) and .toggles == {"Split Right": true, "Split Down": false}'
check "Split Right again: back to one pane" '.toggleRightOff | .terminals == 1 and (.panes | length == 0)'
check "Split Down (the header toggle): two panes one above the other, the toggle pressed" \
    '.toggleDown | (.panes | length == 2 and .[1].body[1] > .[0].body[1] and .[1].body[0] == .[0].body[0])
     and .toggles == {"Split Right": false, "Split Down": true}'
check "Split Down again: back to one pane" '.toggleDownOff | .terminals == 1 and (.panes | length == 0)'
check "Ctrl+Alt+R: split right" \
    '.keyRight | (.panes | length == 2 and .[1].body[0] > .[0].body[0]) and .toggles["Split Right"]'
check "then Ctrl+Alt+D: the same two panes, now one above the other" \
    '.keyDown | (.panes | length == 2 and .[1].body[1] > .[0].body[1]) and .toggles["Split Down"]'
check "Ctrl+Alt+D again: back to one pane" '.keyDownOff | .terminals == 1 and (.panes | length == 0)'
check "only the second pane's header has Close Pane" '.keyRight.panes | (.[0].close | not) and .[1].close'
check "a click focuses the first pane" '.clickFirst.panes | .[0].focused and (.[1].focused | not)'
check "and the second, unfocused, is dimmed: header at .7, body at .62" \
    ".dim.second | near(.header; \$h) and near(.body; \$b)"
check "a click focuses the second pane back" '.clickSecond.panes | .[1].focused and (.[0].focused | not)'
check "and the first, unfocused, is dimmed the same" ".dim.first | near(.header; \$h) and near(.body; \$b)"
check "the second pane runs cargo: its header names it, the first still says Shell" \
    '.cargoRunning.panes | .[0].title == "Shell" and .[1].title == "cargo test --workspace"'
check "cargo exits 0 in the second pane: the session is done" \
    '.cargoDone | .panes[1].title == "Shell"
     and .footer == {"needsYou": 0, "running": 0, "failed": 0, "done": 1}'
check "rpmbuild exits 1 in the first pane: its exit status in the row, the session failed over done" \
    '.rpmbuildFailed | .row.subtitle == "rpmbuild -bb packaging/apex-desktop.spec · exit 1"
     and .footer == {"needsYou": 0, "running": 0, "failed": 1, "done": 0}'
check "just runs in the first pane: its header names it, the row its OSC 9;4 progress (73 %), running" \
    '.justRunning | .panes[0].title == "just vm-image" and .panes[1].title == "Shell"
     and near(.row.progress; 0.73)
     and .footer == {"needsYou": 0, "running": 1, "failed": 0, "done": 0}'
check "the second pane's own progress (20 %) leaves the row's, the first pane's, at 73 %" \
    '.secondProgress | near(.row.progress; 0.73)'
check "claude rings the bell in the unfocused second pane: its header says needs-you, as the session" \
    '.bell | (.panes[1].needsYou and (.panes[0].needsYou | not))
     and .footer == {"needsYou": 1, "running": 0, "failed": 0, "done": 0}'
check "focusing the second pane clears its needs-you: both panes running again" \
    '.bellCleared | (.panes | map(.needsYou) == [false, false])
     and .footer == {"needsYou": 0, "running": 1, "failed": 0, "done": 0}'
check "Close Pane on the second pane's header: one pane, no toggle pressed, the first's just still running" \
    '.closed | .terminals == 1 and (.panes | length == 0) and .row.subtitle == "just vm-image · running"
     and .toggles == {"Split Right": false, "Split Down": false} and .footer.running == 1'
check "the focus key moves the focus to the first pane, and the second dims" \
    '.focusOther.panes | .[0].focused and (.[1].focused | not)'
check "and again back to the second" '.focusBack.panes | .[1].focused and (.[0].focused | not)'
check "the close key on the focused second pane closes it: one pane, the first's just still running" \
    '.closeKeySecond | .terminals == 1 and (.panes | length == 0)
     and .row.subtitle == "just vm-image · running"'
check "the close key on the focused first pane closes it: the second takes its tab, its row goes" \
    '.closeKeyFirst | .terminals == 1 and (.panes | length == 0)
     and .toggles == {"Split Right": false, "Split Down": false}
     and .footer == {"needsYou": 0, "running": 0, "failed": 0, "done": 0}'
((failures == 0)) || die "panes-test.sh: $failures check(s) failed; see ${out#"$APEX_ROOT/"}/panes.json"
log "panes-test.sh: the panes split, focus, keep their own statuses and close"
