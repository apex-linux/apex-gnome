#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Press Apex Code's showing button, toggle button or tab named argv[1] (a trailing * matches a prefix) over AT-SPI;
# with --names, list every showing name.
import json
import sys

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi  # noqa: E402

PRESSABLE = {Atspi.Role.BUTTON, Atspi.Role.TOGGLE_BUTTON, Atspi.Role.PAGE_TAB}


def nodes(node, depth=0):
    try:
        showing = node.get_state_set().contains(Atspi.StateType.SHOWING)
        if depth > 1 and not showing:
            return
        yield node
        for i in range(node.get_child_count()):
            child = node.get_child_at_index(i)
            if child is not None and depth < 60:
                yield from nodes(child, depth + 1)
    except gi.repository.GLib.Error:
        return


def pressable(node, name):
    try:
        action = node.get_action_iface()
        given = node.get_name() or ''
        matches = given.startswith(name[:-1]) if name.endswith('*') else given == name
        return (node.get_role() in PRESSABLE and matches
                and action is not None and action.get_n_actions() > 0)
    except gi.repository.GLib.Error:
        return False


desktop = Atspi.get_desktop(0)
apps = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
app = next((a for a in apps if a is not None and (a.get_name() or '') == 'gnome-builder'), None)
if app is None:
    print(json.dumps({'pressed': False, 'names': []}))
elif sys.argv[1] == '--names':
    print(json.dumps({'names': [n.get_name() for n in nodes(app) if n.get_name()]}))
else:
    button = next((n for n in nodes(app) if pressable(n, sys.argv[1])), None)
    print(json.dumps({'pressed': button is not None and button.get_action_iface().do_action(0)}))
