# SPDX-License-Identifier: GPL-3.0-or-later
"""bounds.py [GROUP...]: each label on a Settings page is where AT-SPI says, read off the case's own capture.

GTK 4.24 reports a widget's size right but leaves its ancestors' CSS padding out of its place. Three checks:

- Each label's box must hold ink, and a line 3 px outside each edge (past a glyph's overhang) must not run through
  text: no more than a quarter as inky as the box's densest row or column, read against the colour most common on the
  lines, so "Checked" is read against the ring around its own fill. This catches a box that cuts through its text, not
  a small shift: a row title holds for vertical shifts of -6 to +8 px.
- Structure: every list row hides libadwaita's 2 px of padding each side (`list > row`), by sizes, but What's New's
  grid row and expander rows none; and each of the grid's kind labels starts its ink exactly where it did, against its
  box, so a shift from any rule fails. Its sizes and apex.css only name the likely cause.
- The upstream gaps, each pinned exactly in GAPS.

GROUPs name what the page must show: rows, grid, or a GAPS group. One that is not there fails.
"""

import os
import re
import sys
from collections import Counter, namedtuple
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
ROW_PADDING = 2
# Where each kind label's ink starts in its AT-SPI box (Adwaita Sans at run.sh's size and hinting): any hidden shift,
# from any rule, moves it.
KIND_INK = (0.5, 3.0)
UPSTREAM = "upstream GTK 4.24: AT-SPI bounds leave out {}"

# A label's upstream gap, pinned exactly: its box within the ancestor `up` levels above, which draws its fill; that
# fill's offset from the ancestor's box, the same size; and the offset where the label's own box() holds.
Gap = namedtuple("Gap", "group up inside fill text padding")
PILL = "a pill button's padding (32, 10)"
BUTTON = "a button's padding (17, 5) and its list row's"
TOGGLE = "a toggle group's padding (3), its toggle's (8, 0) and its list row's"
GAPS = {
    "Keep Current Version": Gap("pills", 1, (0, 0, 64, 20), (0, 0), (32, 10), PILL),
    "Restart Now": Gap("pills", 1, (0, 0, 64, 20), (0, 0), (32, 10), PILL),
    "Check Now": Gap("buttons", 1, (0, 0, 34, 10), (2, 2), (19, 7), BUTTON),
    "Use at Next Restart…": Gap("buttons", 1, (0, 0, 34, 10), (2, 2), (19, 7), BUTTON),
    "S": Gap("toggles", 2, (0, 0, 108, 6), (2, 2), (13, 5), TOGGLE),
    # The active toggle's label fills its raised fill top to bottom, so no line 3 px outside is clear: it is held by
    # its box and its group's fill alone. Toggle text pins hold to about 2 px, as box() does.
    "M": Gap("toggles", 2, (43, 0, 65, 6), (2, 2), None, TOGGLE),
    "L": Gap("toggles", 2, (86, 0, 22, 6), (2, 2), (13, 5), TOGGLE),
    "Off": Gap("gpu", 1, (23, 4, 10, 5), (2, 2), (2, 2), "its list row's padding"),
}


def extents(node):
    e = node.get_extents(Atspi.CoordType.WINDOW)
    return e.x, e.y, e.width, e.height


def margins(selector):
    """The selector's margin in apex.css (top, right, bottom, left), its rules in order, shorthand and longhands; and
    any other selector naming its class that sets a margin or padding, which this reading would miss."""
    sides = ["top", "right", "bottom", "left"]
    margin = dict.fromkeys(sides, 0.0)
    others = []
    px = lambda v: 0.0 if v == "0" else float(v.removesuffix("px"))
    rules = re.sub(r"/\*.*?\*/", "", CSS.read_text(), flags=re.S)
    for selectors, body in re.findall(r"([^{}]+)\{([^}]*)\}", rules):
        declarations = re.findall(r"([\w-]+)\s*:\s*([^;]+);", body)
        for other in (s.strip() for s in selectors.split(",")):
            naming = re.search(rf"{re.escape(selector)}(?![\w-])", other)
            if naming and other != selector and any(p.startswith(("margin", "padding")) for p, _ in declarations):
                others.append(other)
        if selector not in (s.strip() for s in selectors.split(",")):
            continue
        for prop, value in declarations:
            if prop == "margin":
                v = [px(s) for s in value.split()]
                v = v * 4 if len(v) == 1 else v + v if len(v) == 2 else v + v[1:2] if len(v) == 3 else v
                margin.update(zip(sides, v))
            elif prop.removeprefix("margin-") in sides:
                margin[prop.removeprefix("margin-")] = px(value.strip())
    return tuple(margin[s] for s in sides), others


