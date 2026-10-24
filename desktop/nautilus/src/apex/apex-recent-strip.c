/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-recent-strip.h"

#include "apex-format.h"

#include <glib/gi18n.h>

#include "nautilus-file.h"
#include "nautilus-view-info.h"

#define MAX_CARDS 4
#define CARD_ICON_SIZE 36

struct _ApexRecentStrip
{
    GtkWidget parent_instance;

    ApexSlotWatch *watch;
    GAction *enabled;
    GtkWidget *box;
    GtkWidget *cards;
    guint n_cards;
};

G_DEFINE_FINAL_TYPE (ApexRecentStrip, apex_recent_strip, GTK_TYPE_WIDGET)

static gint
newest_first (gconstpointer a,
              gconstpointer b)
{
    GDateTime *ta = gtk_recent_info_get_modified ((GtkRecentInfo *) a);
    GDateTime *tb = gtk_recent_info_get_modified ((GtkRecentInfo *) b);

    return g_date_time_compare (tb, ta);
}

static GList *
newest_existing (void)
{
    GList *items = g_list_sort (gtk_recent_manager_get_items (gtk_recent_manager_get_default ()), newest_first);
    GList *kept = NULL;

    for (GList *l = items; l != NULL; l = l->next)
    {
        GtkRecentInfo *info = l->data;

        if (g_list_length (kept) < MAX_CARDS && gtk_recent_info_is_local (info) && gtk_recent_info_exists (info))
        {
            kept = g_list_append (kept, gtk_recent_info_ref (info));
        }
    }

    g_list_free_full (items, (GDestroyNotify) gtk_recent_info_unref);
    return kept;
}

static void
set_card_icon (NautilusFile *file,
               gpointer      user_data)
{
    GtkImage *image = GTK_IMAGE (user_data);
    g_autoptr (GdkPaintable) icon = nautilus_file_get_icon_paintable (file, CARD_ICON_SIZE,
                                                                      gtk_widget_get_scale_factor (GTK_WIDGET (image)),
                                                                      NAUTILUS_FILE_ICON_FLAGS_USE_THUMBNAILS);

    gtk_image_set_from_paintable (image, icon);
    g_object_unref (image);
}

static char *
card_subtitle (GtkRecentInfo *info,
               GFile         *location)
{
    g_autoptr (GFile) parent = g_file_get_parent (location);
    g_autofree char *folder = parent != NULL ? g_file_get_basename (parent) : g_strdup ("");
    g_autoptr (GDateTime) now = g_date_time_new_now_local ();
    g_autoptr (GDateTime) local = g_date_time_to_local (gtk_recent_info_get_modified (info));
    g_autofree char *day = apex_format_day (local, now);

    if (parent != NULL && g_strcmp0 (g_file_peek_path (parent), g_get_home_dir ()) == 0)
    {
        g_free (folder);
        folder = g_strdup (_("Home"));
    }

    return g_strdup_printf ("%s · %s", folder, day);
}

static void
on_card_clicked (GtkButton *button,
                 GFile     *location)
{
    g_autoptr (GtkFileLauncher) launcher = gtk_file_launcher_new (location);

    gtk_file_launcher_launch (launcher, GTK_WINDOW (gtk_widget_get_root (GTK_WIDGET (button))), NULL, NULL, NULL);
}

