#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The glass protocol kit's scoring, preflight and guards on canned captures and fake sysfs; no laptop.
set -euo pipefail
exec python3 -I "$(dirname -- "${BASH_SOURCE[0]}")/test_glass_protocol.py"
