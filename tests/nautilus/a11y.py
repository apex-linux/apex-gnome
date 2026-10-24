#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: a11y.py OUT.json [PRESS...]

Writes the accessible tree of the running Files window as JSON, one object per node:
{"role": ..., "name": ..., "depth": ..., "states": [...]}, in document order, with the
states that tell a toggle's or a pane's state (STATES). With PRESS, it first performs the
default action of each node named PRESS, in order, waiting for the window to settle after
each. Needs the session's
accessibility bus (at-spi2-core) and the Atspi typelib.
"""

import json
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

APP_NAMES = ("nautilus", "org.gnome.Nautilus", "Files")
MAX_DEPTH = 60
SETTLE_S = 3
STATES = {
    Atspi.StateType.CHECKED: "checked",
    Atspi.StateType.PRESSED: "pressed",
    Atspi.StateType.SELECTED: "selected",
    Atspi.StateType.SHOWING: "showing",
}


def walk(node, depth, out):
    if node is None or depth > MAX_DEPTH:
        return
    try:
        state_set = node.get_state_set()
        states = [name for state, name in STATES.items() if state_set.contains(state)]
        out.append({"role": node.get_role_name(), "name": node.get_name() or "", "depth": depth, "states": states})
        for i in range(node.get_child_count()):
            walk(node.get_child_at_index(i), depth + 1, out)
    except gi.repository.GLib.Error:
        return


def files_tree():
    desktop = Atspi.get_desktop(0)
    nodes = []
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is not None and (app.get_name() or "") in APP_NAMES:
            walk(app, 0, nodes)
    return nodes


def press(node, name):
    if node is None:
        return False
    if (node.get_name() or "") == name and node.get_action_iface() is not None:
        return node.do_action(0)
    return any(press(node.get_child_at_index(i), name) for i in range(node.get_child_count()))


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    desktop = Atspi.get_desktop(0)
    apps = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
    for name in sys.argv[2:]:
        if not any(press(app, name) for app in apps if app and (app.get_name() or "") in APP_NAMES):
            print(f"a11y.py: nothing named {name!r} to press", file=sys.stderr)
            return 1
        time.sleep(SETTLE_S)
    nodes = files_tree()
    with open(sys.argv[1], "w") as f:
        json.dump(nodes, f, ensure_ascii=False, indent=1)
    print(f"a11y.py: {len(nodes)} nodes")
    return 0 if nodes else 1


if __name__ == "__main__":
    sys.exit(main())
