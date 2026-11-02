# SPDX-License-Identifier: GPL-3.0-or-later
"""bounds.py: each label on a Settings page is where AT-SPI says, read off the case's own capture.

Each label's box must hold ink, and a line 3 px outside each edge (past a glyph's overhang) must not run through text:
no more than a quarter as inky as the box's densest row or column. The lines are read against the colour most common
on them, so a label with its own background (Versions' "Checked") is read against the ring around it. A box that cuts
through its text is somewhere the label is not, as GTK 4.24 reports a widget whose ancestor has CSS padding.

No edge line tells a 2 px shift from a descender's overhang, so the change grid, the one place Apex once had such a
shift, is held by its structure: its labels start at their row's box plus the grid's margin and padding in apex.css.
"""

import os
import re
from collections import Counter
from pathlib import Path

import gi

from ccatspi import Atspi, failures, find_app, finish, spin, walk

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf  # noqa: E402

CSS = Path(__file__).resolve().parents[2] / "desktop/control-center/panels/apex/apex.css"
WINDOW_WIDTH = 1100
SIDEBAR_WIDTH = 275
# How far a channel must move from the line's colour to count as ink, as tests/shots/a11y.js's FOCUS_CHANGED.
INK = 8
OUT = 3
CUT = 0.25
KINDS = {"upgraded", "downgraded", "added", "removed", "reinstalled"}
BUTTONS = {Atspi.Role.PUSH_BUTTON, Atspi.Role.TOGGLE_BUTTON, Atspi.Role.RADIO_BUTTON}
# Upstream gaps, each pinned exactly and failing the box test: a label at its button's origin, or a label whose fill
# (its parent's) is drawn that many px below where AT-SPI puts it. A fix or a move upstream fails as "has moved".
GAPS = {
    "Keep Current Version": ("a pill button", None),
    "Restart Now": ("a pill button", None),
    "Check Now": ("a button", None),
    "Use at Next Restart…": ("a button", None),
    "S": ("a toggle group's toggle", None),
    "M": ("a toggle group's toggle", None),
    "L": ("a toggle group's toggle", None),
    "Off": ("an action row's header", 2),
}
UPSTREAM = "upstream GTK 4.24: AT-SPI bounds leave out {}'s CSS padding"


def extents(node):
    e = node.get_extents(Atspi.CoordType.WINDOW)
    return e.x, e.y, e.width, e.height


def css_box(selector, prop):
    """The selector's margin or padding in apex.css as top, right, bottom, left, in px."""
    rules = re.sub(r"/\*.*?\*/", "", CSS.read_text(), flags=re.S)
    for selectors, body in re.findall(r"([^{}]+)\{([^}]*)\}", rules):
        if selector in (s.strip() for s in selectors.split(",")):
            found = re.search(rf"(?:^|;)\s*{prop}:\s*([^;]+);", body)
            if found:
                v = [0.0 if s == "0" else float(s.removesuffix("px")) for s in found[1].split()]
                return (v * 4)[:4] if len(v) == 1 else (v + v)[:4] if len(v) == 2 else (v + v[1:2])[:4]
    return None


def grid_offset():
    """Where apex.css puts the change grid's labels in their row: the row's padding, the grid's margin and padding."""
    row = css_box("row.apex-changes-row", "padding")
    if row is None:
        return None
    margin = css_box(".apex-changes", "margin") or (0, 0, 0, 0)
    padding = css_box(".apex-changes", "padding") or (0, 0, 0, 0)
    return row[3] + margin[3] + padding[3], row[0] + margin[0] + padding[0]


def check_grid(pane):
    """The change grid's labels start at their row's box plus apex.css's offset, which GTK 4.24 leaves out if padded."""
    rows = {}
    for kind in walk(pane):
        if kind.get_role() == Atspi.Role.LABEL and kind.get_name() in KINDS:
            row = kind.get_parent()
            while row is not None and row.get_role() != Atspi.Role.LIST_ITEM:
                row = row.get_parent()
            if row is not None:
                rows[extents(row)] = row
    offset = grid_offset()
    if rows and offset is None:
        failures.append("change grid")
        print(f"FAIL bounds: the change grid's row has no padding of its own in {CSS}, so GTK 4.24 leaves libadwaita's "
              "out of the grid's AT-SPI bounds", flush=True)
        return
    for (rx, ry, _, _), row in rows.items():
        dx, dy = offset
        boxes = [extents(n) for n in walk(row) if n.get_role() == Atspi.Role.LABEL and n.get_name()]
        at = (min(b[0] for b in boxes) - rx, min(b[1] for b in boxes) - ry)
        if at == (dx, dy):
            print(f"ok bounds: the change grid's labels start at {at[0]},{at[1]} in their row, as apex.css puts them",
                  flush=True)
        else:
            failures.append("change grid")
            print(f"FAIL bounds: the change grid's labels start at {at[0]},{at[1]} in their row, not at {dx:g},{dy:g} "
                  "where apex.css's padding and margin put them", flush=True)


