# SPDX-License-Identifier: GPL-3.0-or-later
"""Presses one toggle of Settings' Corner Radius row through AT-SPI and prints when, in CLOCK_MONOTONIC."""

import json
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

TOGGLES = {"0", "8", "14", "20"}


def walk(node):
    yield node
    for i in range(node.get_child_count()):
        child = node.get_child_at_index(i)
        if child is not None:
            yield from walk(child)


def find_app():
    end = time.monotonic() + 30
    while time.monotonic() < end:
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(i)
            if app is not None and app.get_name() in ("Settings", "gnome-control-center"):
                return app
        time.sleep(0.5)
    sys.exit("click.py: Settings is not on the accessibility bus")


def radius_toggle(app, label):
    for node in walk(app):
        if node.get_role() != Atspi.Role.RADIO_BUTTON or node.get_name() != label:
            continue
        group = node.get_parent()
        names = {group.get_child_at_index(i).get_name() for i in range(group.get_child_count())}
        if names == TOGGLES:
            return node
    sys.exit(f"click.py: no Corner Radius toggle {label}")


def main():
    Atspi.init()
    button = radius_toggle(find_app(), sys.argv[1])
    action = button.get_action_iface()
    if action is None or action.get_n_actions() == 0:
        sys.exit("click.py: the toggle has no action")
    clicked_us = time.monotonic_ns() // 1000
    action.do_action(0)
    print(json.dumps({"clicked_us": clicked_us}), flush=True)


if __name__ == "__main__":
    main()
