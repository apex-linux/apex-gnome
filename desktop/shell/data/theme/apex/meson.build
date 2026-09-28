# SPDX-License-Identifier: GPL-2.0-or-later
#
# The Apex SCSS (ADR 0014). Patch 0001-build reads this file with subdir('apex') from
# data/theme/meson.build, right after upstream's theme_sources: the sassc targets
# depend on that list, so a change to an Apex partial recompiles the sheets.
theme_sources += files(
  '_apex-tokens.scss',
  '_apex.scss',
  '_apex-structure.scss',
)
