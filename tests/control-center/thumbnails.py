# SPDX-License-Identifier: GPL-3.0-or-later
"""APEX_READY for Appearance: thumbnails.py PNG FRAME_WIDTH exits 0 once every thumbnail on screen is painted."""

import sys

import gi

from ccatspi import Atspi, find_app, walk

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf  # noqa: E402

HEADER = 48
INSET = 6
GAP = 8
GRID = 12


def roles(node, count):
    for _ in range(count):
        node = node.get_parent() if node is not None else None
        yield node.get_role() if node is not None else None


# A tile is a toggle button in the chooser's table; its picture sits in an overlay under it.
def thumbnails(app):
    for node in walk(app):
        tile = [Atspi.Role.TOGGLE_BUTTON, Atspi.Role.TABLE]
        if node.get_role() == Atspi.Role.IMAGE and list(roles(node, 3))[1:] == tile:
            extents = node.get_extents(Atspi.CoordType.WINDOW)
            if extents.width > 40:
                yield node.get_parent().get_parent().get_name(), extents


def pixel(pixbuf, x, y):
    offset = y * pixbuf.get_rowstride() + x * pixbuf.get_n_channels()
    return bytes(pixbuf.get_pixels()[offset:offset + 3])


# A tile not painted yet shows the card behind it, so it is blank when it matches the card in the gap beside it.
def painted(pixbuf, scale, e):
    card = pixel(pixbuf, round((e.x - GAP) * scale), round((e.y + e.height / 2) * scale))
    x, y = round((e.x + INSET) * scale), round((e.y + INSET) * scale)
    width, height = round((e.width - 2 * INSET) * scale), round((e.height - 2 * INSET) * scale)
    return any(pixel(pixbuf, x + width * (2 * i + 1) // (2 * GRID), y + height * (2 * j + 1) // (2 * GRID)) != card
               for i in range(GRID) for j in range(GRID))


def main():
    path, frame_width = sys.argv[1], int(sys.argv[2])
    pixbuf = GdkPixbuf.Pixbuf.new_from_file(path)
    # AT-SPI's window coordinates start at the frame, which is what the capture holds.
    scale = pixbuf.get_width() / frame_width
    bottom = pixbuf.get_height() / scale
    shown = blank = 0
    for name, e in thumbnails(find_app()):
        if e.width <= 2 * INSET or e.y < HEADER or e.y + e.height > bottom:
            continue
        shown += 1
        if not painted(pixbuf, scale, e):
            blank += 1
            print(f"thumbnails.py: {name} is still blank", flush=True)
    print(f"thumbnails.py: {shown - blank} of {shown} thumbnails on screen are painted", flush=True)
    sys.exit(0 if shown and not blank else 1)


main()
