# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks every row of the Apex Desktop panel against its key, both ways, through AT-SPI."""

import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, Gio, GLib  # noqa: E402

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

TIMEOUT_S = 5
failures = []
settings = {}


def gsettings(schema):
    if schema not in settings:
        settings[schema] = Gio.Settings.new(schema)
    return settings[schema]


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
    end = time.monotonic() + 30
    while time.monotonic() < end:
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(i)
            if app is not None and app.get_name() in ("Settings", "gnome-control-center"):
                return app
        time.sleep(0.5)
    sys.exit("bindings.py: Settings is not on the accessibility bus")


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
    sys.exit(f"bindings.py: {node.get_name()} has no action")


def radios(group):
    kids = (group.get_child_at_index(i) for i in range(group.get_child_count()))
    return {k.get_name(): k for k in kids if k is not None and k.get_role() == Atspi.Role.RADIO_BUTTON}


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
    print(f"APEXCC-BINDINGS {'ok' if not failures else 'FAIL ' + str(len(failures))}", flush=True)
    sys.exit(1 if failures else 0)


main()