static GtkWidget *
card (GtkRecentInfo *info)
{
    g_autoptr (GFile) location = g_file_new_for_uri (gtk_recent_info_get_uri (info));
    NautilusFile *file = nautilus_file_get (location);
    GtkWidget *button = gtk_button_new ();
    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
    GtkWidget *text = gtk_box_new (GTK_ORIENTATION_VERTICAL, 1);
    GtkWidget *image = gtk_image_new_from_gicon (gtk_recent_info_get_gicon (info));
    GtkWidget *name = gtk_label_new (gtk_recent_info_get_display_name (info));
    g_autofree char *subtitle_text = card_subtitle (info, location);
    GtkWidget *subtitle = gtk_label_new (subtitle_text);

    gtk_image_set_pixel_size (GTK_IMAGE (image), CARD_ICON_SIZE);
    nautilus_file_call_when_ready (file, NAUTILUS_ATTRIBUTE_INFO | NAUTILUS_ATTRIBUTE_THUMBNAIL_INFO,
                                   set_card_icon, g_object_ref (image));
    nautilus_file_unref (file);

    gtk_label_set_xalign (GTK_LABEL (name), 0);
    gtk_label_set_ellipsize (GTK_LABEL (name), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class (name, "apex-recent-name");
    gtk_label_set_xalign (GTK_LABEL (subtitle), 0);
    gtk_label_set_ellipsize (GTK_LABEL (subtitle), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class (subtitle, "apex-recent-where");
    gtk_widget_set_valign (text, GTK_ALIGN_CENTER);
    gtk_box_append (GTK_BOX (text), name);
    gtk_box_append (GTK_BOX (text), subtitle);
    gtk_box_append (GTK_BOX (box), image);
    gtk_box_append (GTK_BOX (box), text);

    gtk_button_set_child (GTK_BUTTON (button), box);
    gtk_widget_add_css_class (button, "apex-recent-card");
    gtk_widget_set_tooltip_text (button, gtk_recent_info_get_display_name (info));
    g_signal_connect_data (button, "clicked", G_CALLBACK (on_card_clicked), g_object_ref (location),
                           (GClosureNotify) g_object_unref, G_CONNECT_DEFAULT);
    return button;
}

static void
rebuild_cards (ApexRecentStrip *self)
{
    GList *items = newest_existing ();
    GtkWidget *child;
    guint column = 0;

    while ((child = gtk_widget_get_first_child (self->cards)) != NULL)
    {
        gtk_grid_remove (GTK_GRID (self->cards), child);
    }

    for (GList *l = items; l != NULL; l = l->next, column++)
    {
        gtk_grid_attach (GTK_GRID (self->cards), card (l->data), column, 0, 1, 1);
    }

    self->n_cards = column;
    g_list_free_full (items, (GDestroyNotify) gtk_recent_info_unref);
}

static gboolean
shows_home_grid (ApexRecentStrip *self)
{
    GFile *location = apex_slot_watch_get_location (self->watch);
    g_autoptr (GFile) home = g_file_new_for_path (g_get_home_dir ());

    return location != NULL && g_file_equal (location, home) &&
           apex_slot_watch_get_view_id (self->watch) == NAUTILUS_VIEW_GRID_ID &&
           !apex_slot_watch_is_searching (self->watch);
}

static void
update_visibility (ApexRecentStrip *self)
{
    g_autoptr (GVariant) state = g_action_get_state (self->enabled);

    gtk_widget_set_visible (GTK_WIDGET (self),
                            g_variant_get_boolean (state) && self->n_cards > 0 && shows_home_grid (self));
}

static void
on_recent_changed (ApexRecentStrip *self)
{
    rebuild_cards (self);
    update_visibility (self);
}

static void
apex_recent_strip_dispose (GObject *object)
{
    ApexRecentStrip *self = APEX_RECENT_STRIP (object);

    g_clear_object (&self->watch);
    g_clear_object (&self->enabled);
    g_clear_pointer (&self->box, gtk_widget_unparent);
    G_OBJECT_CLASS (apex_recent_strip_parent_class)->dispose (object);
}

static void
apex_recent_strip_class_init (ApexRecentStripClass *klass)
{
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

    G_OBJECT_CLASS (klass)->dispose = apex_recent_strip_dispose;
    gtk_widget_class_set_layout_manager_type (widget_class, GTK_TYPE_BIN_LAYOUT);
    gtk_widget_class_set_css_name (widget_class, "apex-recent-strip");
}

static GtkWidget *
heading (const char *text)
{
    GtkWidget *label = gtk_label_new (text);

    gtk_label_set_xalign (GTK_LABEL (label), 0);
    gtk_widget_add_css_class (label, "apex-recent-heading");
    return label;
}

static void
apex_recent_strip_init (ApexRecentStrip *self)
{
    self->box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_parent (self->box, GTK_WIDGET (self));

    self->cards = gtk_grid_new ();
    gtk_grid_set_column_homogeneous (GTK_GRID (self->cards), TRUE);
    gtk_grid_set_column_spacing (GTK_GRID (self->cards), 10);

    gtk_box_append (GTK_BOX (self->box), heading (_("Recent")));
    gtk_box_append (GTK_BOX (self->box), self->cards);
    gtk_box_append (GTK_BOX (self->box), heading (_("Folders")));
}

GtkWidget *
apex_recent_strip_new (ApexSlotWatch *watch,
                       GAction       *enabled)
{
    ApexRecentStrip *self = g_object_new (APEX_TYPE_RECENT_STRIP, NULL);

    self->watch = g_object_ref (watch);
    self->enabled = g_object_ref (enabled);
    g_signal_connect_object (watch, "content-changed", G_CALLBACK (update_visibility), self, G_CONNECT_SWAPPED);
    g_signal_connect_object (enabled, "notify::state", G_CALLBACK (update_visibility), self, G_CONNECT_SWAPPED);
    g_signal_connect_object (gtk_recent_manager_get_default (), "changed", G_CALLBACK (on_recent_changed), self,
                             G_CONNECT_SWAPPED);
    on_recent_changed (self);
    return GTK_WIDGET (self);
}
