# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks every row of the Apex Desktop panel against its key, both ways, through AT-SPI."""

import sys

from ccatspi import Atspi, activate, checked, failures, find, find_app, finish, radios, wait_for, walk
from gi.repository import Gio, GLib

APEX = "io.github.apex_linux.Apex.Desktop"
IFACE = "org.gnome.desktop.interface"
A11Y = "org.gnome.desktop.a11y.interface"
WM = "org.gnome.desktop.wm.preferences"
MUTTER = "org.gnome.mutter"

# (row title, schema, key, inverted, the second key a two-key row writes)
SWITCHES = [
    ("Translucent Top Bar", APEX, "translucent-top-bar", False, None),
    ("Show Focused App Name", APEX, "show-focused-app-name", False, None),
    ("Show Date in Clock", IFACE, "clock-show-date", False, (IFACE, "clock-show-weekday")),
    ("Show Battery Percentage", IFACE, "show-battery-percentage", False, None),
    ("Hot Corner", IFACE, "enable-hot-corners", False, None),
    ("Hide Behind Maximized Windows", APEX, "dock-intellihide", False, None),
    ("Show Running Indicators", APEX, "dock-running-indicators", False, None),
    ("Show Trash", APEX, "dock-show-trash", False, None),
    ("Drag to Top Edge to Maximize", MUTTER, "edge-tiling", False, None),
    ("Reduce Transparency", APEX, "reduce-transparency", False, None),
    ("Reduce Motion", IFACE, "enable-animations", True, (A11Y, "reduced-motion")),
]

# (row title, schema, key, {toggle label: value})
CHOICES = [
    ("Icon Size", APEX, "dock-icon-size", {"S": "small", "M": "medium", "L": "large"}),
    ("Corner Radius", APEX, "window-corner-radius", {"0": 0, "8": 8, "14": 14, "20": 20}),
    ("Titlebar Buttons", WM, "button-layout",
     {"All": "appmenu:minimize,maximize,close", "Close only": "appmenu:close"}),
]

settings = {}


def gsettings(schema):
    if schema not in settings:
        settings[schema] = Gio.Settings.new(schema)
    return settings[schema]


def check_switch(app, title, schema, key, inverted, second):
    row = find(app, title, (Atspi.Role.SWITCH,))
    if row is None:
        failures.append(f"{title}: no switch row")
        print(f"FAIL {title}: no switch row", flush=True)
        return
    failed = len(failures)
    s = gsettings(schema)
    for value in (not s.get_boolean(key), s.get_boolean(key)):
        s.set_boolean(key, value)
        Gio.Settings.sync()
        wait_for(f"{title}: {key}={value} shows", lambda: checked(row) == (value != inverted))
    before = s.get_boolean(key)
    activate(row)
    wait_for(f"{title}: the switch writes {key}", lambda: s.get_boolean(key) != before)
    if second is not None:
        s2 = gsettings(second[0])
        if second[1] == "clock-show-weekday":
            wait_for(f"{title}: writes {second[1]} with {key}",
                     lambda: s2.get_boolean(second[1]) == s.get_boolean(key))
        else:
            want = "reduce" if not s.get_boolean(key) else "no-preference"
            wait_for(f"{title}: writes {second[1]}={want}", lambda: s2.get_string(second[1]) == want)
    activate(row)
    wait_for(f"{title}: the switch writes {key} back", lambda: s.get_boolean(key) == before)
    if len(failures) == failed:
        print(f"ok {title} <-> {schema} {key}", flush=True)


def read(s, key):
    v = s.get_value(key)
    return v.get_uint32() if v.get_type_string() == "u" else v.get_string()


def write(s, key, value):
    s.set_value(key, GLib.Variant("u" if isinstance(value, int) else "s", value))
    Gio.Settings.sync()


def check_choice(app, title, schema, key, toggles):
    group = None
    for node in walk(app):
        if node.get_role() == Atspi.Role.RADIO_BUTTON and node.get_name() in toggles:
            if set(radios(node.get_parent())) == set(toggles):
                group = node.get_parent()
                break
    if group is None:
        failures.append(f"{title}: no toggle group {list(toggles)}")
        print(f"FAIL {title}: no toggle group", flush=True)
        return
    failed = len(failures)
    buttons = radios(group)
    s = gsettings(schema)
    original = read(s, key)
    for label, value in toggles.items():
        write(s, key, value)
        wait_for(f"{title}: {key}={value} shows {label}",
                 lambda: all(checked(b) == (n == label) for n, b in buttons.items()))
    for label, value in reversed(list(toggles.items())):
        activate(buttons[label])
        wait_for(f"{title}: {label} writes {key}={value}", lambda: read(s, key) == value)
    write(s, key, original)
    if len(failures) == failed:
        print(f"ok {title} <-> {schema} {key}", flush=True)


def main():
    Atspi.init()
    app = find_app()
    mode = sys.argv[1] if len(sys.argv) > 1 else "rows"
    if mode == "no-schema":
        wait_for("the missing-schema explanation shows",
                 lambda: find(app, "Apex Desktop Settings Are Missing", (Atspi.Role.HEADING, Atspi.Role.LABEL))
                 is not None or any("Apex Desktop Settings Are Missing" in (n.get_name() or "")
                                    for n in walk(app)))
    else:
        for row in SWITCHES:
            check_switch(app, *row)
        for row in CHOICES:
            check_choice(app, *row)
    finish()


main()
