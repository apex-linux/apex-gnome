# SPDX-License-Identifier: GPL-3.0-or-later
"""fonts.py apex|updates: apex.css sizes its text in pt, which GTK scales with Large Text, unlike px.

Each label apex.css sizes must be drawn at its rule's size times text-scaling-factor, in AT-SPI's whole pixels.
"""

import math
import re
import sys
from pathlib import Path

from gi.repository import Gio

from ccatspi import Atspi, failures, find_app, finish, spin, walk

CSS = Path(__file__).resolve().parents[2] / "desktop/control-center/panels/apex/apex.css"
SIDEBAR_WIDTH = 275
KINDS = {"upgraded", "downgraded", "added", "removed"}

# Each surface's labels by the apex.css selector that sizes them.
SURFACES = {
    "apex": {
        ".apex-title": lambda name: name == "Apex Desktop",
        ".apex-versions": lambda name: name.startswith("Version "),
    },
    "updates": {
        ".apex-title": lambda name: name == "Restart to Finish Updating",
        ".apex-updates-hero .apex-subtitle": lambda name: name.startswith("45.20261010.133 is downloaded"),
        ".apex-changes": lambda name: name in KINDS,
        ".apex-changes .apex-change-versions": lambda name: "→" in name and not name.startswith("GNOME"),
    },
}


def css_pixels(selector):
    rules = re.sub(r"/\*.*?\*/", "", CSS.read_text(), flags=re.S)
    for selectors, body in re.findall(r"([^{}]+)\{([^}]*)\}", rules):
        if selector in (s.strip() for s in selectors.split(",")):
            size = re.search(r"font-size:\s*([\d.]+)(pt|px);", body)
            if size:
                value = float(size[1])
                return value * 4 / 3 if size[2] == "pt" else value
    sys.exit(f"fonts.py: no font-size for {selector} in {CSS}")


def main():
    surface = SURFACES[sys.argv[1]]
    scale = Gio.Settings.new("org.gnome.desktop.interface").get_double("text-scaling-factor")
    app = find_app()
    spin(1)
    pane = next(n for n in walk(app) if n.get_role() == Atspi.Role.SCROLL_PANE
                and n.get_extents(Atspi.CoordType.WINDOW).x >= SIDEBAR_WIDTH)
    labels = [n for n in walk(pane) if n.get_role() == Atspi.Role.LABEL and n.get_name()]
    for selector, picks in surface.items():
        want = math.floor(css_pixels(selector) * scale)
        sizes = {int(Atspi.Text.get_default_attributes(n)["size"]) for n in labels if picks(n.get_name())}
        if sizes == {want}:
            print(f"ok fonts: {selector} draws at {want} px under text-scaling-factor {scale}", flush=True)
        else:
            failures.append(selector)
            print(f"FAIL fonts: {selector} draws at {sorted(sizes) or 'nothing'} px, not {want} px under "
                  f"text-scaling-factor {scale}", flush=True)
    finish()


main()
