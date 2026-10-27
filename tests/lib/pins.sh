# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Apex commits the app tests build from; bump them together with apex-image's components.lock.
# shellcheck disable=SC2034 # read by lane.sh, tests/s2c/agent.sh and tests/s7/accent-test.sh

readonly APEX_IMAGE_URL=https://github.com/apex-linux/apex-image
readonly APEX_IMAGE_REV=87354a4ea4857cdf2e8d56ae5081cd070ec1dfb9
readonly APEX_SYSTEM_URL=https://github.com/apex-linux/apex-system
readonly APEX_SYSTEM_REV=19863b15f6fa7efea7486f0f0f96fa97e454e50e
readonly APEX_DESKTOP_URL=https://github.com/apex-linux/apex-desktop
readonly APEX_DESKTOP_REV=8f064873e18b4ffd6a7399c2ab9d040fd7e797ee