def main():
    # With APEX_SCROLL the check runs on the page probe.js scrolled to its end, its "-scrolled" capture.
    scrolled = "-scrolled" if os.environ.get("APEX_SCROLL") else ""
    shot = os.path.join(os.environ["APEX_SHOTS"], os.environ["APEX_SHOT"] + scrolled + ".png")
    pixbuf = GdkPixbuf.Pixbuf.new_from_file(shot)
    scale = pixbuf.get_width() // WINDOW_WIDTH
    data, stride, channels = pixbuf.get_pixels(), pixbuf.get_rowstride(), pixbuf.get_n_channels()

    def rgb(x, y):
        at = y * stride + x * channels
        return tuple(data[at:at + 3])

    def area(x, y, w, h):
        return [rgb(px, py) for py in range(y * scale, (y + h) * scale) for px in range(x * scale, (x + w) * scale)]

    def ink(pixels, behind):
        return sum(max(abs(a - b) for a, b in zip(p, behind)) > INK for p in pixels)

    def box(name, x, y, w, h):
        """Whether the label's text is in its box, and what the capture shows there."""
        inside = area(x, y, w, h)
        fill = Counter(inside).most_common(1)[0][0]
        densest_row = max(ink(area(x, y + r, w, 1), fill) for r in range(h))
        densest_column = max(ink(area(x + c, y, 1, h), fill) for c in range(w))
        lines = [area(x, y - OUT, w, 1), area(x, y + h + OUT - 1, w, 1), area(x - OUT, y, 1, h),
                 area(x + w + OUT - 1, y, 1, h)]
        ring = Counter(p for line in lines for p in line).most_common(1)[0][0]
        rows, columns = [ink(line, ring) for line in lines[:2]], [ink(line, ring) for line in lines[2:]]
        inked = ink(inside, fill)
        holds = inked > 0 and max(rows) <= CUT * densest_row and max(columns) <= CUT * densest_column
        around = sum(rows + columns)
        return holds, f"“{name[:60]}” at {x},{y} {w}x{h}: {inked} ink pixels inside, {around} around it"

    def fill_edges(x, y, h):
        """Where the fill behind a label ends above and below its box, read in column x past its text."""
        fill = rgb(x * scale, y * scale)
        top, bottom = y * scale, (y + h) * scale - 1
        while max(abs(a - b) for a, b in zip(rgb(x * scale, top - 1), fill)) <= INK:
            top -= 1
        while max(abs(a - b) for a, b in zip(rgb(x * scale, bottom + 1), fill)) <= INK:
            bottom += 1
        return top / scale, (bottom + 1) / scale

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
        checked += 1
        holds, what = box(name, x, y, w, h)
        if name not in GAPS:
            if not holds:
                failures.append(name)
                print(f"FAIL bounds: {what}", flush=True)
            continue
        widget, shift = GAPS[name]
        parent = label.get_parent()
        if shift is None:
            pinned = parent.get_role() in BUTTONS and (x, y) == extents(parent)[:2]
            where = f"at its {parent.get_role_name()}'s origin"
        else:
            _, py, _, ph = extents(parent)
            drawn = fill_edges(x + w // 2, y, h)
            pinned = drawn == (py + shift, py + ph + shift)
            where = f"{shift} px below its {parent.get_role_name()}'s box at {py} to {py + ph}"
            what += f", its fill drawn at {drawn[0]:g} to {drawn[1]:g}"
        if holds or not pinned:
            failures.append(name)
            print(f"FAIL bounds: {what}: {'holds' if holds else 'fails'}, {'' if pinned else 'not '}{where}: the "
                  f"known gap has moved ({UPSTREAM.format(widget)})", flush=True)
        else:
            print(f"GAP bounds: {what}: {where} ({UPSTREAM.format(widget)})", flush=True)
    check_grid(pane)
    if checked == 0:
        failures.append("no label")
        print("FAIL bounds: no label of the page is on screen", flush=True)
    elif not failures:
        print(f"ok bounds: the page's {checked} labels on screen are where AT-SPI puts them, but for the "
              "known gaps", flush=True)
    finish()


main()
