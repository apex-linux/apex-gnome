# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Apex commits the app tests build from; bump them together with apex-image's components.lock.
# shellcheck disable=SC2034 # read by lane.sh, tests/s2c/agent.sh and tests/s7/accent-test.sh

readonly APEX_IMAGE_URL=https://github.com/apex-linux/apex-image
readonly APEX_IMAGE_REV=d88a853101c8d93246fb62f3bb3d3311db5e6068
readonly APEX_SYSTEM_URL=https://github.com/apex-linux/apex-system
readonly APEX_SYSTEM_REV=c030843c675d72ed48f70c157d912cf580e1e97a
readonly APEX_DESKTOP_URL=https://github.com/apex-linux/apex-desktop
readonly APEX_DESKTOP_REV=8f064873e18b4ffd6a7399c2ab9d040fd7e797ee
