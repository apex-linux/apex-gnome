# SPDX-License-Identifier: GPL-3.0-or-later
"""A stand-in for apex-updated on the system bus: board 18's states, and every method call logged."""

import json
import sys
import time

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

NAME = "io.github.apex_linux.Apex.Update1"
PATH = "/io/github/apex_linux/Apex/Update1"
IFACE = NAME
PROPS = "org.freedesktop.DBus.Properties"


def stamp(day, hour=9):
    return dbus.UInt64(int(time.mktime((2026, 10, day, hour, 0, 0, 0, 0, -1))))


def deployment(version, digest, day, **extra):
    d = {"image": "ghcr.io/apex-linux/apex:45", "version": version, "digest": digest, "timestamp": stamp(day)}
    d.update(extra)
    return dbus.Dictionary(d, signature="sv")


BOOTED = deployment("45.20261008.131", "sha256:3f9c0e7a5d1b28c4e6f0a9b7c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6a71e", 8,
                    held=dbus.Array([], signature="s"), degraded=dbus.Array([], signature="s"))
HOLDS = dbus.Array([("gnome-control-center", "gnome-control-center-51.1-1.fc45", stamp(19), False,
                      dbus.UInt64(stamp(19) + 14 * 86400), "")], signature="(sstbts)")
OLD_HOLDS = dbus.Array([("nautilus", "nautilus-51.1-1.fc45", stamp(19), True, dbus.UInt64(stamp(19) + 3 * 86400))],
                       signature="(sstbt)")
STOCK = dbus.Array([("libadwaita", "Apex's window radius waits for libadwaita 1.10.1.")], signature="(ss)")
SIZE = dbus.UInt64(412_000_000)
STAGED = deployment("45.20261010.133", "sha256:9e41aa07c3b2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c80c2b", 10,
                    held=dbus.Array(["gnome-control-center"], signature="s"),
                    degraded=dbus.Array([], signature="s"), holds=HOLDS, stock=STOCK, **{"download-size": SIZE})
ROLLBACK = deployment("45.20261001.124", "sha256:b02d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b19c4", 1,
                      pinned=True, **{"pin-reason": "the last version that started cleanly"})
EMPTY = dbus.Dictionary({}, signature="sv")
CHANGES = [
    ("glibc", "i686", "upgraded", "2.42-3.fc45", "2.42-4.fc45"),
    ("glibc", "x86_64", "upgraded", "2.42-3.fc45", "2.42-4.fc45"),
    ("gnome-shell", "x86_64", "upgraded", "51.0-1.fc45", "51.1-1.fc45"),
    ("kernel", "x86_64", "upgraded", "7.2.7-300.fc45", "7.2.9-300.fc45"),
    ("mesa-dri-drivers", "i686", "upgraded", "26.1.0-1.fc45", "26.1.2-1.fc45"),
    ("mesa-dri-drivers", "x86_64", "upgraded", "26.1.0-1.fc45", "26.1.2-1.fc45"),
    ("python3-libdnf5", "x86_64", "added", "", "5.4.6-1.fc45"),
    ("xorg-x11-fonts-misc", "noarch", "removed", "7.5-42.fc45", ""),
]

AVAILABLE = deployment("45.20261010.133", "", 10, **{"download-size": SIZE})
FALLEN = "sha256:9e41aa07c3b2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c80c2b"

# "ready" also refuses SetAutomaticDownloads as polkit would; "up-to-date" accepts it.
SCENARIOS = {
    "ready": {"State": "staged", "Staged": STAGED, "Available": EMPTY},
    "up-to-date": {"State": "up-to-date", "Staged": EMPTY, "Available": EMPTY,
                   "Booted": deployment(BOOTED["version"], BOOTED["digest"], 8, held=dbus.Array(["nautilus"], signature="s"),
                                        holds=OLD_HOLDS)},
    "available": {"State": "available", "Staged": EMPTY, "Available": AVAILABLE},
    "downloading": {"State": "downloading", "Staged": EMPTY, "Available": AVAILABLE, "Progress": dbus.Double(0.64)},
    "health-failure": {"State": "health-failure", "Staged": EMPTY, "Available": EMPTY,
                       "HealthFailure": BOOTED["digest"]},
    "fallback": {"State": "up-to-date", "Staged": EMPTY, "Available": EMPTY, "LastFallback": FALLEN},
}


class Update1(dbus.service.Object):
    def __init__(self, bus, scenario, log):
        super().__init__(bus, PATH)
        self.log = log
        self.props = {
            "State": "unknown", "Progress": dbus.Double(-1.0), "Booted": BOOTED, "Staged": EMPTY,
            "Rollback": ROLLBACK, "Available": EMPTY, "Channel": "stable (running image)",
            "LastCheck": stamp(21), "DeferredReason": "", "LastError": "", "HealthFailure": "",
            "LastFallback": "", "AutomaticDownloads": True,
        }
        self.scenario = scenario
        self.props.update(SCENARIOS[scenario])

    def record(self, method, *args):
        with open(self.log, "a", encoding="utf-8") as f:
            f.write(json.dumps([method, *[a if not isinstance(a, dbus.Boolean) else bool(a) for a in args]]) + "\n")

    @dbus.service.method(PROPS, in_signature="ss", out_signature="v")
    def Get(self, iface, prop):
        return self.props[prop]

    @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        return dbus.Dictionary(self.props, signature="sv") if iface == IFACE else {}

    @dbus.service.signal(PROPS, signature="sa{sv}as")
    def PropertiesChanged(self, iface, changed, invalidated):
        pass

    @dbus.service.method(IFACE)
    def Ping(self):
        pass

    @dbus.service.method(IFACE)
    def Check(self):
        self.record("Check")

    @dbus.service.method(IFACE, in_signature="b")
    def Download(self, override):
        self.record("Download", override)

    @dbus.service.method(IFACE, in_signature="s")
    def Apply(self, digest):
        self.record("Apply", str(digest))

    @dbus.service.method(IFACE, in_signature="b")
    def Rollback(self, mark_bad):
        self.record("Rollback", mark_bad)

    @dbus.service.method(IFACE, out_signature="a(sssss)")
    def GetChanges(self):
        self.record("GetChanges")
        return dbus.Array(CHANGES if self.props["Staged"] else [], signature="(sssss)")

    @dbus.service.method(IFACE)
    def AcknowledgeHealthFailure(self):
        self.record("AcknowledgeHealthFailure")

    @dbus.service.method(IFACE, in_signature="b")
    def SetAutomaticDownloads(self, enabled):
        self.record("SetAutomaticDownloads", enabled)
        if self.scenario == "ready":
            raise dbus.exceptions.DBusException("polkit refused", name=f"{IFACE}.Error.NotAuthorized")
        self.props["AutomaticDownloads"] = dbus.Boolean(enabled)
        self.PropertiesChanged(IFACE, {"AutomaticDownloads": dbus.Boolean(enabled)}, [])


def main():
    scenario, log = sys.argv[1], sys.argv[2]
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    name = dbus.service.BusName(NAME, bus, do_not_queue=True)
    service = Update1(bus, scenario, log)
    print(f"update1.py: {scenario} on {name.get_name()}", flush=True)
    GLib.MainLoop().run()
    del service


main()
