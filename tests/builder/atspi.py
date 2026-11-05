#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Apex Code's names over AT-SPI: the editor's text, and every button and toggle button, as E0 listed them.
import json

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi  # noqa: E402

ROLES = {Atspi.Role.BUTTON, Atspi.Role.TOGGLE_BUTTON, Atspi.Role.TEXT}


def walk(node, out, depth=0):
    try:
        role, name = node.get_role(), node.get_name() or ''
        showing = node.get_state_set().contains(Atspi.StateType.SHOWING)
    except gi.repository.GLib.Error:
        return
    if depth > 1 and not showing:
        return
    if role in ROLES:
        out.append({'role': Atspi.role_get_name(role), 'name': name})
    for i in range(node.get_child_count()):
        child = node.get_child_at_index(i)
        if child is not None and depth < 60:
            walk(child, out, depth + 1)


desktop = Atspi.get_desktop(0)
apps = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
app = next((a for a in apps if a is not None and (a.get_name() or '') == 'gnome-builder'), None)
nodes = []
if app is not None:
    walk(app, nodes)
print(json.dumps({'found': app is not None, 'nodes': nodes}))
