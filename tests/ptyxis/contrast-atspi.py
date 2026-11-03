#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: contrast-atspi.py

Prints, as JSON, what contrast.py measures in the running Ptyxis window, each with its box
in the window's coordinates: the sidebar's labels and status glyphs (in a row, the selected
row, a group heading or the footer), the content header's labels, each pane header's labels
and each pane's terminal, marked dimmed when the pane is unfocused beside a focused one.
"""

import json
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

R = Atspi.Role
S = Atspi.StateType
APP_WAIT_S = 30
# GTK's extents leave out each ancestor's padding and margin; the sidebar's add up to about 20 px.
SEARCH = 24
# The footer's counts, left to right, as panes-test.sh reads them.
FOOTER = ("needs you", "running", "failed", "done")
# A header's labels, left to right; a split's content header has its pane count second.
PARTS = ("title", "path", "tag")
# A session row's labels: its title, the program and its state, the time.
ROW_PARTS = ("title", "subtitle", "when")


def kids(node):
    return [c for c in (node.get_child_at_index(i) for i in range(node.get_child_count())) if c is not None]


def walk(node):
    yield node
    for child in kids(node):
        yield from walk(child)


def has(node, state):
    return node.get_state_set().contains(state)


def box(node):
    e = node.get_extents(Atspi.CoordType.WINDOW)
    return [e.x, e.y, e.width, e.height]


def app():
    end = time.monotonic() + APP_WAIT_S
    while time.monotonic() < end:
        desktop = Atspi.get_desktop(0)
        for a in kids(desktop):
            if a.get_name() == "ptyxis":
                return a
        time.sleep(0.2)
    sys.exit("contrast-atspi: Ptyxis is not on the accessibility bus")


def ancestor(node, role):
    node = node.get_parent()
    while node is not None and node.get_role() != R.FRAME:
        if node.get_role() == role:
            return node
        node = node.get_parent()
    return None


def laid_out(node):
    """A label's text as Pango laid it out, in the box's coordinates: an ellipsized one reaches its edge."""
    text = node.get_text_iface()
    count = text.get_character_count() if text is not None else 0
    if not count:
        return None
    e = text.get_range_extents(0, count, Atspi.CoordType.WINDOW)
    return [e.x, e.y, e.width, e.height]


def target(node, kind, region, container, reach=(SEARCH, SEARCH)):
    """reach: how far right and down the drawn box may sit from the reported one (contrast.py)."""
    return {"kind": kind, "region": region, "container": container, "name": node.get_name() or "", "box": box(node),
            "reach": list(reach), "text": laid_out(node) if kind == "text" else None}


def pane_header(terminal):
    """The header above a split pane's terminal: a title, a path and a tag."""
    node = terminal.get_parent()
    while node is not None and node.get_role() != R.FRAME:
        parts = kids(node)
        if parts and sum(k.get_role() == R.LABEL for k in kids(parts[0])) == 3 and \
                abs(box(parts[0])[0] - box(terminal)[0]) <= 1:
            return parts[0]
        node = node.get_parent()
    return None


def row_status(row):
    """What a row's glyph shows, from its subtitle: "program · running", "program · exit 1"."""
    labels = [n.get_name() for n in walk(row) if n.get_role() == R.LABEL and n.get_name()]
    state = labels[1].rpartition(" · ")[2] if len(labels) > 1 and " · " in labels[1] else ""
    return "failed" if state.startswith("exit ") else state if state in ("needs you", "running", "done") else None


def sidebar(nodes):
    sessions = next(n for n in nodes if n.get_role() == R.LIST and n.get_name() == "Sessions")
    x, _, width, _ = box(sessions)
    found = []
    for n in nodes:
        if n.get_role() not in (R.LABEL, R.IMAGE) or not has(n, S.SHOWING) or n.get_role() == R.LABEL and not n.get_name():
            continue
        bx, _, bw, _ = box(n)
        if bx < x or bx + bw > x + width:
            continue
        row = ancestor(n, R.LIST_ITEM)
        if row is not None:
            region, container = "selectedRow" if has(row, S.SELECTED) else "row", "rows"
        elif ancestor(n, R.LIST) is sessions:
            region, container = "group", f"group {box(n.get_parent())[1]}"
        else:
            region, container = "footer", "footer"
        found.append(target(n, "glyph" if n.get_role() == R.IMAGE else "text", region, container))
        if row is not None:
            found[-1]["row"] = box(row)[1]
            if n.get_role() == R.LABEL:
                labels = [k for k in walk(row) if k.get_role() == R.LABEL and k.get_name()]
                found[-1]["slot"] = ROW_PARTS[labels.index(n)] if labels.index(n) < len(ROW_PARTS) else None
        if n.get_role() == R.IMAGE and row is not None:
            found[-1]["status"] = row_status(row)
        elif n.get_role() == R.IMAGE and region == "group":
            found[-1]["part"] = "icon"
    footer = sorted((t for t in found if t["region"] == "footer" and t["kind"] == "glyph"), key=lambda t: t["box"][0])
    for t, status in zip(footer, FOOTER):
        t["status"] = status
    return found, x + width


def content(nodes, side_right):
    terminals = [n for n in nodes if n.get_role() == R.TERMINAL and has(n, S.SHOWING)]
    split = len(terminals) > 1
    found, in_panes = [], set()
    for t in terminals:
        dimmed = split and not has(t, S.FOCUSED)
        header = pane_header(t)
        if header is not None:
            region = "dimmedPaneHeader" if dimmed else "paneHeader"
            labels = iter(PARTS)
            for part in kids(header):
                if part.get_role() == R.LABEL and part.get_name() or part.get_role() == R.IMAGE and has(part, S.SHOWING):
                    kind = "glyph" if part.get_role() == R.IMAGE else "text"
                    # A header's parts fill its height: only its left padding is missing.
                    found.append(target(part, kind, region, f"pane {box(header)[0]}", (SEARCH, 0)))
                    found[-1]["part"] = next(labels) if kind == "text" else "needs you"
                    in_panes.add(tuple(box(part)))
        x, y, width, height = box(t)
        # The output above the prompt, clear of the caret and the scrollbar.
        found.append({"kind": "terminal", "region": "dimmedBody" if dimmed else "body", "container": None, "name": "terminal",
                      "box": [x + 4, y + 4, width - 24, height // 2]})
    top = min(box(t)[1] for t in terminals)
    header = sorted((n for n in nodes if n.get_role() == R.LABEL and n.get_name() and has(n, S.SHOWING)
                     and tuple(box(n)) not in in_panes and box(n)[0] >= side_right and box(n)[1] + box(n)[3] <= top),
                    key=lambda n: box(n)[0])
    for n, part in zip(header, PARTS):
        found.append(dict(target(n, "text", "header", "header"), part=part))
    return found


Atspi.init()
nodes = list(walk(app()))
side, side_right = sidebar(nodes)
print(json.dumps({"targets": side + content(nodes, side_right)}), flush=True)
