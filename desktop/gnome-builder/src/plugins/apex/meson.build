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

# E2: one process per toolbox runs what Builder runs there (apex-toolbox-bridge.h).
foreach tool : ['apex-toolbox-exec', 'apex-toolbox-bridge']
  executable(tool, tool + '.c',
    c_args: ['-DPACKAGE_LIBEXECDIR="@0@"'.format(get_option('prefix') / get_option('libexecdir'))],
    install: true,
    install_dir: get_option('libexecdir'),
  )
endforeach

subdir('po')
