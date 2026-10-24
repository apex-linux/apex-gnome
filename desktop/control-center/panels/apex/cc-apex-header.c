/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <config.h>

#include <adwaita.h>
#include <glib/gi18n.h>
#include <json-glib/json-glib.h>

#include "cc-apex-header.h"

#define MANIFEST_PATH "/usr/share/apex/manifest.json"
#define TILE_SIZE 72

struct _CcApexHeader {
    GtkWidget parent_instance;

    GSettings *background_settings;
    GCancellable *cancellable;

    GtkPicture *wallpaper;
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
load_wallpaper_thread (GTask *task, gpointer source, gpointer task_data, GCancellable *cancellable)
{
    const char *uri = task_data;
    g_autofree char *path = g_filename_from_uri (uri, NULL, NULL);
    g_autoptr(GdkPixbuf) scaled = NULL;
    g_autoptr(GdkPixbuf) pixbuf = NULL;
    g_autoptr(GBytes) bytes = NULL;
    g_autoptr(GError) error = NULL;
    int width, height, size = TILE_SIZE * 3;

    if (path == NULL || gdk_pixbuf_get_file_info (path, &width, &height) == NULL) {
        g_task_return_new_error (task, G_IO_ERROR, G_IO_ERROR_FAILED, "cannot read %s", uri);
        return;
    }

    scaled = gdk_pixbuf_new_from_file_at_scale (path, width >= height ? -1 : size, width >= height ? size : -1,
                                                TRUE, &error);
    if (scaled == NULL) {
        g_task_return_error (task, g_steal_pointer (&error));
        return;
    }
    pixbuf = gdk_pixbuf_new_subpixbuf (scaled, (gdk_pixbuf_get_width (scaled) - size) / 2,
                                       (gdk_pixbuf_get_height (scaled) - size) / 2, size, size);

    bytes = g_bytes_new (gdk_pixbuf_read_pixels (pixbuf),
                         (gsize) gdk_pixbuf_get_rowstride (pixbuf) * (gdk_pixbuf_get_height (pixbuf) - 1) +
                             gdk_pixbuf_get_width (pixbuf) * gdk_pixbuf_get_n_channels (pixbuf));
    g_task_return_pointer (task,
                           gdk_memory_texture_new (gdk_pixbuf_get_width (pixbuf), gdk_pixbuf_get_height (pixbuf),
                                                   gdk_pixbuf_get_has_alpha (pixbuf) ? GDK_MEMORY_R8G8B8A8
                                                                                      : GDK_MEMORY_R8G8B8,
                                                   bytes, gdk_pixbuf_get_rowstride (pixbuf)),
                           g_object_unref);
}

static void
wallpaper_loaded_cb (GObject *source, GAsyncResult *result, gpointer user_data)
{
    g_autoptr(GdkTexture) texture = NULL;
    g_autoptr(GError) error = NULL;

    texture = g_task_propagate_pointer (G_TASK (result), &error);
    if (texture == NULL) {
        if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
            g_debug ("No wallpaper in the header: %s", error->message);
        return;
    }
    gtk_picture_set_paintable (CC_APEX_HEADER (source)->wallpaper, GDK_PAINTABLE (texture));
}

static void
update_wallpaper (CcApexHeader *self)
{
    gboolean dark = adw_style_manager_get_dark (adw_style_manager_get_default ());
    g_autoptr(GTask) task = NULL;

    task = g_task_new (self, self->cancellable, wallpaper_loaded_cb, NULL);
    g_task_set_task_data (task,
                          g_settings_get_string (self->background_settings, dark ? "picture-uri-dark" : "picture-uri"),
                          g_free);
    g_task_run_in_thread (task, load_wallpaper_thread);
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
    g_clear_object (&self->background_settings);
    g_free (self->image_version);
    g_free (self->shell_version);

    G_OBJECT_CLASS (cc_apex_header_parent_class)->finalize (object);
}

static void
cc_apex_header_class_init (CcApexHeaderClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);
    g_autoptr(GtkCssProvider) provider = gtk_css_provider_new ();

    object_class->dispose = cc_apex_header_dispose;
    object_class->finalize = cc_apex_header_finalize;

    gtk_widget_class_set_layout_manager_type (widget_class, GTK_TYPE_BOX_LAYOUT);
    gtk_widget_class_set_css_name (widget_class, "apex-header");

    gtk_css_provider_load_from_resource (provider, "/org/gnome/Settings/apex/apex.css");
    gtk_style_context_add_provider_for_display (gdk_display_get_default (), GTK_STYLE_PROVIDER (provider),
                                                GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

static void
cc_apex_header_init (CcApexHeader *self)
{
    GtkWidget *clamp, *tile, *diamond, *text, *title;

    gtk_orientable_set_orientation (GTK_ORIENTABLE (gtk_widget_get_layout_manager (GTK_WIDGET (self))),
                                    GTK_ORIENTATION_VERTICAL);
    gtk_box_layout_set_spacing (GTK_BOX_LAYOUT (gtk_widget_get_layout_manager (GTK_WIDGET (self))), 14);
    gtk_widget_add_css_class (GTK_WIDGET (self), "card");

    tile = gtk_overlay_new ();
    gtk_widget_add_css_class (tile, "apex-tile");
    gtk_widget_set_overflow (tile, GTK_OVERFLOW_HIDDEN);
    gtk_widget_set_size_request (tile, TILE_SIZE, TILE_SIZE);
    self->wallpaper = GTK_PICTURE (gtk_picture_new ());
    gtk_picture_set_content_fit (self->wallpaper, GTK_CONTENT_FIT_COVER);
    gtk_overlay_set_child (GTK_OVERLAY (tile), GTK_WIDGET (self->wallpaper));
    diamond = gtk_image_new ();
    gtk_widget_add_css_class (diamond, "apex-diamond");
    gtk_widget_set_halign (diamond, GTK_ALIGN_CENTER);
    gtk_widget_set_valign (diamond, GTK_ALIGN_CENTER);
    gtk_overlay_add_overlay (GTK_OVERLAY (tile), diamond);
    clamp = adw_clamp_new ();
    adw_clamp_set_maximum_size (ADW_CLAMP (clamp), TILE_SIZE);
    adw_clamp_set_tightening_threshold (ADW_CLAMP (clamp), TILE_SIZE);
    adw_clamp_set_child (ADW_CLAMP (clamp), tile);
    gtk_widget_set_parent (clamp, GTK_WIDGET (self));

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

    self->background_settings = g_settings_new ("org.gnome.desktop.background");
    g_signal_connect_object (self->background_settings, "changed::picture-uri", G_CALLBACK (update_wallpaper), self,
                             G_CONNECT_SWAPPED);
    g_signal_connect_object (self->background_settings, "changed::picture-uri-dark", G_CALLBACK (update_wallpaper),
                             self, G_CONNECT_SWAPPED);
    g_signal_connect_object (adw_style_manager_get_default (), "notify::dark", G_CALLBACK (update_wallpaper), self,
                             G_CONNECT_SWAPPED);
    update_wallpaper (self);
}
