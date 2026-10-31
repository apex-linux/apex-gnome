#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: contrast.py SHOT.png SHOT.targets.json FRAME_WIDTH
       contrast.py --selftest

Measures each target contrast-atspi.py found in shoot.sh's capture of the same scene, and
prints them as JSON: a target's ground is the colour most of its box is, its ink the colour
of its strongest strokes (the 90th percentile, by contrast with the ground, of the pixels
that differ from it), so a dimmed or translucent ink is measured as it is drawn. A terminal
is measured the same way, its output's strokes against its background. With --selftest it
checks itself on drawn images instead.
"""

import json
import struct
import sys
import zlib

# A pixel this close to the ground in contrast is the ground, antialiased or dithered.
GROUND_RATIO = 1.05
INK_PERCENTILE = 0.9
# A stroke, for the search: clear of a neighbouring surface a shade off the ground, as a header's
# beside a terminal's in dark.
STROKE_RATIO = 1.5
RING_WEIGHT = 4


def read_png(path):
    """An 8-bit RGB or RGBA, non-interlaced PNG, as gnome-shell writes it: (width, height, rows of RGB)."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG"
    pos, idat, width = 8, b"", None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
            assert depth == 8 and colour in (2, 6) and interlace == 0, f"{path}: unsupported PNG"
            channels = 3 if colour == 2 else 4
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = width * channels
    rows, prev = [], bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append([tuple(line[x * channels:x * channels + 3]) for x in range(width)])
        prev = line
    return width, height, rows


