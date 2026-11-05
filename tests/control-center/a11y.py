# SPDX-License-Identifier: GPL-3.0-or-later
"""C-a11y: a11y.py SURFACE measures contrast, Large Text fit and keyboard reach on an Apex Settings surface.

Run as APEX_CHECK with APEX_UNSAFE=1: it screenshots and types through org.gnome.Shell, which only unsafe mode opens.
SURFACE is apex (board 11), updates-ready or updates-available (board 18), or page: text and Large Text's fit (23, 24).
"""

import json
import os
import sys
from collections import Counter

import gi

from ccatspi import Atspi, a11y_ready, failures, find_app, finish, spin, walk
from contrast import FOCUS_CHANGED, FOCUS_MARGIN, perimeter, ratio

gi.require_version("GdkPixbuf", "2.0")
gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import GdkPixbuf, Gio, GLib, Pango, PangoCairo  # noqa: E402

TEXT_RATIO = 4.5
GLYPH_RATIO = 3.0
# probe.js's WINDOW, in the stage's logical pixels; the pointer rests outside it.
WINDOW = (170, 64, 1100, 730)
PARKED = (1400, 880)
SIDEBAR_WIDTH = 275
TAB_LIMIT = 90
STILL_TRIES = 20

# Every measurement with its box and frame (a11y/SHOT-FRAME.png), written to SHOT-a11y.json for whoever reads a value.
record = []

W = Atspi.CoordType.WINDOW
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
case = os.environ.get("APEX_SHOT", "case")
shots = os.environ.get("APEX_SHOTS", "/tmp")
# The frames each value was read off, apart from the board captures.
frames = os.path.join(shots, "a11y")
os.makedirs(frames, exist_ok=True)


def shell(js):
    ok, out = bus.call_sync("org.gnome.Shell", "/org/gnome/Shell", "org.gnome.Shell", "Eval",
                            GLib.Variant("(s)", (js,)), None, 0, 10000, None).unpack()
    if not ok:
        sys.exit(f"a11y.py: org.gnome.Shell.Eval refused: {out}")
    return out


DEVICES = """const C = imports.gi.Clutter, seat = global.stage.context.get_backend().get_default_seat();
globalThis.apexKeys ??= seat.create_virtual_device(C.InputDeviceType.KEYBOARD_DEVICE);
globalThis.apexPointer ??= seat.create_virtual_device(C.InputDeviceType.POINTER_DEVICE);"""


def keys(*names):
    press = "".join(f"apexKeys.notify_keyval(t++, C.KEY_{n}, C.KeyState.PRESSED);" for n in names)
    release = "".join(f"apexKeys.notify_keyval(t++, C.KEY_{n}, C.KeyState.RELEASED);" for n in reversed(names))
    shell(f"{DEVICES} let t = imports.gi.GLib.get_monotonic_time(); {press}{release}")
    spin(0.6)


def pointer(x, y, scroll=None, count=0, click=False):
    js = f"{DEVICES} let t = imports.gi.GLib.get_monotonic_time(); apexPointer.notify_absolute_motion(t++, {x}, {y});"
    if scroll:
        js += (f"for (let i = 0; i < {count}; i++) "
               f"apexPointer.notify_discrete_scroll(t++, C.ScrollDirection.{scroll}, C.ScrollSource.WHEEL);")
    if click:
        js += "apexPointer.notify_button(t++, C.BUTTON_PRIMARY, C.ButtonState.PRESSED);"
        js += "apexPointer.notify_button(t++, C.BUTTON_PRIMARY, C.ButtonState.RELEASED);"
    shell(js)
    spin(0.3)


def in_window(x, y, **kw):
    # A new pointer drops its first motion, as probe.js's clickLocated says, so it moves twice.
    pointer(WINDOW[0] + x - 1, WINDOW[1] + y)
    pointer(WINDOW[0] + x, WINDOW[1] + y, **kw)


# A new pointer starts in the top-left corner, where the hot corner can open the overview, and drops its first
# motion: it moves twice, and the overview closes.
def park():
    pointer(*PARKED)
    pointer(*PARKED)
    shell("Main.overview.hide();")
    spin(1.5)


