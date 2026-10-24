#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: a11y.py OUT.json

Writes the accessible tree of the running Files window as JSON, one object per node:
{"role": ..., "name": ..., "depth": ...}, in document order. Needs the session's
accessibility bus (at-spi2-core) and the Atspi typelib.
"""

import json
import sys

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

APP_NAMES = ("nautilus", "org.gnome.Nautilus", "Files")
MAX_DEPTH = 60


def walk(node, depth, out):
    if node is None or depth > MAX_DEPTH:
        return
    try:
        out.append({"role": node.get_role_name(), "name": node.get_name() or "", "depth": depth})
        for i in range(node.get_child_count()):
            walk(node.get_child_at_index(i), depth + 1, out)
    except gi.repository.GLib.Error:
        return


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    desktop = Atspi.get_desktop(0)
    nodes = []
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is not None and (app.get_name() or "") in APP_NAMES:
            walk(app, 0, nodes)
    with open(sys.argv[1], "w") as f:
        json.dump(nodes, f, ensure_ascii=False, indent=1)
    print(f"a11y.py: {len(nodes)} nodes")
    return 0 if nodes else 1


if __name__ == "__main__":
    sys.exit(main())
