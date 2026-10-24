# SPDX-License-Identifier: GPL-2.0-or-later
# The resource goes in as sources: the linker keeps an object nothing references only so.

apex_shell_sources = gnome.compile_resources(
  'cc-apex-resources',
  'apex.gresource.xml',
  c_name: 'cc_apex',
  dependencies: custom_target(
    input: files('cc-apex-panel.blp', 'cc-apex-updates-page.blp'),
    output: ['cc-apex-panel.ui', 'cc-apex-updates-page.ui'],
    command: [blueprint_compiler, 'batch-compile', '@OUTDIR@', '@CURRENT_SOURCE_DIR@', '@INPUT@'],
  ),
)

# The copy of apex-system's contract; apex-image checks it byte for byte.
apex_update1 = gnome.gdbus_codegen(
  'cc-apex-update1',
  'io.github.apex_linux.Apex.Update1.xml',
  interface_prefix: 'io.github.apex_linux.Apex.',
  namespace: 'CcApex',
  autocleanup: 'all',
)

panels_list += 'apex'

foreach desktop : ['gnome-apex-panel.desktop', 'io.github.apex_linux.Apex.Tweaks.desktop']
  i18n.merge_file(
    type: 'desktop',
    input: desktop + '.in',
    output: desktop,
    po_dir: po_dir,
    install: true,
    install_dir: control_center_desktopdir,
  )
endforeach

panels_libs += static_library(
  'apex',
  sources: files(
    'cc-apex-background.c',
    'cc-apex-header.c',
    'cc-apex-panel.c',
    'cc-apex-power-state.c',
    'cc-apex-power.c',
    'cc-apex-sidebar.c',
    'cc-apex-tile.c',
    'cc-apex-updates-page.c',
    'cc-apex-updates-state.c',
  ) + apex_update1,
  include_directories: [top_inc, common_inc],
  dependencies: common_deps + [gudev_dep, json_glib_dep, m_dep],
  c_args: ['-DG_LOG_DOMAIN="cc-apex-panel"', '-DPANEL_ID="apex"'],
)

install_data(
  'icons/org.gnome.Settings-apex-symbolic.svg',
  install_dir: control_center_icondir / 'hicolor' / 'scalable' / 'apps',
)