def check_rows(pane):
    """Each list row hides its padding from AT-SPI: its content's box is that much smaller than where it starts."""
    found = []
    for row in walk(pane):
        if row.get_role() != Atspi.Role.LIST_ITEM or row.get_child_count() == 0:
            continue
        rx, _, rw, _ = extents(row)
        cx, _, cw, _ = extents(row.get_child_at_index(0))
        hidden = (rw - cw) - 2 * (cx - rx)
        grid = any(n.get_role() == Atspi.Role.LABEL and n.get_name() in KINDS for n in walk(row))
        nested = any(n.get_role() == Atspi.Role.LIST_ITEM for n in list(walk(row))[1:])
        want = 0 if grid or nested else 2 * ROW_PADDING
        found.append(row)
        if hidden != want:
            failures.append(f"row {row.get_name()}")
            print(f"FAIL bounds: list row “{row.get_name()}” hides {hidden} px of padding across, not {want}: "
                  f"{'the known gap has moved' if want else 'AT-SPI leaves it out'} "
                  f"({UPSTREAM.format('libadwaita list rows’ padding')})", flush=True)
    if found:
        print(f"GAP bounds: {len(found)} list rows each hide {ROW_PADDING} px of padding a side from AT-SPI, so their "
              f"labels are {ROW_PADDING} px left of their text, but What's New's grid row and expander rows hide none "
              f"({UPSTREAM.format('libadwaita list rows’ padding')})", flush=True)
    return bool(found)


def grid_causes(pane):
    """Why What's New's grid could be off its text, from sizes and apex.css: diagnostics only, the ink pin decides."""
    (top, right, bottom, left), others = margins(".apex-changes")
    causes = [f"{', '.join(others)} in apex.css sets a margin or padding read nowhere here"] if others else []
    grids = {}
    for kind in walk(pane):
        if kind.get_role() == Atspi.Role.LABEL and kind.get_name() in KINDS:
            grids[extents(kind.get_parent())] = kind.get_parent()
    for (gx, gy, gw, gh), grid in grids.items():
        rx, ry, rw, rh = extents(grid.get_parent())
        got = (gx - rx, gy - ry, rw - gw, rh - gh)
        want = (left, top, left + right, top + bottom)
        boxes = [extents(n) for n in list(walk(grid))[1:]]
        cells = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[0] + b[2] for b in boxes),
                 max(b[1] + b[3] for b in boxes))
        if cells != (gx, gy, gx + gw, gy + gh):
            causes.append(f"the grid is {gx},{gy} to {gx + gw},{gy + gh}, its labels {cells}: they don't fill it (its "
                          "padding, or a label's margin)")
        if got != want:
            causes.append(f"the grid sits {got[0]:g},{got[1]:g} into its row, {got[2]:g}x{got[3]:g} smaller, not "
                          f"{want[0]:g},{want[1]:g} and {want[2]:g}x{want[3]:g} from apex.css's margins (the row's "
                          "padding)")
    return causes


