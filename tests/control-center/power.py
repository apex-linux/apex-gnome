# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks board 24's Graphics and Display group in Power through AT-SPI: the refresh row's key both ways, and the
graphics card's row, which lib.sh's headless_dgpu supplies under umockdev, following power/runtime_status."""

import glob
import os
import sys

from ccatspi import Atspi, activate, checked, failures, find, find_app, finish, wait_for, walk
from gi.repository import Gio

APEX = "io.github.apex_linux.Apex.Desktop"
KEY = "lower-refresh-rate-on-battery"
REFRESH = "Lower Refresh Rate on Battery"
# Mutter's headless monitor is virtual, not built in, so the row explains the rule instead of naming rates.
REFRESH_LINE = "The built-in display's lowest rate on battery, its highest when plugged in"
GPU = "NVIDIA GeForce RTX 3050 Mobile"
GPU_PATH = "sys/devices/pci0000:00/0000:00:01.1/0000:01:00.0/power/runtime_status"


def names(app):
    return [n.get_name() or "" for n in walk(app)]


# By last occurrence: the view switcher's “General” tab comes before the groups.
def in_order(texts, *wanted):
    last = [len(texts) - 1 - texts[::-1].index(w) if w in texts else -1 for w in wanted]
    return -1 not in last and last == sorted(last)


def say(ok, what):
    if ok:
        print(f"ok {what}", flush=True)


def check_refresh(app):
    row = find(app, REFRESH, (Atspi.Role.SWITCH,))
    if row is None:
        failures.append(f"no “{REFRESH}” switch")
        print(f"FAIL no “{REFRESH}” switch", flush=True)
        return
    say(wait_for(f"“{REFRESH}” explains its rates", lambda: REFRESH_LINE in names(app)),
        f"“{REFRESH}” explains its rates")
    s = Gio.Settings.new(APEX)
    failed = len(failures)
    for value in (not s.get_boolean(KEY), s.get_boolean(KEY)):
        s.set_boolean(KEY, value)
        Gio.Settings.sync()
        wait_for(f"{KEY}={value} shows", lambda: checked(row) == value)
    before = s.get_boolean(KEY)
    activate(row)
    wait_for(f"the switch writes {KEY}", lambda: s.get_boolean(KEY) != before)
    activate(row)
    wait_for(f"the switch writes {KEY} back", lambda: s.get_boolean(KEY) == before)
    say(len(failures) == failed, f"{REFRESH} <-> {APEX} {KEY}")


def umockdev_dir():
    for environ in glob.glob("/proc/[0-9]*/environ"):
        try:
            with open(environ, "rb") as f:
                env = dict(v.split(b"=", 1) for v in f.read().split(b"\0") if b"=" in v)
            with open(os.path.join(os.path.dirname(environ), "comm"), encoding="utf-8") as f:
                comm = f.read().strip()
        except OSError:
            continue
        if comm.startswith("gnome-control-c") and b"UMOCKDEV_DIR" in env:
            return env[b"UMOCKDEV_DIR"].decode()
    return None


def check_gpu(app):
    say(wait_for(f"“{GPU}” is off", lambda: GPU in names(app) and "Off" in names(app)
                 and "Powered down until an app asks for it" in names(app)), f"“{GPU}” shows Off")
    testbed = umockdev_dir()
    if testbed is None:
        failures.append("no gnome-control-center under umockdev")
        print("FAIL no gnome-control-center under umockdev", flush=True)
        return
    with open(os.path.join(testbed, GPU_PATH), "w", encoding="utf-8") as f:
        f.write("active\n")
    say(wait_for(f"“{GPU}” follows runtime_status to On",
                 lambda: "On" in names(app) and "Powered up for an app" in names(app)),
        f"“{GPU}” follows runtime_status to On")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "plain"
    app = find_app()
    say(wait_for("Graphics and Display shows between Power Mode and General", lambda: in_order(
        names(app), "Power Mode", "Graphics and Display", "General")),
        "Graphics and Display shows between Power Mode and General")
    check_refresh(app)
    if mode == "dgpu":
        check_gpu(app)
    else:
        say(wait_for("no NVIDIA row without the card", lambda: not any("NVIDIA" in n for n in names(app))),
            "no graphics card row without an NVIDIA card")
    finish()


main()