class Frame:
    """A screenshot of the Settings window, read back as RGB at its own scale."""

    # A scroll to the focus and the indicator's own transition take a moment: a frame counts once two in a row agree.
    def __init__(self, name):
        path = f"{frames}/{case}-{name}.png"
        last = None
        for _ in range(STILL_TRIES):
            bus.call_sync("org.gnome.Shell.Screenshot", "/org/gnome/Shell/Screenshot", "org.gnome.Shell.Screenshot",
                          "ScreenshotArea", GLib.Variant("(iiiibs)", (*WINDOW, False, path)), None, 0, 10000, None)
            pixbuf = GdkPixbuf.Pixbuf.new_from_file(path)
            pixels = pixbuf.get_pixels()
            if pixels == last:
                break
            last = pixels
            spin(0.15)
        else:
            sys.exit(f"a11y.py: {path} still changes after {STILL_TRIES} screenshots")
        self.width, self.height = pixbuf.get_width(), pixbuf.get_height()
        self.scale = self.width // WINDOW[2]
        self.channels, self.stride = pixbuf.get_n_channels(), pixbuf.get_rowstride()
        self.data = pixbuf.get_pixels()

    def at(self, px, py):
        px, py = min(max(round(px), 0), self.width - 1), min(max(round(py), 0), self.height - 1)
        at = py * self.stride + px * self.channels
        return tuple(self.data[at:at + 3])

    def pixels(self, box):
        x, y, w, h = (round(v * self.scale) for v in box)
        for py in range(max(0, y), min(self.height, y + h)):
            row = py * self.stride
            for px in range(max(0, x), min(self.width, x + w)):
                at = row + px * self.channels
                yield px, py, tuple(self.data[at:at + 3])


def extents(node):
    e = node.get_extents(W)
    return e.x, e.y, e.width, e.height


def inside(box, area):
    x, y, w, h = box
    ax, ay, aw, ah = area
    return w > 0 and h > 0 and x >= ax and y >= ay and x + w <= ax + aw and y + h <= ay + ah


def verdict(check, value, threshold, what):
    """One measurement against its threshold."""
    value = round(value, 2)
    if value >= threshold:
        print(f"ok {case} a11y: {check}: {what} {value}:1, at least {threshold}:1", flush=True)
    else:
        failures.append(check)
        print(f"FAIL {case} a11y: {check}: {what} {value}:1, under {threshold}:1", flush=True)


def outcome(check, ok, what):
    if ok:
        print(f"ok {case} a11y: {check}: {what}", flush=True)
    else:
        failures.append(check)
        print(f"FAIL {case} a11y: {check}: {what}", flush=True)


# Text: what is drawn most in the label's box is behind the text, and the pixel farthest from it is the ink.
def text_contrast(frame, box):
    pixels = [rgb for _, _, rgb in frame.pixels(box)]
    if not pixels:
        return None
    behind = Counter(pixels).most_common(1)[0][0]
    return max(ratio(rgb, behind) for rgb in pixels)


def close(a, b):
    return max(abs(x - y) for x, y in zip(a, b)) <= FOCUS_CHANGED


# A sidebar tile sits between its row's left edge and the row's label: the gap beside the label is the sidebar,
# the colour most drawn apart from it is the fill, and the glyph is the pixel farthest from the fill inside it.
def tile_contrast(frame, row, label):
    rx, ry, _, rh = extents(row)
    lx = extents(label)[0]
    box = (rx + 6, ry, lx - rx - 6, rh)
    pixels = list(frame.pixels(box))
    sidebar = next(rgb for px, _, rgb in reversed(pixels))
    others = [rgb for _, _, rgb in pixels if not close(rgb, sidebar)]
    if not others:
        return None
    fill = Counter(others).most_common(1)[0][0]
    on_fill = [(px, py) for px, py, rgb in pixels if close(rgb, fill)]
    xs, ys = [p[0] for p in on_fill], [p[1] for p in on_fill]
    inset = 3 * frame.scale
    left, right, top, bottom = min(xs) + inset, max(xs) - inset, min(ys) + inset, max(ys) - inset
    inner = [rgb for px, py, rgb in pixels if left <= px <= right and top <= py <= bottom]
    return max(ratio(rgb, fill) for rgb in inner) if inner else None


