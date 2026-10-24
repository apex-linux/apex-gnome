/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <config.h>

#include <adwaita.h>

#include "cc-apex-tile.h"

#define TILE_SIZE 72

struct _CcApexTile {
    GtkWidget parent_instance;

    GSettings *background_settings;
    GCancellable *cancellable;

    GtkPicture *wallpaper;
    GtkImage *badge;
};

G_DEFINE_FINAL_TYPE (CcApexTile, cc_apex_tile, GTK_TYPE_WIDGET)

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
    gtk_picture_set_paintable (CC_APEX_TILE (source)->wallpaper, GDK_PAINTABLE (texture));
}

static void
update_wallpaper (CcApexTile *self)
{
    gboolean dark = adw_style_manager_get_dark (adw_style_manager_get_default ());
    g_autoptr(GTask) task = NULL;

    task = g_task_new (self, self->cancellable, wallpaper_loaded_cb, NULL);
    g_task_set_task_data (task,
                          g_settings_get_string (self->background_settings, dark ? "picture-uri-dark" : "picture-uri"),
                          g_free);
    g_task_run_in_thread (task, load_wallpaper_thread);
}

void
cc_apex_tile_set_badge (CcApexTile *self, const char *icon_name, const char *tone)
{
    static const char *const tones[] = { "good", "accent", "warning", "error" };

    gtk_widget_set_visible (GTK_WIDGET (self->badge), icon_name != NULL);
    if (icon_name)
        gtk_widget_add_css_class (GTK_WIDGET (self), "badged");
    else
        gtk_widget_remove_css_class (GTK_WIDGET (self), "badged");
    gtk_image_set_from_icon_name (self->badge, icon_name);
    for (guint i = 0; i < G_N_ELEMENTS (tones); i++)
        gtk_widget_remove_css_class (GTK_WIDGET (self->badge), tones[i]);
    if (tone)
        gtk_widget_add_css_class (GTK_WIDGET (self->badge), tone);
}

static void
cc_apex_tile_dispose (GObject *object)
{
    CcApexTile *self = CC_APEX_TILE (object);
    GtkWidget *child;

    g_cancellable_cancel (self->cancellable);
    while ((child = gtk_widget_get_first_child (GTK_WIDGET (self))))
        gtk_widget_unparent (child);

    G_OBJECT_CLASS (cc_apex_tile_parent_class)->dispose (object);
}

static void
cc_apex_tile_finalize (GObject *object)
{
    CcApexTile *self = CC_APEX_TILE (object);

    g_clear_object (&self->cancellable);
    g_clear_object (&self->background_settings);

    G_OBJECT_CLASS (cc_apex_tile_parent_class)->finalize (object);
}

static void
cc_apex_tile_class_init (CcApexTileClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);
    g_autoptr(GtkCssProvider) provider = gtk_css_provider_new ();

    object_class->dispose = cc_apex_tile_dispose;
    object_class->finalize = cc_apex_tile_finalize;

    gtk_widget_class_set_layout_manager_type (widget_class, GTK_TYPE_BIN_LAYOUT);
    gtk_widget_class_set_css_name (widget_class, "apex-tile");

    gtk_css_provider_load_from_resource (provider, "/org/gnome/Settings/apex/apex.css");
    gtk_style_context_add_provider_for_display (gdk_display_get_default (), GTK_STYLE_PROVIDER (provider),
                                                GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

static void
cc_apex_tile_init (CcApexTile *self)
{
    GtkWidget *clamp, *frame, *overlay, *diamond;

    gtk_widget_set_halign (GTK_WIDGET (self), GTK_ALIGN_CENTER);

    frame = gtk_overlay_new ();
    gtk_widget_add_css_class (frame, "frame");
    gtk_widget_set_overflow (frame, GTK_OVERFLOW_HIDDEN);
    gtk_widget_set_size_request (frame, TILE_SIZE, TILE_SIZE);
    self->wallpaper = GTK_PICTURE (gtk_picture_new ());
    gtk_picture_set_content_fit (self->wallpaper, GTK_CONTENT_FIT_COVER);
    gtk_overlay_set_child (GTK_OVERLAY (frame), GTK_WIDGET (self->wallpaper));
    diamond = gtk_image_new ();
    gtk_widget_add_css_class (diamond, "diamond");
    gtk_widget_set_halign (diamond, GTK_ALIGN_CENTER);
    gtk_widget_set_valign (diamond, GTK_ALIGN_CENTER);
    gtk_overlay_add_overlay (GTK_OVERLAY (frame), diamond);

    clamp = adw_clamp_new ();
    adw_clamp_set_maximum_size (ADW_CLAMP (clamp), TILE_SIZE);
    adw_clamp_set_tightening_threshold (ADW_CLAMP (clamp), TILE_SIZE);
    adw_clamp_set_child (ADW_CLAMP (clamp), frame);

    overlay = gtk_overlay_new ();
    gtk_overlay_set_child (GTK_OVERLAY (overlay), clamp);
    self->badge = GTK_IMAGE (gtk_image_new ());
    gtk_widget_add_css_class (GTK_WIDGET (self->badge), "badge");
    gtk_widget_set_halign (GTK_WIDGET (self->badge), GTK_ALIGN_END);
    gtk_widget_set_valign (GTK_WIDGET (self->badge), GTK_ALIGN_END);
    gtk_widget_set_visible (GTK_WIDGET (self->badge), FALSE);
    gtk_overlay_add_overlay (GTK_OVERLAY (overlay), GTK_WIDGET (self->badge));
    gtk_widget_set_parent (overlay, GTK_WIDGET (self));

    self->cancellable = g_cancellable_new ();
    self->background_settings = g_settings_new ("org.gnome.desktop.background");
    g_signal_connect_object (self->background_settings, "changed::picture-uri", G_CALLBACK (update_wallpaper), self,
                             G_CONNECT_SWAPPED);
    g_signal_connect_object (self->background_settings, "changed::picture-uri-dark", G_CALLBACK (update_wallpaper),
                             self, G_CONNECT_SWAPPED);
    g_signal_connect_object (adw_style_manager_get_default (), "notify::dark", G_CALLBACK (update_wallpaper), self,
                             G_CONNECT_SWAPPED);
    update_wallpaper (self);
}