def main():
    groups = set(sys.argv[1:])
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

    def drawn_fill(x, y, w, h):
        """Where the fill an AT-SPI box's widget draws begins and ends, read from 8 px outside it inwards."""
        inner = area(x + 3, y + 3, w - 6, h - 6)
        fill = Counter(inner).most_common(1)[0][0]
        # Across the middle row; down and up a column half the height in, where a rounded end is straight.
        row, column = (2 * y + h) * scale // 2, (x + min(h, w) // 2) * scale

        def edge(points):
            return next((p for p in points if max(abs(a - b) for a, b in zip(rgb(*p), fill)) <= INK), None)

        span = range(16 * scale)
        ends = [edge([((x - 8) * scale + i, row) for i in span]), edge([(column, (y - 8) * scale + i) for i in span]),
                edge([((x + w + 8) * scale - 1 - i, row) for i in span]),
                edge([(column, (y + h + 8) * scale - 1 - i) for i in span])]
        if None in ends:
            return None
        return ends[0][0] / scale, ends[1][1] / scale, (ends[2][0] + 1) / scale, (ends[3][1] + 1) / scale

    def ink_start(x, y, w, h):
        """Where the ink around an AT-SPI box starts, against the box, read 4 px around it."""
        points = [(px, py) for py in range((y - 4) * scale, (y + h + 4) * scale)
                  for px in range((x - 4) * scale, (x + w + 4) * scale)]
        behind = Counter(rgb(*p) for p in points).most_common(1)[0][0]
        inked = [p for p in points if max(abs(a - b) for a, b in zip(rgb(*p), behind)) > INK]
        if not inked:
            return None
        return min(p[0] for p in inked) / scale - x, min(p[1] for p in inked) / scale - y

    def check_grid_ink():
        """Each What's New kind label on screen has its ink where AT-SPI says, exactly."""
        kinds = [n for n in walk(pane) if n.get_role() == Atspi.Role.LABEL and n.get_name() in KINDS]
        shown = [(n.get_name(), extents(n)) for n in kinds]
        shown = [(k, b) for k, b in shown if b[1] - 4 >= vy and b[1] + b[3] + 4 <= vy + vh]
        off = [(k, b, ink_start(*b)) for k, b in shown]
        off = [(k, b, at) for k, b, at in off if at != KIND_INK]
        for kind, (x, y, _, _), at in off:
            causes = grid_causes(pane)
            failures.append("change grid")
            likely = "; likely " + "; ".join(causes) if causes else ""
            print(f"FAIL bounds: What's New's “{kind}” at {x},{y}: its ink starts {at} into its box, not "
                  f"{KIND_INK}: AT-SPI puts it off its text{likely}", flush=True)
        if shown and not off:
            print(f"ok bounds: What's New's {len(shown)} kind labels on screen each start their ink {KIND_INK} into "
                  "their box", flush=True)
            for cause in grid_causes(pane):
                print(f"note bounds: {cause}, but the ink is where AT-SPI says", flush=True)
        return bool(shown)

    def check_gap(label, name, gap, holds, what):
        x, y, w, h = extents(label)
        owner = label
        for _ in range(gap.up):
            owner = owner.get_parent()
        ox, oy, ow, oh = extents(owner)
        inside = (x - ox, y - oy, ox + ow - x - w, oy + oh - y - h)
        fill = drawn_fill(ox, oy, ow, oh)
        want_fill = (ox + gap.fill[0], oy + gap.fill[1], ox + ow + gap.fill[0], oy + oh + gap.fill[1])
        shifted = gap.text is None or box(name, x + gap.text[0], y + gap.text[1], w, h)[0]
        moved = [f"{'holds' if holds else 'fails'} where AT-SPI puts it" if holds else None,
                 f"its box {inside} in its {owner.get_role_name()}, not {gap.inside}" if inside != gap.inside else None,
                 f"its {owner.get_role_name()}'s fill drawn at {fill}, not {want_fill}" if fill != want_fill else None,
                 f"fails moved {gap.text}" if not shifted else None]
        moved = [m for m in moved if m]
        upstream = UPSTREAM.format(gap.padding)
        if moved:
            failures.append(name)
            print(f"FAIL bounds: {what}: {'; '.join(moved)}: the known gap has moved ({upstream})", flush=True)
        else:
            print(f"GAP bounds: {what}: at {gap.inside} in its {owner.get_role_name()}, whose fill is drawn "
                  f"{gap.fill} off its box{f'; its text {gap.text} off' if gap.text else ''} ({upstream})", flush=True)

    app = find_app()
    spin(1)
    pane = next(n for n in walk(app) if n.get_role() == Atspi.Role.SCROLL_PANE and extents(n)[0] >= SIDEBAR_WIDTH)
    vx, vy, vw, vh = extents(pane)
    checked, seen = 0, set()
    for label in walk(pane):
        name = label.get_name() or ""
        x, y, w, h = extents(label)
        if label.get_role() != Atspi.Role.LABEL or not name.strip() or w <= 0 or h <= 0:
            continue
        if x - OUT < vx or y - OUT < vy or x + w + OUT > vx + vw or y + h + OUT > vy + vh:
            continue
        checked += 1
        holds, what = box(name, x, y, w, h)
        if name in GAPS:
            seen.add(name)
            check_gap(label, name, GAPS[name], holds, what)
        elif not holds:
            failures.append(name)
            print(f"FAIL bounds: {what}", flush=True)
    present = {"rows": check_rows(pane), "grid": check_grid_ink()}
    for group in sorted(groups):
        members = {n for n, g in GAPS.items() if g.group == group}
        if members:
            missing = members - seen
        elif group in present:
            missing = set() if present[group] else {group}
        else:
            missing = {f"{group}, no such group,"}
        if missing:
            failures.append(group)
            print(f"FAIL bounds: the page should show {group}, but {', '.join(sorted(missing))} is not on it",
                  flush=True)
    if checked == 0:
        failures.append("no label")
        print("FAIL bounds: no label of the page is on screen", flush=True)
    elif not failures:
        print(f"ok bounds: the page's {checked} labels on screen are where AT-SPI puts them, but for the "
              "known gaps", flush=True)
    finish()


main()
