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

typedef enum
{
    APEX_KIND_OTHER = 0,
    APEX_KIND_FOLDER = 1 << 0,
    APEX_KIND_DOCUMENT = 1 << 1,
    APEX_KIND_IMAGE = 1 << 2,
    APEX_KIND_MEDIA = 1 << 3,
} ApexKind;

ApexKind apex_kind_of (const char *content_type,
                       gboolean    is_directory);
char *apex_format_day (GDateTime *when,
                       GDateTime *now);
char *apex_format_home_path (const char *path,
                             const char *home);

G_END_DECLS
