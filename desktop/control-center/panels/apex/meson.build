# SPDX-License-Identifier: GPL-2.0-or-later
# The resource goes in as sources: the linker keeps an object nothing references only so.

apex_shell_sources = gnome.compile_resources(
  'cc-apex-resources',
  'apex.gresource.xml',
  c_name: 'cc_apex',
  dependencies: custom_target(
    input: files('cc-apex-panel.blp'),
    output: 'cc-apex-panel.ui',
    command: [blueprint_compiler, 'batch-compile', '@OUTDIR@', '@CURRENT_SOURCE_DIR@', '@INPUT@'],
  ),
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
  sources: files('cc-apex-panel.c', 'cc-apex-header.c'),
  include_directories: [top_inc, common_inc],
  dependencies: common_deps + [json_glib_dep],
  c_args: ['-DG_LOG_DOMAIN="cc-apex-panel"', '-DPANEL_ID="apex"'],
)

install_data(
  'icons/org.gnome.Settings-apex-symbolic.svg',
  install_dir: control_center_icondir / 'hicolor' / 'scalable' / 'apps',
)
