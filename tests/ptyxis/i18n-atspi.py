#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: i18n-atspi.py

Under vi_VN.UTF-8 (shoot.sh's vi case): the sidebar's title, its needs-you count and the host's group read in
Vietnamese from apex-ptyxis, and no English one shows. Prints the labels seen; exits 1 on a miss.
"""

import json
import re
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

APP_WAIT_S = 30
WANT = {"Dòng lệnh": "the sidebar's title", r"\d+ cần bạn": "the footer's needs-you count", "Máy này": "the host's group"}
ENGLISH = ("Terminal", r"\d+ needs you", "This computer")


def kids(node):
    return [c for c in (node.get_child_at_index(i) for i in range(node.get_child_count())) if c is not None]


def walk(node):
    yield node
    for child in kids(node):
        yield from walk(child)


def labels():
    end = time.monotonic() + APP_WAIT_S
    while time.monotonic() < end:
        for app in kids(Atspi.get_desktop(0)):
            if app.get_name() == "ptyxis":
                return [
                    n.get_name() for n in walk(app)
                    if n.get_role() == Atspi.Role.LABEL and n.get_state_set().contains(Atspi.StateType.SHOWING)
                ]
        time.sleep(0.2)
    sys.exit("i18n-atspi: Ptyxis is not on the accessibility bus")


def main():
    seen = labels()
    print(json.dumps(seen, ensure_ascii=False))
    missing = [what for pattern, what in WANT.items() if not any(re.fullmatch(pattern, t or "") for t in seen)]
    english = [t for t in seen if any(re.fullmatch(p, t or "") for p in ENGLISH)]
    if missing or english:
        sys.exit(f"i18n-atspi: missing {missing}, still English {english}; labels: {seen}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
