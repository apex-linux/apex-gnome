/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

#define CC_TYPE_APEX_TILE (cc_apex_tile_get_type ())
G_DECLARE_FINAL_TYPE (CcApexTile, cc_apex_tile, CC, APEX_TILE, GtkWidget)

void cc_apex_tile_set_badge (CcApexTile *self, const char *icon_name, const char *tone);

G_END_DECLS
