# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Apex commits the app tests build from; bump them together with apex-image's components.lock.
# shellcheck disable=SC2034 # read by lane.sh and tests/s2c/agent.sh

readonly APEX_IMAGE_URL=https://github.com/apex-linux/apex-image
readonly APEX_IMAGE_REV=3b1ba1ec31d424d9cc6d63918d60e0abf8ceebbc
readonly APEX_SYSTEM_URL=https://github.com/apex-linux/apex-system
readonly APEX_SYSTEM_REV=5d2346ba50d4b112cad9a1dda82629d26100158e
