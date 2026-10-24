# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Apex commits the app tests build from; bump them together with apex-image's components.lock.
# shellcheck disable=SC2034 # read by lane.sh, tests/s2c/agent.sh and tests/s7/accent-test.sh

readonly APEX_IMAGE_URL=https://github.com/apex-linux/apex-image
readonly APEX_IMAGE_REV=3b1ba1ec31d424d9cc6d63918d60e0abf8ceebbc
readonly APEX_SYSTEM_URL=https://github.com/apex-linux/apex-system
readonly APEX_SYSTEM_REV=c030843c675d72ed48f70c157d912cf580e1e97a
readonly APEX_DESKTOP_URL=https://github.com/apex-linux/apex-desktop
readonly APEX_DESKTOP_REV=608a9186fb5871fb94acf7d24ce4fad3c4e3c2c7
