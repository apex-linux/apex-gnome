#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Apex Code's names over AT-SPI: the editor's text, every button and toggle button, as E0 listed them, and E0's other gaps' roles; a page tab also says whether it takes keyboard focus and is selected, a tree item its description, selection and level.
import json

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi  # noqa: E402

ROLES = {Atspi.Role.BUTTON, Atspi.Role.TOGGLE_BUTTON, Atspi.Role.TEXT, Atspi.Role.PAGE_TAB_LIST,
         Atspi.Role.PROGRESS_BAR, Atspi.Role.ENTRY, Atspi.Role.LIST, Atspi.Role.LABEL, Atspi.Role.PAGE_TAB,
         Atspi.Role.RADIO_BUTTON, Atspi.Role.TREE, Atspi.Role.TREE_ITEM}


def walk(node, out, depth=0):
    try:
        role, name = node.get_role(), node.get_name() or ''
        showing = node.get_state_set().contains(Atspi.StateType.SHOWING)
    except gi.repository.GLib.Error:
        return
    if depth > 1 and not showing:
        return
    if role in ROLES:
        node_out = {'role': Atspi.role_get_name(role), 'name': name}
        if role == Atspi.Role.PAGE_TAB:
            states = node.get_state_set()
            node_out['focusable'] = states.contains(Atspi.StateType.FOCUSABLE)
            node_out['selected'] = states.contains(Atspi.StateType.SELECTED)
        if role == Atspi.Role.TREE_ITEM:
            node_out['description'] = node.get_description() or ''
            node_out['selected'] = node.get_state_set().contains(Atspi.StateType.SELECTED)
            node_out['level'] = (node.get_attributes() or {}).get('level')
        out.append(node_out)
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
