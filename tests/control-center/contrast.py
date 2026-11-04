# SPDX-License-Identifier: GPL-3.0-or-later
"""WCAG 2's contrast ratio and #250's focus-indicator rule, as tests/shots/a11y.js has them.

selftest.sh keeps the two the same.
"""

# focusRing's box around a control, how far a channel must move to count as changed, and its 1 px line around the
# control, PERIMETER_SIDES * (width + height).
FOCUS_MARGIN = 8
FOCUS_CHANGED = 8
PERIMETER_SIDES = 2


def srgb(channel):
    c = channel / 255
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    r, g, b = rgb
    return 0.2126 * srgb(r) + 0.7152 * srgb(g) + 0.0722 * srgb(b)


def ratio(a, b):
    hi, lo = sorted((luminance(a), luminance(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def perimeter(width, height, scale):
    return round(PERIMETER_SIDES * (width + height) * scale)
