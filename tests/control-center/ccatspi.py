# SPDX-License-Identifier: GPL-3.0-or-later
"""AT-SPI helpers shared by bindings.py, updates.py and appearance.py."""

import os
import sys
import threading
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, Gio, GLib  # noqa: E402

TIMEOUT_S = 5
# at-spi2-registryd pings each app every 30 s and disables one that leaves a ping unanswered this long.
PING_MS = 10000
REGISTRY = "org.a11y.atspi.Registry"
ROOT = "/org/a11y/atspi/accessible/root"
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
            if app is not None and app.get_name() in ("Settings", "Cài đặt", "gnome-control-center"):
                return app
        time.sleep(0.5)
    sys.exit(f"{sys.argv[0]}: Settings is not on the accessibility bus")


def a11y_bus():
    session = Gio.bus_get_sync(Gio.BusType.SESSION)
    address, = session.call_sync("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", None,
                                 GLib.VariantType("(s)"), 0, PING_MS, None).unpack()
    flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
    return Gio.DBusConnection.new_for_address_sync(address, flags, None, None)


def bus_call(bus, name, path, iface, method, args, reply):
    return bus.call_sync(name, path, iface, method, args, GLib.VariantType(reply), 0, PING_MS, None).unpack()


def registered(bus):
    """The registry's apps, by pid: an app it has disabled is not among them."""
    children, = bus_call(bus, REGISTRY, ROOT, "org.a11y.atspi.Accessible", "GetChildren", None, "(a(so))")
    pids = {}
    for name, _ in children:
        pid, = bus_call(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                        "GetConnectionUnixProcessID", GLib.Variant("(s)", (name,)), "(u)")
        pids[pid] = name
    return pids


def watch_registry(bus, names):
    """Ends the checker the moment the registry drops one of NAMES (bus name -> label) from the desktop."""
    def dropped(_conn, _sender, _path, _iface, _signal, params):
        operation, _, _, (name, _), _ = params.unpack()
        if operation != "remove" or name not in names:
            return
        owned, = bus_call(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                          "NameHasOwner", GLib.Variant("(s)", (name,)), "(b)")
        why = (f"the AT-SPI registry disabled it: it left a ping unanswered for {PING_MS // 1000} s" if owned
               else "it left the accessibility bus")
        print(f"FAIL {sys.argv[0]}: {names[name]}: {why}", flush=True)
        os._exit(1)

    def run():
        context = GLib.MainContext()
        context.push_thread_default()
        bus.signal_subscribe(REGISTRY, "org.a11y.atspi.Event.Object", "ChildrenChanged", ROOT, "remove",
                             Gio.DBusSignalFlags.NONE, dropped)
        GLib.MainLoop(context).run()

    threading.Thread(target=run, daemon=True).start()


def a11y_ready(app):
    """The walk starts once the shell (the checker's parent) and APP are on the registry's desktop and answer a ping."""
    apps = {os.getppid(): "gnome-shell", app.get_process_id(): app.get_name()}
    bus = a11y_bus()
    pids = registered(bus)
    for pid, label in apps.items():
        if pid not in pids:
            sys.exit(f"{sys.argv[0]}: {label} (pid {pid}) is not on the AT-SPI registry's desktop: it has disabled it, "
                     "or it never registered")
    names = {pids[pid]: f"{label} (pid {pid})" for pid, label in apps.items()}
    watch_registry(bus, names)
    for name, label in names.items():
        try:
            bus.call_sync(name, "/", "org.freedesktop.DBus.Peer", "Ping", None, None, 0, PING_MS, None)
        except GLib.Error as e:
            sys.exit(f"{sys.argv[0]}: {label} does not answer a ping on the accessibility bus: {e.message}")
    print(f"APEXCC-A11Y-READY {', '.join(names.values())}", flush=True)


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
