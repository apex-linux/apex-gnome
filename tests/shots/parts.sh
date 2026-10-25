# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash disable=SC2034 # read by direct.sh, patched.sh and assert.sh

# direct.sh's pr part, which CI runs on every pull request: the scenes and every a11y check,
# then the quick dock, indicator, safe-mode and fault cases, in main's order.
readonly PR_CASES=(default default-scale1 dark-style high-contrast large-text default-solid
    dark-style-solid high-contrast-solid large-text-solid dock-intellihide dock-intellihide-dark
    dock-one-gpu no-dock indicators indicators-scale1 indicators-dark safe-env layer-disabled
    fault-configure fault-enable fault-abort)
