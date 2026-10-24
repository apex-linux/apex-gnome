/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-format.h"

#include <glib/gi18n.h>
#include <math.h>

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
