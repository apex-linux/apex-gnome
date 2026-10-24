/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-disk-footer.h"

#include "apex-format.h"

#include <glib/gi18n.h>

#define REFRESH_SECONDS 30
#define FILESYSTEM_ATTRIBUTES G_FILE_ATTRIBUTE_FILESYSTEM_SIZE "," G_FILE_ATTRIBUTE_FILESYSTEM_FREE

struct _ApexDiskFooter
{
    GtkBox parent_instance;

    GtkWidget *name;
    GtkWidget *meter;
    GtkWidget *free_space;
    GCancellable *cancellable;
    guint refresh_id;
};

G_DEFINE_FINAL_TYPE (ApexDiskFooter, apex_disk_footer, GTK_TYPE_BOX)

static void
on_filesystem_info (GObject      *source,
                    GAsyncResult *result,
                    gpointer      user_data)
{
    g_autoptr (GFileInfo) info = g_file_query_filesystem_info_finish (G_FILE (source), result, NULL);
    ApexDiskFooter *self;
    guint64 total;
    guint64 free_bytes;
    g_autofree char *text = NULL;

    if (info == NULL || !g_file_info_has_attribute (info, G_FILE_ATTRIBUTE_FILESYSTEM_SIZE))
    {
        return;
    }

    self = APEX_DISK_FOOTER (user_data);
    total = g_file_info_get_attribute_uint64 (info, G_FILE_ATTRIBUTE_FILESYSTEM_SIZE);
    free_bytes = g_file_info_get_attribute_uint64 (info, G_FILE_ATTRIBUTE_FILESYSTEM_FREE);
    text = apex_format_disk_free (free_bytes, total);

    gtk_label_set_label (GTK_LABEL (self->free_space), text);
    gtk_level_bar_set_value (GTK_LEVEL_BAR (self->meter), apex_disk_used_fraction (free_bytes, total));
    gtk_widget_set_visible (self->meter, total > 0);
    gtk_widget_set_visible (self->free_space, total > 0);
}

void
apex_disk_footer_refresh (ApexDiskFooter *self)
{
    g_autoptr (GFile) home = g_file_new_for_path (g_get_home_dir ());

    g_cancellable_cancel (self->cancellable);
    g_set_object (&self->cancellable, g_cancellable_new ());
    g_file_query_filesystem_info_async (home, FILESYSTEM_ATTRIBUTES, G_PRIORITY_DEFAULT,
                                        self->cancellable, on_filesystem_info, self);
}

static gboolean
on_refresh_timeout (gpointer user_data)
{
    apex_disk_footer_refresh (APEX_DISK_FOOTER (user_data));
    return G_SOURCE_CONTINUE;
}

static void
apex_disk_footer_map (GtkWidget *widget)
{
    ApexDiskFooter *self = APEX_DISK_FOOTER (widget);

    GTK_WIDGET_CLASS (apex_disk_footer_parent_class)->map (widget);
    apex_disk_footer_refresh (self);
    self->refresh_id = g_timeout_add_seconds (REFRESH_SECONDS, on_refresh_timeout, self);
}

static void
apex_disk_footer_unmap (GtkWidget *widget)
{
    ApexDiskFooter *self = APEX_DISK_FOOTER (widget);

    g_clear_handle_id (&self->refresh_id, g_source_remove);
    GTK_WIDGET_CLASS (apex_disk_footer_parent_class)->unmap (widget);
}

static void
apex_disk_footer_dispose (GObject *object)
{
    ApexDiskFooter *self = APEX_DISK_FOOTER (object);

    g_cancellable_cancel (self->cancellable);
    g_clear_object (&self->cancellable);
    g_clear_handle_id (&self->refresh_id, g_source_remove);
    G_OBJECT_CLASS (apex_disk_footer_parent_class)->dispose (object);
}

static void
apex_disk_footer_class_init (ApexDiskFooterClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

    object_class->dispose = apex_disk_footer_dispose;
    widget_class->map = apex_disk_footer_map;
    widget_class->unmap = apex_disk_footer_unmap;
    gtk_widget_class_set_css_name (widget_class, "apex-disk-footer");
}

static void
apex_disk_footer_init (ApexDiskFooter *self)
{
    GtkWidget *heading = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
    g_autofree char *os_name = g_get_os_info (G_OS_INFO_KEY_NAME);

    gtk_orientable_set_orientation (GTK_ORIENTABLE (self), GTK_ORIENTATION_VERTICAL);
    gtk_box_set_spacing (GTK_BOX (self), 6);

    self->name = gtk_label_new (os_name);
    gtk_label_set_xalign (GTK_LABEL (self->name), 0);
    gtk_label_set_ellipsize (GTK_LABEL (self->name), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class (self->name, "apex-disk-name");
    gtk_box_append (GTK_BOX (heading), gtk_image_new_from_icon_name ("drive-harddisk-symbolic"));
    gtk_box_append (GTK_BOX (heading), self->name);
    gtk_box_append (GTK_BOX (self), heading);

    self->meter = gtk_level_bar_new_for_interval (0.0, 1.0);
    gtk_level_bar_remove_offset_value (GTK_LEVEL_BAR (self->meter), GTK_LEVEL_BAR_OFFSET_LOW);
    gtk_level_bar_remove_offset_value (GTK_LEVEL_BAR (self->meter), GTK_LEVEL_BAR_OFFSET_HIGH);
    gtk_level_bar_remove_offset_value (GTK_LEVEL_BAR (self->meter), GTK_LEVEL_BAR_OFFSET_FULL);
    gtk_accessible_update_property (GTK_ACCESSIBLE (self->meter),
                                    GTK_ACCESSIBLE_PROPERTY_LABEL, _("Disk usage"), -1);
    gtk_widget_set_visible (self->meter, FALSE);
    gtk_box_append (GTK_BOX (self), self->meter);

    self->free_space = gtk_label_new (NULL);
    gtk_label_set_xalign (GTK_LABEL (self->free_space), 0);
    gtk_widget_add_css_class (self->free_space, "apex-disk-free");
    gtk_widget_set_visible (self->free_space, FALSE);
    gtk_box_append (GTK_BOX (self), self->free_space);
}

GtkWidget *
apex_disk_footer_new (void)
{
    return g_object_new (APEX_TYPE_DISK_FOOTER, NULL);
}
