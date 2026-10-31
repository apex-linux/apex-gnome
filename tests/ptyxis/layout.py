#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: layout.py SHOT.png SHOT.targets.json FRAME_WIDTH FRAME_HEIGHT
       layout.py --selftest

Prints, one per line, what is wrong with the layout of contrast-atspi.py's targets in a
shoot.sh capture: text cut short (Pango's laid-out text reaching its box's right edge, as
an ellipsized label's does), two targets of one row or header over each other, or a target
outside the window. A row's subtitle may be cut short: the design ellipsizes it. Boxes are
moved past GTK's missing paddings first, as contrast.py moves them.
"""

import json
import sys

import contrast

# Pango's ellipsized text ends within this of its box's right edge.
EDGE = 2
# Boxes that share a pixel row or column at their very edge do not overlap.
TOUCH = 1


def cut(t):
    if t["kind"] != "text" or not t.get("text") or t.get("slot") == "subtitle":
        return False
    x, _, width, _ = t["box"]
    tx, _, tw, _ = t["text"]
    return tw > 0 and tx + tw >= x + width - EDGE


def overlaps(a, b):
    ax, ay, aw, ah = a["drawn"]
    bx, by, bw, bh = b["drawn"]
    return ax < bx + bw - TOUCH and bx < ax + aw - TOUCH and ay < by + bh - TOUCH and by < ay + ah - TOUCH


def group(t):
    """What a target shares its space with: its row, its header, the footer or a group heading."""
    if "row" in t:
        return f"row {t['row']}"
    return t.get("container")


def problems(targets, frame):
    width, height = frame
    found = []
    for t in targets:
        x, y, w, h = t["drawn"]
        name = f"{t['region']} {t['name']!r}"
        if t["kind"] == "terminal":
            continue
        if cut(t):
            found.append(f"{name} is cut short")
        if x < 0 or y < 0 or x + w > width or y + h > height:
            found.append(f"{name} leaves the window")
    grouped = {}
    for t in targets:
        if t["kind"] != "terminal" and group(t):
            grouped.setdefault(group(t), []).append(t)
    for members in grouped.values():
        for i, a in enumerate(members):
            for b in members[i + 1:]:
                if overlaps(a, b):
                    found.append(f"{a['region']} {a['name']!r} overlaps {b['name']!r}")
    return found


def drawn(png, targets_json, frame_width):
    """The targets with their boxes where they are drawn, as contrast.py places them."""
    width, _, rows = contrast.read_png(png)
    scale = width / frame_width
    targets = json.load(open(targets_json))["targets"]
    ratios, offsets = {}, {}
    for container in {t["container"] for t in targets if t["container"]}:
        members = [t for t in targets if t["container"] == container]
        reach = [min(t["reach"][i] for t in members) for i in (0, 1)]
        offsets[container] = contrast.located(rows, [t["box"] for t in members], reach, scale, ratios)
    for t in targets:
        dx, dy = offsets.get(t["container"], (0, 0))
        t["drawn"] = [t["box"][0] + dx, t["box"][1] + dy, t["box"][2], t["box"][3]]
    return targets


def selftest():
    def label(name, box, text, **more):
        return dict(kind="text", region="row", container="rows", name=name, box=box, drawn=box, text=text, **more)
    title = label("apex-gnome", [18, 90, 176, 17], [18, 90, 77, 16], row=76, slot="title")
    subtitle = label("claude · needs you", [18, 109, 176, 15], [18, 109, 87, 14], row=76, slot="subtitle")
    when = label("now", [204, 89, 23, 36], [204, 100, 13, 14], row=76, slot="when")
    cases = [
        ("a row at its design size", [title, subtitle, when], 0),
        ("a subtitle the design ellipsizes", [title, dict(subtitle, text=[18, 109, 176, 14]), when], 0),
        ("a title cut short", [dict(title, text=[18, 90, 175, 16]), subtitle, when], 1),
        ("a title over the time", [dict(title, box=[18, 90, 200, 17], drawn=[18, 90, 200, 17]), subtitle, when], 1),
        ("a time outside the window", [title, subtitle, dict(when, drawn=[1230, 89, 23, 36])], 1),
    ]
    failures = 0
    for what, targets, want in cases:
        got = problems(targets, (1240, 762))
        ok = len(got) == want
        failures += not ok
        print(f"{'ok' if ok else 'not ok'} - layout.py: {what}: {len(got)} problem(s) {got}", flush=True)
    return failures


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(1 if selftest() else 0)
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    for line in problems(drawn(sys.argv[1], sys.argv[2], float(sys.argv[3])), (float(sys.argv[3]), float(sys.argv[4]))):
        print(line)
