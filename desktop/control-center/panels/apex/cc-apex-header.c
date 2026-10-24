/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <config.h>

#include <adwaita.h>
#include <glib/gi18n.h>
#include <json-glib/json-glib.h>

#include "cc-apex-header.h"
#include "cc-apex-tile.h"

#define MANIFEST_PATH "/usr/share/apex/manifest.json"

struct _CcApexHeader {
    GtkWidget parent_instance;

    GCancellable *cancellable;

    GtkLabel *versions_label;

    char *image_version;
    char *shell_version;
};

G_DEFINE_FINAL_TYPE (CcApexHeader, cc_apex_header, GTK_TYPE_WIDGET)

char *
cc_apex_header_format_versions (const char *image_version, const char *shell_version, const char *session_type,
                                const char *os_name, const char *os_version)
{
    g_autoptr(GPtrArray) parts = g_ptr_array_new_with_free_func (g_free);

    if (image_version && *image_version)
        g_ptr_array_add (parts, g_strdup_printf (_("Version %s"), image_version));

    if (shell_version && *shell_version) {
        if (g_strcmp0 (session_type, "wayland") == 0)
            g_ptr_array_add (parts, g_strdup_printf (_("GNOME Shell %s on Wayland"), shell_version));
        else if (g_strcmp0 (session_type, "x11") == 0)
            g_ptr_array_add (parts, g_strdup_printf (_("GNOME Shell %s on X11"), shell_version));
        else
            g_ptr_array_add (parts, g_strdup_printf (_("GNOME Shell %s"), shell_version));
    }

    if (os_name && *os_name)
        g_ptr_array_add (parts, os_version && *os_version ? g_strdup_printf ("%s %s", os_name, os_version)
                                                          : g_strdup (os_name));

    g_ptr_array_add (parts, NULL);
    return g_strjoinv (" · ", (char **) parts->pdata);
}

static char *
read_image_version (void)
{
    g_autoptr(JsonParser) parser = json_parser_new ();
    g_autoptr(GError) error = NULL;
    JsonNode *root;
    JsonObject *manifest;

    if (!json_parser_load_from_mapped_file (parser, MANIFEST_PATH, &error)) {
        if (!g_error_matches (error, G_FILE_ERROR, G_FILE_ERROR_NOENT))
            g_warning ("Cannot read %s: %s", MANIFEST_PATH, error->message);
        return NULL;
    }

    root = json_parser_get_root (parser);
    manifest = JSON_NODE_HOLDS_OBJECT (root) ? json_node_get_object (root) : NULL;
    if (manifest == NULL || !json_object_has_member (manifest, "version"))
        return NULL;
    return g_strdup (json_object_get_string_member_with_default (manifest, "version", NULL));
}

static void
update_versions (CcApexHeader *self)
{
    g_autofree char *os_name = g_get_os_info (G_OS_INFO_KEY_NAME);
    g_autofree char *os_version = g_get_os_info (G_OS_INFO_KEY_VERSION_ID);
    g_autofree char *text = NULL;

    text = cc_apex_header_format_versions (self->image_version, self->shell_version,
                                           g_getenv ("XDG_SESSION_TYPE"), os_name, os_version);
    gtk_label_set_label (self->versions_label, text);
}

static void
shell_version_cb (GObject *source, GAsyncResult *result, gpointer user_data)
{
    g_autoptr(GVariant) reply = NULL;
    g_autoptr(GVariant) value = NULL;
    g_autoptr(GError) error = NULL;
    CcApexHeader *self;

    reply = g_dbus_connection_call_finish (G_DBUS_CONNECTION (source), result, &error);
    if (reply == NULL) {
        if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
            g_warning ("Cannot read the GNOME Shell version: %s", error->message);
        return;
    }

    self = CC_APEX_HEADER (user_data);
    g_variant_get (reply, "(v)", &value);
    if (g_variant_is_of_type (value, G_VARIANT_TYPE_STRING)) {
        g_free (self->shell_version);
        self->shell_version = g_variant_dup_string (value, NULL);
        update_versions (self);
    }
}