def text_scale():
    return Gio.Settings.new("org.gnome.desktop.interface").get_double("text-scaling-factor")


# AT-SPI gives a label's font but not whether Pango cut it short; the label's text, laid out unrounded as GTK 4 does
# and wrapped at the label's width, must fit the label's height.
def fits(label):
    attrs = Atspi.Text.get_default_attributes(label)
    # GTK gives the pixel size cut to a whole pixel: a label can read as fitting by under a pixel, never the reverse.
    size = float(attrs.get("size", "0"))
    font = Pango.FontDescription.new()
    font.set_family(attrs.get("family-name", "sans"))
    font.set_weight(Pango.Weight(int(attrs.get("weight", "400"))))
    font.set_absolute_size(size * Pango.SCALE)
    context = PangoCairo.FontMap.get_default().create_context()
    context.set_round_glyph_positions(False)
    layout = Pango.Layout.new(context)
    layout.set_font_description(font)
    layout.set_text(label.get_name(), -1)
    _, _, width, height = extents(label)
    layout.set_width(width * Pango.SCALE)
    layout.set_wrap(Pango.WrapMode.WORD_CHAR)
    # Clipping is of ink, which GTK centres with the layout: GTK can give a line a pixel under Pango's logical height
    # with its glyphs still whole. The height needed is the band about the layout's middle that holds the ink.
    ink, logical = layout.get_extents()
    middle = logical.height / 2
    needed = 2 * max(middle - ink.y, ink.y + ink.height - middle) / Pango.SCALE
    return needed <= height, needed, height


def labels_in(root):
    return [n for n in walk(root) if n.get_role() == Atspi.Role.LABEL and (n.get_name() or "").strip()]


def focused(app):
    for node in walk(app):
        if node.get_state_set().contains(Atspi.StateType.FOCUSED):
            return node
    return None


# Presses Tab up to TAB_LIMIT times, keeping each focused node, and while `shoot` holds a frame of it, with where
# the control before it is now; `done` ends the walk early.
def tab_walk(app, shoot, done):
    steps = []
    for i in range(TAB_LIMIT):
        keys("Tab")
        node = focused(app)
        if node is None:
            continue
        last = steps[-1] if steps else None
        step = {"node": node, "box": extents(node), "frame": None, "last_box": None}
        if shoot(node) or (last and last["frame"]):
            step["frame"] = Frame(f"tab-{i:02d}")
            # Read after the frame: focus may have scrolled the page.
            step["box"] = extents(node)
            step["last_box"] = extents(last["node"]) if last else None
        steps.append(step)
        if done(steps):
            break
    return steps


# tests/shots/a11y.js's rule, the perimeter-th largest ratio of what focus changed; focus may scroll the page between
# the frames, so each pixel is read where the scroll put it, inside the pane and outside the next control's box.
def focus_ring(focused_frame, box, unfocused_frame, moved_box, exclude, view):
    scale = focused_frame.scale
    x, y, w, h = box
    dx, dy = moved_box[0] - x, moved_box[1] - y
    m = FOCUS_MARGIN
    ex, ey, ew, eh = exclude[0] - m, exclude[1] - m, exclude[2] + 2 * m, exclude[3] + 2 * m
    vx, vy, vw, vh = view
    ratios = []
    for px, py, now in focused_frame.pixels((x - m, y - m, w + 2 * m, h + 2 * m)):
        lx, ly = px / scale, py / scale
        bx, by = lx + dx, ly + dy
        if not (vx <= lx < vx + vw and vy <= ly < vy + vh and vx <= bx < vx + vw and vy <= by < vy + vh):
            continue
        if ex <= bx < ex + ew and ey <= by < ey + eh:
            continue
        was = unfocused_frame.at(px + dx * scale, py + dy * scale)
        if not close(now, was):
            ratios.append(ratio(now, was))
    ratios.sort(reverse=True)
    line = perimeter(w, h, scale)
    return ratios[line - 1] if len(ratios) >= line else 1.0


