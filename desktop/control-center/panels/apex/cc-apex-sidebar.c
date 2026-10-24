/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <config.h>

#include <json-glib/json-glib.h>
#include <string.h>

#include "cc-apex-sidebar.h"

#define TILES_PATH "/org/gnome/Settings/apex/settings-tiles.json"

static void
add_provider (GtkCssProvider *provider)
{
    gtk_style_context_add_provider_for_display (gdk_display_get_default (), GTK_STYLE_PROVIDER (provider),
                                                GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

static gboolean
is_colour (const char *value)
{
    if (value == NULL || strlen (value) != 7 || value[0] != '#')
        return FALSE;
    for (int i = 1; i < 7; i++)
        if (!g_ascii_isxdigit (value[i]))
            return FALSE;
    return TRUE;
}

/* settings-tiles.json is the one table of tile colours; the shell's Spotlight mirrors it. */
static char *
tiles_css (void)
{
    g_autoptr(GBytes) bytes = g_resources_lookup_data (TILES_PATH, G_RESOURCE_LOOKUP_FLAGS_NONE, NULL);
    g_autoptr(JsonParser) parser = json_parser_new ();
    g_autoptr(GError) error = NULL;
    g_autoptr(GList) members = NULL;
    GString *css = g_string_new (NULL);
    JsonObject *table;

    if (bytes == NULL ||
        !json_parser_load_from_data (parser, g_bytes_get_data (bytes, NULL), g_bytes_get_size (bytes), &error) ||
        !JSON_NODE_HOLDS_OBJECT (json_parser_get_root (parser))) {
        g_warning ("Cannot read %s: %s", TILES_PATH, error ? error->message : "not an object");
        return g_string_free (css, FALSE);
    }

    table = json_node_get_object (json_parser_get_root (parser));
    members = json_object_get_members (table);
    for (GList *l = members; l; l = l->next) {
        const char *id = l->data;
        const char *value = json_object_get_string_member_with_default (table, id, NULL);

        if (g_strcmp0 (value, "accent") == 0)
            value = "var(--accent-bg-color)";
        else if (!is_colour (value)) {
            g_warning ("%s: %s has no tile colour", TILES_PATH, id);
            continue;
        }
        g_string_append_printf (css, "image.apex-tile.apex-tile-%s { background-color: %s; }\n", id, value);
    }
    return g_string_free (css, FALSE);
}

void
cc_apex_load_css (void)
{
    static gsize loaded = 0;

    if (g_once_init_enter (&loaded)) {
        g_autoptr(GtkCssProvider) sheet = gtk_css_provider_new ();
        g_autoptr(GtkCssProvider) tiles = gtk_css_provider_new ();
        g_autofree char *css = tiles_css ();

        gtk_css_provider_load_from_resource (sheet, "/org/gnome/Settings/apex/apex.css");
        add_provider (sheet);
        gtk_css_provider_load_from_string (tiles, css);
        add_provider (tiles);
        g_once_init_leave (&loaded, 1);
    }
}

void
cc_apex_sidebar_tile (GtkWidget *icon, const char *panel_id)
{
    g_autofree char *class = g_strdup_printf ("apex-tile-%s", panel_id);

    cc_apex_load_css ();
    gtk_widget_add_css_class (icon, "apex-tile");
    gtk_widget_add_css_class (icon, class);
}
