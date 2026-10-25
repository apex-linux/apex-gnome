#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ADR 0014's glass acceptance, run by the owner on the laptop: glass_protocol.py. tests/laptop/README.md.
set -euo pipefail
exec python3 -I "$(dirname -- "${BASH_SOURCE[0]}")/glass_protocol.py" "$@"
