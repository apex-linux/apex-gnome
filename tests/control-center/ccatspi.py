# SPDX-License-Identifier: GPL-3.0-or-later
"""AT-SPI helpers shared by bindings.py, updates.py and appearance.py."""

import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib  # noqa: E402

TIMEOUT_S = 5
failures = []


def spin(seconds=0.05):
    end = time.monotonic() + seconds
    ctx = GLib.MainContext.default()
    while time.monotonic() < end:
        while ctx.pending():
            ctx.iteration(False)
        time.sleep(0.01)


def wait_for(what, check):
    end = time.monotonic() + TIMEOUT_S
    while time.monotonic() < end:
        if check():
            return True
        spin()
    failures.append(what)
    print(f"FAIL {what}", flush=True)
    return False


def walk(node):
    yield node
    for i in range(node.get_child_count()):
        child = node.get_child_at_index(i)
        if child is not None:
            yield from walk(child)


def find_app():
    end = time.monotonic() + 60
    while time.monotonic() < end:
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(i)
            if app is not None and app.get_name() in ("Settings", "gnome-control-center"):
                return app
        time.sleep(0.5)
    sys.exit(f"{sys.argv[0]}: Settings is not on the accessibility bus")


def find(root, name, roles):
    for node in walk(root):
        if node.get_name() == name and node.get_role() in roles:
            return node
    return None


def checked(node):
    return node.get_state_set().contains(Atspi.StateType.CHECKED)


def activate(node):
    """Runs the action of NODE, or of the switch inside it: AdwSwitchRow itself has none."""
    for n in walk(node):
        action = n.get_action_iface() if n.get_role() == node.get_role() else None
        if action is not None and action.get_n_actions() > 0:
            action.do_action(0)
            return
    sys.exit(f"{sys.argv[0]}: {node.get_name()} has no action")


def radios(group):
    kids = (group.get_child_at_index(i) for i in range(group.get_child_count()))
    return {k.get_name(): k for k in kids if k is not None and k.get_role() == Atspi.Role.RADIO_BUTTON}




def finish():
    print(f"APEXCC-CHECK {'ok' if not failures else 'FAIL ' + str(len(failures))}", flush=True)
    sys.exit(1 if failures else 0)
