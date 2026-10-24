# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks board 23's wallpaper name and note in Appearance through AT-SPI, and that they follow a new wallpaper."""

import sys

import gi

from ccatspi import Atspi, checked, find, find_app, finish, wait_for, walk

gi.require_version("Gio", "2.0")
from gi.repository import Gio  # noqa: E402

NOTE = "{} has a light and a dark version and follows the style."
# balls.xml's entry; the chooser's tiles have no AT-SPI action, so the settings change as a click would make them.
BALLS = {"picture-uri": "file:///usr/share/backgrounds/gnome/balls-l.jxl",
         "picture-uri-dark": "file:///usr/share/backgrounds/gnome/balls-d.jxl",
         "primary-color": "#3C3635", "secondary-color": "#E4DAC4"}


def labels(app):
    return [n.get_name() for n in walk(app) if n.get_role() == Atspi.Role.LABEL]


def shows(app, name):
    tile = find(app, name, (Atspi.Role.TOGGLE_BUTTON,))
    return name in labels(app) and NOTE.format(name) in labels(app) and tile is not None and checked(tile)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "amber"
    app = find_app()
    if mode == "custom":
        wait_for("custom: the Background group is up", lambda: "Background" in labels(app))
        if wait_for("custom: no wallpaper name or note",
                    lambda: not any("follows the style" in (t or "") for t in labels(app))):
            print("ok custom: a wallpaper outside the chooser shows no name or note", flush=True)
        finish()
    if wait_for("amber: shows “Amber” and its note, its tile checked", lambda: shows(app, "Amber")):
        print("ok amber: the header and note name Amber", flush=True)
    settings = Gio.Settings.new("org.gnome.desktop.background")
    for key, value in BALLS.items():
        settings.set_string(key, value)
    Gio.Settings.sync()
    if wait_for("amber: Balls is named once set", lambda: shows(app, "Balls") and "Amber" not in labels(app)):
        print("ok amber: setting Balls moves the name, the note and the check to Balls", flush=True)
    finish()


main()
