# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash disable=SC2034 # read by direct.sh, patched.sh and assert.sh

# direct.sh's pr part, which CI runs on every pull request: the scenes and every a11y check, then the
# quick dock, indicator, safe-mode (stock-light, stock-dark among them), fault and shutdown cases, in main's order.
readonly PR_CASES=(default default-scale1 dark-style high-contrast large-text default-solid
    dark-style-solid high-contrast-solid large-text-solid dock-intellihide dock-intellihide-dark
    dock-one-gpu no-dock no-dock-dark indicators indicators-scale1 indicators-dark stock-light stock-dark safe-env layer-disabled
    dock-dnd dock-external keys fault-configure fault-enable fault-abort shutdown-banner)
# direct.sh's fedora part on a pull request: the baselines of the desktop comparison.
readonly PR_FEDORA_CASES=(fedora-light fedora-dark)

# Every direct case, once: glass-stress, G2's heaviest load; the cases that read elapsed time or count
# frames, which lanes.sh never runs beside it; and the rest, which it runs beside it.
readonly STRESS_CASES=(glass-stress)
readonly TIMED_CASES=(default default-scale1 dark-style motion idle glass-load glass fedora-glass dock-pin dock-dnd
    fault-enable fault-abort shutdown-banner)
readonly QUIET_CASES=(high-contrast large-text default-solid dark-style-solid high-contrast-solid large-text-solid
    dock-intellihide dock-intellihide-dark dock-one-gpu no-dock no-dock-dark indicators indicators-scale1 indicators-dark
    stock-light stock-dark safe-env layer-disabled layer-cycles dock-external keys fault-configure kernel-safe
    fedora-light fedora-dark)

# apex-desktop's 90_apex override (tests/lib/pins.sh) moves the input source off Spotlight's Super+Space.
readonly INPUT_SOURCE_KEYS="['<Super><Alt>space', 'XF86Keyboard']"
readonly INPUT_SOURCE_BACKWARD_KEYS="['<Shift><Super><Alt>space', '<Shift>XF86Keyboard']"
# Its fonts, hinting and icon theme, as org.gnome.desktop.interface keys in the override's syntax.
readonly SESSION_FONT_NAME="'Adwaita Sans 10.125'"
readonly SESSION_DOCUMENT_FONT_NAME="'Adwaita Sans 10.125'"
readonly SESSION_MONOSPACE_FONT_NAME="'JetBrains Mono 9.75'"
readonly SESSION_FONT_HINTING="'none'"
readonly SESSION_ICON_THEME="'Apex'"
