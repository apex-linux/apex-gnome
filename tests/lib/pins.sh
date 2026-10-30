# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Apex commits the app tests build from; bump them together with apex-image's components.lock.
# shellcheck disable=SC2034 # read by lane.sh, tests/s2c/agent.sh and tests/s7/accent-test.sh

readonly APEX_IMAGE_URL=https://github.com/apex-linux/apex-image
readonly APEX_IMAGE_REV=9304e95f98279cfa5b6744c19a23c87ab91e41bf
readonly APEX_SYSTEM_URL=https://github.com/apex-linux/apex-system
readonly APEX_SYSTEM_REV=70fa599d8f8a56b7ba5b7f6eecc59ac84975fbe4
readonly APEX_DESKTOP_URL=https://github.com/apex-linux/apex-desktop
readonly APEX_DESKTOP_REV=cd95f41b25c20053a94999d37d3594ffbdaa1ad2
