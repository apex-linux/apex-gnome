/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "config.h"

#include "ptyxis-palette.h"

#include "apex-palette.h"

/* A rewritten user palette replaces its object in the palette list, while the
 * profile's palette changes only with its GSettings key: terminals keep the old one. */
static void
palettes_changed_cb (PtyxisProfile *profile,
                     guint          position,
                     guint          removed,
                     guint          added,
                     GListModel    *palettes)
{
  g_autofree char *id = ptyxis_profile_dup_palette_id (profile);

  for (guint i = position; i < position + added; i++)
    {
      g_autoptr(PtyxisPalette) palette = g_list_model_get_item (palettes, i);

      if (g_strcmp0 (ptyxis_palette_get_id (palette), id) == 0)
        {
          g_object_notify (G_OBJECT (profile), "palette");
          return;
        }
    }
}

void
apex_profile_follow_palette_files (PtyxisProfile *profile)
{
  g_signal_connect_object (ptyxis_palette_get_all (), "items-changed",
                           G_CALLBACK (palettes_changed_cb), profile, G_CONNECT_SWAPPED);
}
