#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: update1-mock.py LOG

apex-updated's Update1 on the system bus, as python-dbusmock: up to date, with GetChanges'
rows for a staged update and an Apply that succeeds. The probe moves it between states
through dbusmock's own interface; every call is logged to LOG.
"""

import signal
import subprocess
import sys
import time

import dbus

NAME = "io.github.apex_linux.Apex.Update1"
PATH = "/io/github/apex_linux/Apex/Update1"
MOCK = "org.freedesktop.DBus.Mock"
CHANGES = [
    ("gnome-shell", "x86_64", "upgraded", "51.0-1.fc45", "51.1-1.fc45"),
    ("kernel", "x86_64", "upgraded", "7.2.7-300.fc45", "7.2.9-300.fc45"),
    ("mesa-dri-drivers", "i686", "upgraded", "26.1.0-1.fc45", "26.1.2-1.fc45"),
    ("mesa-dri-drivers", "x86_64", "upgraded", "26.1.0-1.fc45", "26.1.2-1.fc45"),
    ("python3-libdnf5", "x86_64", "added", "", "5.4.6-1.fc45"),
]


def main():
    log = sys.argv[1]
    server = subprocess.Popen([sys.executable, "-m", "dbusmock", "--system", "-l", log, NAME, PATH, NAME])
    signal.signal(signal.SIGTERM, lambda *_: (server.terminate(), sys.exit(0)))
    bus = dbus.SystemBus()
    for _ in range(100):
        if bus.name_has_owner(NAME):
            break
        time.sleep(0.1)
    mock = dbus.Interface(bus.get_object(NAME, PATH), MOCK)
    mock.AddProperties(NAME, dbus.Dictionary({
        "State": "up-to-date",
        "Staged": dbus.Dictionary({}, signature="sv"),
    }, signature="sv"))
    mock.AddMethods(NAME, [
        ("Apply", "s", "", ""),
        ("GetChanges", "", "a(sssss)", f"ret = dbus.Array({CHANGES!r}, signature='(sssss)')"),
    ])
    print(f"update1-mock.py: owns {NAME}", flush=True)
    sys.exit(server.wait())


main()
