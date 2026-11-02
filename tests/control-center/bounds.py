# SPDX-License-Identifier: GPL-3.0-or-later
"""bounds.py: each label on the Software Updates page is where AT-SPI says, read off the case's capture.

Each label's box must hold ink, and a line 3 px outside each edge (past a glyph's overhang) must not run through text:
no more than a quarter as inky as the box's densest row or column. A box that cuts through its text is somewhere the
label is not, as GTK 4.24 reports a widget whose ancestor has CSS padding.
"""

import os
from collections import Counter

import gi

from ccatspi import Atspi, failures, find_app, finish, spin, walk

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf  # noqa: E402

WINDOW_WIDTH = 1100
SIDEBAR_WIDTH = 275
# How far a channel must move from the box's background to count as ink, as tests/shots/a11y.js's FOCUS_CHANGED.
INK = 8
OUT = 3
CUT = 0.25
# libadwaita pads its buttons: a button's label is off by that padding until GTK counts it. Pinned: one that
# holds fails, so the gap goes once GTK is fixed.
UPSTREAM = "upstream GTK 4.24: AT-SPI bounds leave out a button's CSS padding"


def extents(node):
    e = node.get_extents(Atspi.CoordType.WINDOW)
    return e.x, e.y, e.width, e.height


def main():
    shot = os.path.join(os.environ["APEX_SHOTS"], os.environ["APEX_SHOT"] + ".png")
    pixbuf = GdkPixbuf.Pixbuf.new_from_file(shot)
    scale = pixbuf.get_width() // WINDOW_WIDTH
    data, stride, channels = pixbuf.get_pixels(), pixbuf.get_rowstride(), pixbuf.get_n_channels()

    def rgb(x, y):
        at = y * stride + x * channels
        return tuple(data[at:at + 3])

    def area(x, y, w, h):
        return [rgb(px, py) for py in range(y * scale, (y + h) * scale) for px in range(x * scale, (x + w) * scale)]

    app = find_app()
    spin(1)
    pane = next(n for n in walk(app) if n.get_role() == Atspi.Role.SCROLL_PANE and extents(n)[0] >= SIDEBAR_WIDTH)
    vx, vy, vw, vh = extents(pane)
    checked = 0
    for label in walk(pane):
        name = label.get_name() or ""
        x, y, w, h = extents(label)
        if label.get_role() != Atspi.Role.LABEL or not name.strip() or w <= 0 or h <= 0:
            continue
        if x - OUT < vx or y - OUT < vy or x + w + OUT > vx + vw or y + h + OUT > vy + vh:
            continue
        inside = area(x, y, w, h)
        behind = Counter(inside).most_common(1)[0][0]
        ink = lambda pixels: sum(max(abs(a - b) for a, b in zip(p, behind)) > INK for p in pixels)
        densest_row = max(ink(area(x, y + r, w, 1)) for r in range(h))
        densest_column = max(ink(area(x + c, y, 1, h)) for c in range(w))
        rows = [ink(area(x, y - OUT, w, 1)), ink(area(x, y + h + OUT - 1, w, 1))]
        columns = [ink(area(x - OUT, y, 1, h)), ink(area(x + w + OUT - 1, y, 1, h))]
        edges = sum(rows) + sum(columns)
        checked += 1
        holds = (ink(inside) > 0 and max(rows) <= CUT * densest_row and max(columns) <= CUT * densest_column)
        what = f"“{name[:60]}” at {x},{y} {w}x{h}: {ink(inside)} ink pixels inside, {edges} around its edges"
        if label.get_parent().get_role() == Atspi.Role.PUSH_BUTTON:
            if holds:
                failures.append(name)
                print(f"FAIL bounds: {what}: holds now; drop the known gap ({UPSTREAM})", flush=True)
            else:
                print(f"GAP bounds: {what} ({UPSTREAM})", flush=True)
        elif not holds:
            failures.append(name)
            print(f"FAIL bounds: {what}", flush=True)
    if checked == 0:
        failures.append("no label")
        print("FAIL bounds: no label of the page is on screen", flush=True)
    elif not failures:
        print(f"ok bounds: the page's {checked} labels on screen are where AT-SPI puts them, but for the "
              "known gaps", flush=True)
    finish()


main()
