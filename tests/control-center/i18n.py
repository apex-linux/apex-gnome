# SPDX-License-Identifier: GPL-3.0-or-later
"""The Apex Desktop panel under LANG=vi_VN.UTF-8: its titles come from apex-control-center.mo."""

from ccatspi import failures, find_app, finish, wait_for, walk

# Two strings of the domain, a group's title and a row's, as vi.po has them.
VIETNAMESE = ["Thanh đỉnh", "Thanh đỉnh trong mờ"]
ENGLISH = ["Top Bar", "Translucent Top Bar"]

app = find_app()


def names():
    return {node.get_name() for node in walk(app)}


for text in VIETNAMESE:
    wait_for(f"{text!r} shown", lambda text=text: text in names())
shown = names()
failures.extend(f"{text!r} still in English" for text in ENGLISH if text in shown)
finish()
