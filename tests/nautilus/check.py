#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: check.py SHOTS_DIR

Asserts what boards 27 and 28 say against each case's accessible tree
(CASE.a11y.json, from a11y.py): the disk footer's text, the item count. Prints one
line per assertion and exits 1 when one fails.
"""

import json
import os
import re
import sys

FOOTER = re.compile(r"^\d+(\.\d)? (B|kB|MB|GB|TB|PB) free of \d+(\.\d)? (B|kB|MB|GB|TB|PB)$")
SPEC_ODT = "Apex Fedora — Spec.odt"

CASES = {
    "home": {"count": "9 items"},
    "documents": {"count": f"5 items · “{SPEC_ODT}” selected"},
}


def names(tree, role=None):
    return [n["name"] for n in tree if role is None or n["role"] == role]


def check_case(name, tree, expect):
    failures = []
    labels = names(tree)
    footer = [t for t in labels if FOOTER.match(t)]
    if len(footer) == 1:
        print(f"ok {name}: the disk footer reads “{footer[0]}”")
    else:
        failures.append(f"{name}: expected one disk footer text, found {footer}")
    if "Disk usage" in names(tree, "level bar"):
        print(f"ok {name}: the disk meter is labelled")
    else:
        failures.append(f"{name}: no level bar labelled “Disk usage”")
    if expect["count"] in labels:
        print(f"ok {name}: the item-count bar reads “{expect['count']}”")
    else:
        near = [t for t in labels if " item" in t or " result" in t]
        failures.append(f"{name}: expected the count “{expect['count']}”, found {near}")
    return failures


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    shots = sys.argv[1]
    failures = []
    for case, expect in CASES.items():
        for scheme in ("light", "dark"):
            path = os.path.join(shots, f"{case}-{scheme}.a11y.json")
            if not os.path.exists(path):
                failures.append(f"{case}-{scheme}: no accessible tree")
                continue
            with open(path) as f:
                failures += check_case(f"{case}-{scheme}", json.load(f), expect)
    for f in failures:
        print(f"not ok: {f}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
