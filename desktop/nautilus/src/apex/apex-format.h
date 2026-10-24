/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <glib.h>

G_BEGIN_DECLS

char *apex_format_disk_size (guint64 bytes);
char *apex_format_disk_free (guint64 free_bytes,
                             guint64 total_bytes);
double apex_disk_used_fraction (guint64 free_bytes,
                                guint64 total_bytes);
char *apex_format_item_count (guint       n_items,
                              gboolean    searching,
                              guint       n_selected,
                              const char *selected_name);

G_END_DECLS
