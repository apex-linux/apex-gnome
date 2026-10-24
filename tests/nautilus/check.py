#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: check.py SHOTS_DIR

Asserts what boards 27, 28 and 29 say against each case's accessible tree
(CASE.a11y.json, from a11y.py): the disk footer, the item count, the view toggle, the
details pane, the recent strip and the search chips. Prints one line per assertion and
exits 1 when one fails.
"""

import json
import os
import re
import sys

FOOTER = re.compile(r"^\d+(\.\d)? (B|kB|MB|GB|TB|PB) free of \d+(\.\d)? (B|kB|MB|GB|TB|PB)$")
SPEC_ODT = "Apex Fedora — Spec.odt"
RECENT = ["Apex Fedora — Spec.odt", "mockup-2880x1800.png", "HIG Notes.md", "Fedora-Workstation-Live-45.iso"]
CHIPS = ["All 11", "Folders 4", "Documents 3", "Images 4", "Audio & Video 0"]

# Per case: the count's text (or its start), the checked view toggle, whether the details
# pane shows, whether the recent strip shows, the checked chip, texts that must show.
CASES = {
    "home": {"count": "9 items", "view": "Grid View", "details": False, "recent": True},
    "documents": {
        "count": f"5 items · “{SPEC_ODT}” selected",
        "view": "List View",
        "details": True,
        "recent": False,
        "texts": ["Document", f"~/Documents/{SPEC_ODT}"],
    },
    "search": {"count_prefix": "11 results", "view": "List View", "details": False, "recent": False, "chip": "All 11"},
    "search-documents": {
        "count_prefix": "3 results",
        "view": "List View",
        "details": False,
        "recent": False,
        "chip": "Documents 3",
    },
    "noschema": {"count": "9 items", "view": "Grid View", "details": False, "recent": True},
}
SCHEMES = {"search-documents": ["light"], "noschema": ["light"]}


def showing(tree, name, role=None):
    return any(
        n["name"] == name and "showing" in n["states"] and (role is None or n["role"] == role) for n in tree
    )


def checked(tree, name):
    return any(n["name"] == name and ({"checked", "pressed"} & set(n["states"])) for n in tree)


def check_case(name, tree, expect):
    results = []

    def claim(ok, text):
        results.append((ok, f"{name}: {text}"))

    labels = [n["name"] for n in tree if "showing" in n["states"]]
    footer = [t for t in labels if FOOTER.match(t)]
    claim(len(footer) == 1, f"the disk footer reads {footer}")
    claim(showing(tree, "Disk usage", "level bar"), "the disk meter is labelled “Disk usage”")

    if "count" in expect:
        claim(expect["count"] in labels, f"the item-count bar reads “{expect['count']}”")
    else:
        found = [t for t in labels if t.startswith(expect["count_prefix"])]
        claim(len(found) == 1, f"the item-count bar starts “{expect['count_prefix']}”: {found}")

    other = "List View" if expect["view"] == "Grid View" else "Grid View"
    claim(checked(tree, expect["view"]) and not checked(tree, other), f"the view toggle is on {expect['view']}")
    claim(checked(tree, "Details") == expect["details"], f"the Details button is {'on' if expect['details'] else 'off'}")
    claim(showing(tree, "Location") == expect["details"], f"the details pane {'shows' if expect['details'] else 'is closed'}")
    for text in expect.get("texts", []):
        claim(text in labels, f"the details pane shows “{text}”")

    recent = showing(tree, "Recent") and all(showing(tree, r) for r in RECENT)
    claim(recent == expect["recent"], f"the recent strip {'shows the four' if expect['recent'] else 'is hidden'}")

    chip = expect.get("chip")
    if chip is None:
        claim(not any(showing(tree, c) for c in CHIPS), "the search chips are hidden")
    else:
        claim(all(showing(tree, c) for c in CHIPS), f"the chips read {', '.join(CHIPS)}")
        claim([c for c in CHIPS if checked(tree, c)] == [chip], f"the chip “{chip}” alone is on")
    return results


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    shots = sys.argv[1]
    failures = 0
    for case, expect in CASES.items():
        for scheme in SCHEMES.get(case, ["light", "dark"]):
            path = os.path.join(shots, f"{case}-{scheme}.a11y.json")
            if not os.path.exists(path):
                print(f"not ok: {case}-{scheme}: no accessible tree", file=sys.stderr)
                failures += 1
                continue
            with open(path) as f:
                for ok, text in check_case(f"{case}-{scheme}", json.load(f), expect):
                    print(f"ok {text}" if ok else f"not ok: {text}", file=sys.stdout if ok else sys.stderr)
                    failures += not ok
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