def write_png(path, rows):
    """RGB rows as a PNG: --selftest's drawn images."""
    height, width = len(rows), len(rows[0])
    raw = b"".join(b"\x00" + bytes(v for px in row for v in px) for row in rows)

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def luminance(rgb):
    def channel(v):
        c = v / 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (channel(v) for v in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    hi, lo = sorted((luminance(a), luminance(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def lightness(rgb):
    """CIELAB L*, 0 to 100."""
    y = luminance(rgb)
    return 116 * (y ** (1 / 3) if y > 216 / 24389 else (24389 / 27 * y + 16) / 116) - 16


def hexed(rgb):
    return "#" + "".join(f"{v:02x}" for v in rgb)


def mode(pixels):
    counts = {}
    for px in pixels:
        counts[px] = counts.get(px, 0) + 1
    return max(counts, key=counts.get)


def stroke_counter(rows, area, ground, ratios):
    """Counts, by an integral image, the pixels in a box that differ from the ground."""
    x0, y0, x1, y1 = area
    patch = [row[x0:x1] for row in rows[y0:y1]]
    h, w = len(patch), len(patch[0])
    integral = [[0] * (w + 1) for _ in range(h + 1)]
    for j in range(h):
        run = 0
        for i in range(w):
            px = patch[j][i]
            if (px, ground) not in ratios:
                ratios[px, ground] = ratio(px, ground)
            run += ratios[px, ground] > STROKE_RATIO
            integral[j + 1][i + 1] = integral[j][i + 1] + run

    def strokes(left, top, right, bottom):
        left, top = max(0, left - x0), max(0, top - y0)
        right, bottom = min(w, right - x0), min(h, bottom - y0)
        if right <= left or bottom <= top:
            return 0
        return integral[bottom][right] - integral[top][right] - integral[bottom][left] + integral[top][left]
    return strokes


def located(rows, boxes, reach, scale, ratios):
    """GTK's AT-SPI extents leave out each ancestor's padding and margin, the same for every box of
    one container: the offset, within reach right and down, that puts the most strokes inside the
    container's boxes and the fewest in the pixel ring around each."""
    scaled = [[round(v * scale) for v in b] for b in boxes]
    reach_x, reach_y = (round(r * scale) for r in reach)
    ring = max(1, round(scale))
    height, width = len(rows), len(rows[0])
    area = (max(0, min(b[0] for b in scaled) - ring), max(0, min(b[1] for b in scaled) - ring),
            min(width, max(b[0] + b[2] for b in scaled) + reach_x + ring),
            min(height, max(b[1] + b[3] for b in scaled) + reach_y + ring))
    # The ground the boxes stand on as reported: below a header, the area can reach a terminal's own.
    ground = mode(px for x, y, w, h in scaled for row in rows[max(0, y):y + h] for px in row[max(0, x):x + w])
    strokes = stroke_counter(rows, area, ground, ratios)
    best = None
    for dy in range(reach_y + 1):
        for dx in range(reach_x + 1):
            score = 0
            for x, y, w, h in scaled:
                inside = strokes(x + dx, y + dy, x + dx + w, y + dy + h)
                around = strokes(x + dx - ring, y + dy - ring, x + dx + w + ring, y + dy + h + ring) - inside
                score += inside - RING_WEIGHT * around
            if best is None or score > best[0]:
                best = (score, dx, dy)
    return best[1] / scale, best[2] / scale


def measure(rows, box, scale):
    x, y, width, height = (round(v * scale) for v in box)
    pixels = [px for row in rows[max(0, y):y + height] for px in row[max(0, x):x + width]]
    if not pixels:
        return {"ground": None, "ink": None, "ratio": None, "lightness": None}
    counts = {}
    for px in pixels:
        counts[px] = counts.get(px, 0) + 1
    ground = mode(pixels)
    strokes = sorted((r, px) for px in counts for r in [ratio(px, ground)] if r > GROUND_RATIO
                     for _ in range(counts[px]))
    ink = strokes[int(len(strokes) * INK_PERCENTILE)][1] if strokes else ground
    return {"ground": hexed(ground), "ink": hexed(ink), "ratio": round(ratio(ink, ground), 2),
            "lightness": round(lightness(ink), 1)}


def report(png, targets_json, frame_width):
    width, _, rows = read_png(png)
    scale = width / frame_width
    targets = json.load(open(targets_json))["targets"]
    ratios, offsets = {}, {}
    for container in {t["container"] for t in targets if t["container"]}:
        members = [t for t in targets if t["container"] == container]
        reach = [min(t["reach"][i] for t in members) for i in (0, 1)]
        offsets[container] = located(rows, [t["box"] for t in members], reach, scale, ratios)
    measured = []
    for t in targets:
        dx, dy = offsets.get(t["container"], (0, 0))
        box = [t["box"][0] + dx, t["box"][1] + dy, t["box"][2], t["box"][3]]
        measured.append(dict(t, offset=[dx, dy], **measure(rows, box, scale)))
    return measured


def selftest():
    """A label's strokes over a row's fill, as an image: legible, then in the fill's own colour."""
    import tempfile
    fill, ink = (241, 241, 244), (29, 29, 33)
    failures = 0

    def drawn(stroke):
        rows = [[fill] * 40 for _ in range(20)]
        for yy in range(6, 14):
            for xx in range(4, 36, 4):
                rows[yy][xx] = rows[yy][xx + 1] = stroke
                rows[yy][xx + 2] = tuple((s + f) // 2 for s, f in zip(stroke, fill))
        return rows

    cases = [("a label in the foreground", drawn(ink), lambda m: m["ratio"] >= 4.5 and m["ink"] == hexed(ink)),
             ("a label in its row's fill colour", drawn(fill), lambda m: m["ratio"] == 1.0)]
    with tempfile.TemporaryDirectory() as tmp:
        for what, rows, holds in cases:
            png = f"{tmp}/shot.png"
            write_png(png, rows)
            _, _, read = read_png(png)
            m = measure(read, [0, 0, 20, 10], 2)
            ok = read == rows and holds(m)
            failures += not ok
            print(f"{'ok' if ok else 'not ok'} - contrast.py: {what} measures {m['ratio']}:1", flush=True)
    return failures


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(1 if selftest() else 0)
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    print(json.dumps(report(sys.argv[1], sys.argv[2], float(sys.argv[3]))))