static void
request_shell_version (CcApexHeader *self)
{
    g_autoptr(GDBusConnection) bus = g_bus_get_sync (G_BUS_TYPE_SESSION, NULL, NULL);

    if (bus == NULL)
        return;
    g_dbus_connection_call (bus, "org.gnome.Shell", "/org/gnome/Shell", "org.freedesktop.DBus.Properties", "Get",
                            g_variant_new ("(ss)", "org.gnome.Shell", "ShellVersion"), G_VARIANT_TYPE ("(v)"),
                            G_DBUS_CALL_FLAGS_NO_AUTO_START, -1, self->cancellable, shell_version_cb, self);
}

static void
cc_apex_header_dispose (GObject *object)
{
    CcApexHeader *self = CC_APEX_HEADER (object);
    GtkWidget *child;

    g_cancellable_cancel (self->cancellable);
    while ((child = gtk_widget_get_first_child (GTK_WIDGET (self))))
        gtk_widget_unparent (child);

    G_OBJECT_CLASS (cc_apex_header_parent_class)->dispose (object);
}

static void
cc_apex_header_finalize (GObject *object)
{
    CcApexHeader *self = CC_APEX_HEADER (object);

    g_clear_object (&self->cancellable);
    g_free (self->image_version);
    g_free (self->shell_version);

    G_OBJECT_CLASS (cc_apex_header_parent_class)->finalize (object);
}

static void
cc_apex_header_class_init (CcApexHeaderClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);
    object_class->dispose = cc_apex_header_dispose;
    object_class->finalize = cc_apex_header_finalize;

    gtk_widget_class_set_layout_manager_type (widget_class, GTK_TYPE_BOX_LAYOUT);
    gtk_widget_class_set_css_name (widget_class, "apex-header");
}

static void
cc_apex_header_init (CcApexHeader *self)
{
    GtkWidget *text, *title;

    gtk_orientable_set_orientation (GTK_ORIENTABLE (gtk_widget_get_layout_manager (GTK_WIDGET (self))),
                                    GTK_ORIENTATION_VERTICAL);
    gtk_box_layout_set_spacing (GTK_BOX_LAYOUT (gtk_widget_get_layout_manager (GTK_WIDGET (self))), 14);
    gtk_widget_add_css_class (GTK_WIDGET (self), "card");
    gtk_widget_set_parent (GTK_WIDGET (g_object_new (CC_TYPE_APEX_TILE, NULL)), GTK_WIDGET (self));

    text = gtk_box_new (GTK_ORIENTATION_VERTICAL, 3);
    title = gtk_label_new (_("Apex Desktop"));
    gtk_widget_add_css_class (title, "apex-title");
    gtk_accessible_update_property (GTK_ACCESSIBLE (title), GTK_ACCESSIBLE_PROPERTY_LEVEL, 1, -1);
    gtk_box_append (GTK_BOX (text), title);
    self->versions_label = GTK_LABEL (gtk_label_new (NULL));
    gtk_label_set_wrap (self->versions_label, TRUE);
    gtk_label_set_justify (self->versions_label, GTK_JUSTIFY_CENTER);
    gtk_label_set_selectable (self->versions_label, TRUE);
    gtk_widget_add_css_class (GTK_WIDGET (self->versions_label), "apex-versions");
    gtk_widget_add_css_class (GTK_WIDGET (self->versions_label), "dim-label");
    gtk_box_append (GTK_BOX (text), GTK_WIDGET (self->versions_label));
    gtk_widget_set_parent (text, GTK_WIDGET (self));

    self->cancellable = g_cancellable_new ();
    self->image_version = read_image_version ();
    update_versions (self);
    request_shell_version (self);
}
