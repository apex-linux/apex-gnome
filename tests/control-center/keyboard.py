# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks through AT-SPI that Keyboard's shortcut list shows Spotlight and the input-source switch on apex-desktop's keys."""

import sys

from ccatspi import Atspi, failures, find, find_app, finish, spin, wait_for, walk

OPEN = "View and Customize Shortcuts"
SEARCH = "Search Shortcuts"
# (row title, search text, the label Settings shows): apex-desktop's 60-apex.xml and 90_apex.gschema.override;
# GTK's accelerator labels put Alt before Super, so <Super><Alt>space reads Alt+Super+Space.
ROWS = [
    ("Open Spotlight", "Spotlight", "Super+Space"),
    ("Switch to next input source", "input source", "Alt+Super+Space"),
    ("Switch to previous input source", "input source", "Shift+Alt+Super+Space"),
]


def rows_named(app, title):
    return [n for n in walk(app) if n.get_name() == title and n.get_role() != Atspi.Role.LABEL]


def accelerators(row):
    return [n.get_name() for n in walk(row) if n.get_role() == Atspi.Role.LABEL and "+" in (n.get_name() or "")]


def search(app, text):
    entry = next((n for n in walk(app) if n.get_name() == SEARCH and n.get_editable_text_iface() is not None), None)
    if entry is None:
        return False
    entry.get_editable_text_iface().set_text_contents(text)
    spin(1)
    return True


def check(app, title, text, accel):
    if not search(app, text):
        failures.append(f"{title}: no search entry")
        print(f"FAIL {title}: no {SEARCH} entry", flush=True)
        return
    failed = len(failures)
    wait_for(f"{title}: one row in the shortcut list", lambda: len(rows_named(app, title)) == 1)
    shown = [a for row in rows_named(app, title) for a in accelerators(row)]
    if len(failures) == failed and shown != [accel]:
        failures.append(f"{title}: shows {shown}, not {accel}")
        print(f"FAIL {title}: shows {shown}, not {accel}", flush=True)
    if len(failures) == failed:
        print(f"ok {title}: {accel}", flush=True)


def locate(app):
    """Prints the centre of the row that opens the shortcut list for probe.js to click: it has no AT-SPI action."""
    roles = (Atspi.Role.BUTTON, Atspi.Role.PUSH_BUTTON)
    if wait_for(f"Keyboard shows “{OPEN}”", lambda: find(app, OPEN, roles) is not None):
        e = find(app, OPEN, roles).get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        print(f"APEXCC-AT {e.x + e.width // 2} {e.y + e.height // 2}", flush=True)


def main():
    Atspi.init()
    app = find_app()
    if sys.argv[1:] == ["locate"]:
        locate(app)
        finish()
    if wait_for("the shortcut list opens", lambda: any(n.get_name() == SEARCH for n in walk(app))):
        for row in ROWS:
            check(app, *row)
    finish()


main()
