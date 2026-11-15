/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <libide-gui.h>

G_BEGIN_DECLS

#define GBP_TYPE_APEX_PALETTE (gbp_apex_palette_get_type())

G_DECLARE_FINAL_TYPE (GbpApexPalette, gbp_apex_palette, GBP, APEX_PALETTE, GtkPopover)

/* Ctrl+K on the workspace opens the palette under its header bar. */
void gbp_apex_palette_install (IdeWorkspace *workspace);

G_END_DECLS
