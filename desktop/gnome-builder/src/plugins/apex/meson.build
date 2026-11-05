# SPDX-License-Identifier: GPL-3.0-or-later
# Apex Code's built-in plugin (desktop/gnome-builder in apex-gnome, Source1); the series hooks it in.

plugins_sources += files([
  'apex-plugin.c',
  'gbp-apex-a11y-addins.c',
  'gbp-apex-workbench-addin.c',
])

plugins_sources += gnome.compile_resources(
  'apex-resources',
  'apex.gresource.xml',
  c_name: 'gbp_apex',
)

subdir('po')