def report(check, items, threshold, what, unit=":1"):
    """Each item's own verdict when it misses the threshold; the rest in one line."""
    held = []
    for item, value in items:
        item = item.replace("\n", " / ")
        if value is None:
            outcome(f"{check}: {item}", False, f"{what} not measured")
        elif value < threshold:
            verdict(f"{check}: {item}", value, threshold, what)
        else:
            held.append((value, item))
    if held:
        low, item = min(held)
        print(f"ok {case} a11y: {check}: {len(held)} at least {threshold}{unit}, the lowest “{item}” at "
              f"{round(low, 2)}{unit}", flush=True)
    elif not items:
        outcome(check, False, "nothing measured")


def pane(app):
    return next(n for n in walk(app) if n.get_role() == Atspi.Role.SCROLL_PANE and extents(n)[0] >= SIDEBAR_WIDTH)


def sidebar_pane(app):
    return next(n for n in walk(app) if n.get_role() == Atspi.Role.SCROLL_PANE and extents(n)[0] < SIDEBAR_WIDTH)


def scroll(area, direction):
    x, y, w, h = area
    in_window(x + w // 2, y + h // 2, scroll=direction, count=40)
    park()


# Every label of `root` fully on screen in a frame at rest, one frame per scroll position.
def rest_contrast(app, root, positions):
    measured = {}
    for name, before in positions:
        before()
        frame = Frame(f"rest-{name}")
        view = extents(pane(app))
        for label in labels_in(root()):
            box = extents(label)
            if label.get_name() not in measured and inside(box, view):
                value = measured[label.get_name()] = text_contrast(frame, box)
                record.append({"text": label.get_name(), "box": box, "frame": name, "ratio": value})
    return list(measured.items())


def large_text(labels, skip=()):
    if text_scale() == 1:
        return
    items = []
    for label in labels:
        if label.get_name() in skip:
            continue
        _, needed, height = fits(label)
        items.append((label.get_name(), height / needed if needed else 1.0))
    report("large text: each label fits its box", items, 1.0, "its box over the height its ink needs", "")


def rings(steps, wanted, view):
    items = []
    for k, step in enumerate(steps):
        if not wanted(step["node"]) or not step["frame"]:
            continue
        later = steps[k + 1] if k + 1 < len(steps) and steps[k + 1]["frame"] else None
        name = step["node"].get_name() or step["node"].get_role_name()
        if later is None:
            items.append((name, None))
            continue
        ring = focus_ring(step["frame"], step["box"], later["frame"], later["last_box"], later["box"], view)
        items.append((name, ring))
    report("focus: the indicator changes by 3:1", items, GLYPH_RATIO, "its focus indicator")


def row_of(node):
    while node is not None and node.get_parent() is not None:
        if node.get_parent().get_role() == Atspi.Role.LIST:
            return node
        node = node.get_parent()
    return None


def panel_rows(app):
    rows = []
    for node in walk(pane(app)):
        if node.get_role() == Atspi.Role.LIST:
            rows += [node.get_child_at_index(i) for i in range(node.get_child_count())]
    return [r for r in rows if r is not None]


def in_panel(node):
    return extents(node)[0] >= SIDEBAR_WIDTH and row_of(node) is not None


def sidebar_rows(app):
    return [n for n in walk(sidebar_pane(app)) if n.get_role() == Atspi.Role.BUTTON]


# Board 11: the Apex Desktop panel's rows and the 0002 tiles at both scroll positions, then Tab from the sidebar.
def apex(app):
    content = lambda: pane(app)
    text = rest_contrast(app, content, [("bottom", park), ("top", lambda: scroll(extents(pane(app)), "UP"))])
    rows = panel_rows(app)
    row_labels = {label.get_name() for row in rows for label in labels_in(row)}
    report("text: the panel's row titles and subtitles at 4.5:1", [t for t in text if t[0] in row_labels],
           TEXT_RATIO, "against what is drawn behind it")
    tiles = {}
    for position in ("top", "bottom"):
        if position == "bottom":
            scroll(extents(sidebar_pane(app)), "DOWN")
        frame = Frame(f"tiles-{position}")
        view = extents(sidebar_pane(app))
        for row in sidebar_rows(app):
            label = next(iter(labels_in(row)), None)
            if label and row.get_name() not in tiles and inside(extents(row), view):
                tiles[row.get_name()] = tile_contrast(frame, row, label)
    report("tiles: each glyph against its fill at 3:1", list(tiles.items()), GLYPH_RATIO, "the glyph against its tile")
    large_text([label for row in rows for label in labels_in(row)])
    seen_sidebar = []

    def shoot(node):
        if extents(node)[0] < SIDEBAR_WIDTH and node.get_role() == Atspi.Role.BUTTON:
            seen_sidebar.append(node)
        return bool(seen_sidebar) and in_panel(node)

    def done(steps):
        after = [s for s in steps if seen_sidebar and s["frame"]]
        return bool(after) and not in_panel(steps[-1]["node"])

    steps = tab_walk(app, shoot, done)
    start = next((k for k, s in enumerate(steps) if s["frame"]), None)
    visited = []
    for step in steps[start:] if start is not None else []:
        row = row_of(step["node"]) if in_panel(step["node"]) else None
        if row is None:
            break
        if not visited or visited[-1] != row.get_name():
            visited.append(row.get_name())
    expected = [row.get_name() for row in panel_rows(app)]
    outcome("keyboard: Tab from the sidebar reaches every row, in order", visited == expected,
            f"visited {visited}, rows {expected}")
    rings(steps, in_panel, extents(pane(app)))


# Boards 23 and 24: the page's text, and its fit at Large Text.
def page(app):
    content = lambda: pane(app)
    text = rest_contrast(app, content, [("bottom", park), ("top", lambda: scroll(extents(pane(app)), "UP"))])
    report("text: the page's text at 4.5:1", text, TEXT_RATIO, "against what is drawn behind it")
    large_text(labels_in(pane(app)))


# Board 18: the page's state line, change list, buttons and the rest of its text, then Tab to its buttons.
def updates(app, surface):
    from update1 import CHANGES

    content = lambda: pane(app)
    text = rest_contrast(app, content, [("bottom", park), ("top", lambda: scroll(extents(pane(app)), "UP"))])
    report("text: the page's text at 4.5:1", text, TEXT_RATIO, "against what is drawn behind it")
    packages = {name for name, *_ in CHANGES} | {f"{name}.{arch}" for name, arch, *_ in CHANGES}
    large_text(labels_in(pane(app)), skip=packages)
    # "ready": every button the page shows; "available": its Download.
    buttons = [n.get_name() for n in walk(pane(app)) if n.get_role() == Atspi.Role.PUSH_BUTTON
               and n.get_state_set().contains(Atspi.StateType.SHOWING)]
    wanted = buttons if surface == "updates-ready" else ["Download"]
    named = lambda node: node.get_role() == Atspi.Role.PUSH_BUTTON and node.get_name() in wanted
    reached = []

    def shoot(node):
        if named(node) and node.get_name() not in reached:
            reached.append(node.get_name())
        return named(node)

    def done(steps):
        return len(reached) == len(wanted) and steps[-1]["frame"] is not None and not named(steps[-1]["node"])

    steps = tab_walk(app, shoot, done)
    outcome("keyboard: Tab reaches " + ", ".join(wanted), sorted(reached) == sorted(wanted), f"reached {reached}")
    rings(steps, named, extents(pane(app)))


def main():
    surface = sys.argv[1]
    app = find_app()
    a11y_ready(app)
    park()
    if surface == "apex":
        apex(app)
    elif surface == "page":
        page(app)
    else:
        updates(app, surface)
    with open(f"{shots}/{case}-a11y.json", "w", encoding="utf-8") as f:
        json.dump(record, f, indent=1, ensure_ascii=False)
    finish()


main()
