#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: home.py HOME CLOCK

Seeds HOME with the folders and files of the design canvas's board 27 ("Files: Home"):
their names, sizes and modification times, relative to CLOCK ("YYYY-MM-DD HH:MM:SS",
UTC), with the XDG user directories named, the images as real PNGs in the board's
colours, the sidebar's bookmarks, and the board's four recent files in
recently-used.xbel.
"""

import datetime
import os
import struct
import sys
import zlib

KB = 1000
MB = 1000 * KB
GB = 1000 * MB

XDG_DIRS = {
    "DESKTOP": "Desktop",
    "DOCUMENTS": "Documents",
    "DOWNLOAD": "Downloads",
    "MUSIC": "Music",
    "PICTURES": "Pictures",
    "PUBLICSHARE": "Public",
    "TEMPLATES": "Templates",
    "VIDEOS": "Videos",
}

# (path, size in bytes, modified as "today HH:MM", "yesterday HH:MM" or "MM-DD")
FILES = [
    ("Documents/Apex Fedora — Spec.odt", 84 * KB, "today 09:12"),
    ("Documents/Design Tokens.ods", 26 * KB, "yesterday 18:40"),
    ("Documents/HIG Notes.md", 12 * KB, "10-18"),
    ("Documents/Invoice-2026-09.pdf", 148 * KB, "10-02"),
    ("Documents/Keyboard Shortcuts.odt", 31 * KB, "09-29"),
    ("Downloads/Fedora-Workstation-Live-45.iso", 2400 * MB, "10-09"),
    ("Downloads/adwaita-icons-src.tar.xz", 18200 * KB, "10-05"),
    ("Downloads/inter-4.1.zip", 4600 * KB, "09-30"),
    ("Downloads/jetbrains-mono-2.304.zip", 5700 * KB, "09-30"),
    ("Music/Rain on Glass.flac", 38400 * KB, "08-14"),
    ("Music/Night Drive.opus", 6100 * KB, "08-02"),
    ("Music/Focus Loop.ogg", 4800 * KB, "07-21"),
    ("Pictures/mockup-2880x1800.png", 1900 * KB, "today 08:55"),
    ("Pictures/icon-grid.png", 240 * KB, "10-12"),
    ("Pictures/dock-study.png", 410 * KB, "10-07"),
    ("Pictures/Screenshots/Screenshot 09-12-04.png", 1200 * KB, "10-20"),
    ("Pictures/Screenshots/Screenshot 09-30-51.png", 1400 * KB, "10-20"),
    ("Pictures/Screenshots/Screenshot 09-38-17.png", 1100 * KB, "10-20"),
    ("Pictures/Wallpapers/apex-facets-light.png", 38 * KB, "10-21"),
    ("Pictures/Wallpapers/apex-facets-dark.png", 36 * KB, "10-21"),
    ("Pictures/Wallpapers/apex-glass.png", 2100 * KB, "09-28"),
    ("Pictures/Wallpapers/apex-mono.png", 92 * KB, "09-28"),
    ("Projects/apex-shell/stylesheet.scss", 18 * KB, "10-19"),
    ("Projects/apex-shell/metadata.json", 1 * KB, "10-02"),
    ("Projects/apex-shell/extension.js", 9 * KB, "10-19"),
    ("Projects/apex-shell/README.md", 3 * KB, "10-02"),
    ("Projects/apex-plymouth/apex.plymouth", 1 * KB, "10-15"),
    ("Projects/apex-plymouth/apex.script", 4 * KB, "10-15"),
    ("Projects/apex-plymouth/logo@2x.png", 22 * KB, "10-15"),
    ("Projects/Makefile", 2 * KB, "10-19"),
    ("Projects/README.md", 6 * KB, "10-19"),
    ("Videos/Boot Animation v3.webm", 12600 * KB, "10-03"),
    ("Videos/Overview Transition.mp4", 28900 * KB, "09-30"),
]

# Folders whose time the board gives; the rest take their newest child's.
FOLDERS = {
    "Desktop": None,
    "Public": None,
    "Templates": None,
    "Documents": "today 09:12",
    "Downloads": "10-09",
    "Music": "08-14",
    "Pictures": "today 08:55",
    "Pictures/Screenshots": "10-20",
    "Pictures/Wallpapers": "10-21",
    "Projects": "10-19",
    "Projects/apex-shell": "10-19",
    "Projects/apex-gtk-theme": "10-02",
    "Projects/apex-icons": "09-28",
    "Projects/apex-plymouth": "10-15",
    "Videos": "10-03",
}

IMAGE_COLOURS = {
    "mockup-2880x1800.png": (0xE8, 0xEB, 0xF0),
    "icon-grid.png": (0xD3, 0xD9, 0xE2),
    "dock-study.png": (0xC7, 0xD1, 0xDD),
    "apex-facets-light.png": (0xE8, 0xEB, 0xF0),
    "apex-facets-dark.png": (0x0F, 0x11, 0x15),
    "apex-glass.png": (0x4D, 0x58, 0x68),
    "apex-mono.png": (0x1B, 0x1E, 0x25),
    "logo@2x.png": (0x0F, 0x11, 0x15),
}
DEFAULT_IMAGE_COLOUR = (0xE8, 0xEB, 0xF0)
IMAGE_SIZE = (320, 200)

# The sidebar's bookmarks, as xdg-user-dirs-gtk writes them at a first login.
BOOKMARKS = ["Documents", "Downloads", "Music", "Pictures", "Videos"]

RECENT = [
    ("Pictures/mockup-2880x1800.png", "today 08:55"),
    ("Documents/Apex Fedora — Spec.odt", "today 09:12"),
    ("Documents/HIG Notes.md", "10-18"),
    ("Downloads/Fedora-Workstation-Live-45.iso", "10-09"),
]
RECENT_MIME = {
    ".png": "image/png",
    ".odt": "application/vnd.oasis.opendocument.text",
    ".md": "text/markdown",
    ".iso": "application/x-cd-image",
}


def when(clock, spec):
    if spec.startswith("today ") or spec.startswith("yesterday "):
        day, hhmm = spec.split(" ")
        hour, minute = map(int, hhmm.split(":"))
        date = clock.date() - datetime.timedelta(days=1 if day == "yesterday" else 0)
        return datetime.datetime(date.year, date.month, date.day, hour, minute, tzinfo=datetime.timezone.utc)
    month, day = map(int, spec.split("-"))
    return datetime.datetime(clock.year, month, day, 12, 0, tzinfo=datetime.timezone.utc)


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def png(colour, size):
    width, height = IMAGE_SIZE
    row = b"\0" + bytes(colour) * width
    body = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(row * height))
    )
    pad = max(0, size - len(body) - 12 - 12)
    # A private ancillary chunk gives the file the board's size; decoders skip it.
    return body + png_chunk(b"apXp", b"\0" * pad) + png_chunk(b"IEND", b"")


def write_file(path, size):
    if path.endswith(".png"):
        data = png(IMAGE_COLOURS.get(os.path.basename(path), DEFAULT_IMAGE_COLOUR), size)
        with open(path, "wb") as f:
            f.write(data)
        return
    with open(path, "wb") as f:
        f.truncate(size)


def set_time(path, moment):
    t = moment.timestamp()
    os.utime(path, (t, t), follow_symlinks=False)


def recent_xbel(home, clock):
    entries = []
    for rel, spec in RECENT:
        stamp = when(clock, spec).strftime("%Y-%m-%dT%H:%M:%S.000000Z")
        uri = "file://" + _quote_path(os.path.join(home, rel))
        mime = RECENT_MIME[os.path.splitext(rel)[1]]
        entries.append(
            f'  <bookmark href="{uri}" added="{stamp}" modified="{stamp}" visited="{stamp}">\n'
            '    <info><metadata owner="http://freedesktop.org">\n'
            f'      <mime:mime-type type="{mime}"/>\n'
            '      <bookmark:applications><bookmark:application name="Files" exec="&apos;nautilus %u&apos;"'
            f' modified="{stamp}" count="1"/></bookmark:applications>\n'
            "    </metadata></info>\n  </bookmark>\n"
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks"'
        ' xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info">\n' + "".join(entries) + "</xbel>\n"
    )


def _quote_path(path):
    return "/".join(_quote(part) for part in path.split("/"))


def _quote(part):
    out = []
    for byte in part.encode("utf-8"):
        c = chr(byte)
        out.append(c if (c.isascii() and (c.isalnum() or c in "-._~@")) else "%%%02X" % byte)
    return "".join(out)


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    home = sys.argv[1]
    clock = datetime.datetime.strptime(sys.argv[2], "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc)

    for folder in FOLDERS:
        os.makedirs(os.path.join(home, folder), exist_ok=True)
    for rel, size, spec in FILES:
        path = os.path.join(home, rel)
        write_file(path, size)
        set_time(path, when(clock, spec))
    for folder in sorted(FOLDERS, key=lambda f: -f.count("/")):
        spec = FOLDERS[folder]
        set_time(os.path.join(home, folder), when(clock, spec) if spec else when(clock, "09-28"))

    config = os.path.join(home, ".config")
    os.makedirs(config, exist_ok=True)
    with open(os.path.join(config, "user-dirs.dirs"), "w") as f:
        for key, name in XDG_DIRS.items():
            f.write(f'XDG_{key}_DIR="$HOME/{name}"\n')
    os.makedirs(os.path.join(config, "gtk-3.0"), exist_ok=True)
    with open(os.path.join(config, "gtk-3.0", "bookmarks"), "w") as f:
        f.writelines(f"file://{_quote_path(os.path.join(home, name))}\n" for name in BOOKMARKS)
    data = os.path.join(home, ".local", "share")
    os.makedirs(data, exist_ok=True)
    with open(os.path.join(data, "recently-used.xbel"), "w") as f:
        f.write(recent_xbel(home, clock))
    print(f"home.py: {len(FOLDERS)} folders, {len(FILES)} files under {home}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
