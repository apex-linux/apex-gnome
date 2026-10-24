/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-format.h"

#include <glib/gi18n.h>
#include <math.h>
#include <string.h>

static const char * const size_units[] = { "B", "kB", "MB", "GB", "TB", "PB" };

char *
apex_format_disk_size (guint64 bytes)
{
    double value = bytes;
    guint unit = 0;

    while (value >= 999.5 && unit + 1 < G_N_ELEMENTS (size_units))
    {
        value /= 1000;
        unit++;
    }

    if (unit == 0 || value >= 9.95 || fabs (value - round (value)) < 0.05)
    {
        return g_strdup_printf ("%.0f %s", value, size_units[unit]);
    }

    return g_strdup_printf ("%.1f %s", value, size_units[unit]);
}

char *
apex_format_disk_free (guint64 free_bytes,
                       guint64 total_bytes)
{
    g_autofree char *free_text = apex_format_disk_size (MIN (free_bytes, total_bytes));
    g_autofree char *total_text = apex_format_disk_size (total_bytes);

    /* Translators: the free space and the size of the disk holding the home folder, "588 GB free of 1 TB". */
    return g_strdup_printf (_("%s free of %s"), free_text, total_text);
}

double
apex_disk_used_fraction (guint64 free_bytes,
                         guint64 total_bytes)
{
    if (total_bytes == 0)
    {
        return 0.0;
    }

    return (double) (total_bytes - MIN (free_bytes, total_bytes)) / total_bytes;
}

char *
apex_format_item_count (guint       n_items,
                        gboolean    searching,
                        guint       n_selected,
                        const char *selected_name)
{
    g_autofree char *count = NULL;

    if (searching)
    {
        count = g_strdup_printf (ngettext ("%u result", "%u results", n_items), n_items);
    }
    else
    {
        count = g_strdup_printf (ngettext ("%u item", "%u items", n_items), n_items);
    }

    if (n_selected == 1 && selected_name != NULL)
    {
        return g_strdup_printf (_("%s · “%s” selected"), count, selected_name);
    }

    if (n_selected > 1)
    {
        return g_strdup_printf (ngettext ("%s · %u selected", "%s · %u selected", n_selected),
                                count, n_selected);
    }

    return g_steal_pointer (&count);
}

static const char * const document_types[] = {
    "application/pdf",
    "application/rtf",
    "application/msword",
    "application/vnd.ms-excel",
    "application/vnd.ms-powerpoint",
    "application/json",
    "application/javascript",
    "application/xml",
    "application/x-shellscript",
    "application/x-yaml",
    "application/toml",
};

static const char * const document_prefixes[] = {
    "text/",
    "application/vnd.oasis.opendocument.",
    "application/vnd.openxmlformats-officedocument.",
};

ApexKind
apex_kind_of (const char *content_type,
              gboolean    is_directory)
{
    if (is_directory)
    {
        return APEX_KIND_FOLDER;
    }

    if (content_type == NULL)
    {
        return APEX_KIND_OTHER;
    }

    if (g_str_has_prefix (content_type, "image/"))
    {
        return APEX_KIND_IMAGE;
    }

    if (g_str_has_prefix (content_type, "audio/") || g_str_has_prefix (content_type, "video/"))
    {
        return APEX_KIND_MEDIA;
    }

    for (guint i = 0; i < G_N_ELEMENTS (document_prefixes); i++)
    {
        if (g_str_has_prefix (content_type, document_prefixes[i]))
        {
            return APEX_KIND_DOCUMENT;
        }
    }

    for (guint i = 0; i < G_N_ELEMENTS (document_types); i++)
    {
        if (g_str_equal (content_type, document_types[i]))
        {
            return APEX_KIND_DOCUMENT;
        }
    }

    return APEX_KIND_OTHER;
}

char *
apex_format_day (GDateTime *when,
                 GDateTime *now)
{
    g_autoptr (GDateTime) yesterday = g_date_time_add_days (now, -1);
    gint year, month, day;

    g_date_time_get_ymd (when, &year, &month, &day);
    if (year == g_date_time_get_year (now) && g_date_time_get_day_of_year (when) == g_date_time_get_day_of_year (now))
    {
        return g_strdup (_("Today"));
    }

    if (year == g_date_time_get_year (yesterday) &&
        g_date_time_get_day_of_year (when) == g_date_time_get_day_of_year (yesterday))
    {
        return g_strdup (_("Yesterday"));
    }

    /* Translators: a day this year, "Oct 18"; see the GDateTime format. */
    return g_date_time_format (when, year == g_date_time_get_year (now) ? _("%b %-d") : _("%b %-d, %Y"));
}

char *
apex_format_home_path (const char *path,
                       const char *home)
{
    gsize home_length = strlen (home);

    if (g_str_has_prefix (path, home) && (path[home_length] == '/' || path[home_length] == '\0'))
    {
        return g_strconcat ("~", path + home_length, NULL);
    }

    return g_strdup (path);
}
