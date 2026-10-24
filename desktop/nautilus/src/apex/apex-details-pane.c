/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-details-pane.h"

#include "apex-format.h"

#include <adwaita.h>
#include <glib/gi18n.h>

#include "nautilus-file.h"
#include "nautilus-tag-manager.h"

#define PREVIEW_ICON_SIZE 112

struct _ApexDetailsPane
{
    GtkWidget parent_instance;

    ApexSlotWatch *watch;
    GSignalGroup *file_signals;
    GtkWidget *box;
    GtkWidget *preview;
    GtkWidget *name;
    GtkWidget *kind;
    GtkWidget *size;
    GtkWidget *modified;
    GtkWidget *location;
    GtkWidget *open;
    GtkWidget *star;
    gboolean showing_selection;
};

G_DEFINE_FINAL_TYPE (ApexDetailsPane, apex_details_pane, GTK_TYPE_WIDGET)

static NautilusFile *
shown_file (ApexDetailsPane *self,
            gboolean        *is_selection)
{
    NautilusWindowSlot *slot = apex_slot_watch_get_slot (self->watch);
    GList *selection = slot != NULL ? nautilus_window_slot_get_selection (slot) : NULL;
    GFile *location = apex_slot_watch_get_location (self->watch);

    *is_selection = selection != NULL;
    if (selection != NULL)
    {
        return nautilus_file_ref (selection->data);
    }

    return location != NULL ? nautilus_file_get (location) : NULL;
}

static char *
location_text (NautilusFile *file)
{
    g_autoptr (GFile) location = nautilus_file_get_location (file);
    g_autofree char *path = g_file_get_path (location);

    if (path == NULL)
    {
        return g_file_get_uri (location);
    }

    return apex_format_home_path (path, g_get_home_dir ());
}

static char *
size_text (ApexDetailsPane *self,
           NautilusFile    *file)
{
    NautilusViewModel *model = apex_slot_watch_get_model (self->watch);

    if (!self->showing_selection && model != NULL)
    {
        return apex_format_item_count (g_list_model_get_n_items (G_LIST_MODEL (model)),
                                       apex_slot_watch_is_searching (self->watch), 0, NULL);
    }

    return nautilus_file_get_string_attribute (file, "size");
}

static gboolean
is_starred (NautilusFile *file)
{
    g_autofree char *uri = nautilus_file_get_uri (file);

    return nautilus_tag_manager_file_is_starred (nautilus_tag_manager_get (), uri);
}

static void
update (ApexDetailsPane *self)
{
    g_autoptr (NautilusFile) file = shown_file (self, &self->showing_selection);
    g_autoptr (GdkPaintable) icon = NULL;
    g_autofree char *kind = NULL;
    g_autofree char *size = NULL;
    g_autofree char *modified = NULL;
    g_autofree char *location = NULL;
    gboolean starred;

    g_signal_group_set_target (self->file_signals, file);
    gtk_widget_set_visible (self->box, file != NULL);
    if (file == NULL)
    {
        return;
    }

    icon = nautilus_file_get_icon_paintable (file, PREVIEW_ICON_SIZE, gtk_widget_get_scale_factor (GTK_WIDGET (self)),
                                             NAUTILUS_FILE_ICON_FLAGS_USE_THUMBNAILS);
    kind = nautilus_file_get_string_attribute (file, "type");
    size = size_text (self, file);
    modified = nautilus_file_get_string_attribute (file, "date_modified");
    location = location_text (file);
    starred = is_starred (file);

    gtk_image_set_from_paintable (GTK_IMAGE (self->preview), icon);
    gtk_label_set_label (GTK_LABEL (self->name),
                         nautilus_file_is_home (file) ? _("Home") : nautilus_file_get_display_name (file));
    gtk_label_set_label (GTK_LABEL (self->kind), kind);
    gtk_label_set_label (GTK_LABEL (self->size), size != NULL ? size : "—");
    gtk_label_set_label (GTK_LABEL (self->modified), modified != NULL ? modified : "—");
    gtk_label_set_label (GTK_LABEL (self->location), location);
    gtk_widget_set_visible (self->open, self->showing_selection);
    gtk_button_set_icon_name (GTK_BUTTON (self->star), starred ? "starred-symbolic" : "non-starred-symbolic");
    gtk_widget_set_tooltip_text (self->star, starred ? _("Unstar") : _("Star"));
    gtk_widget_set_visible (self->star, self->showing_selection || nautilus_file_is_directory (file));
}

static void
on_open (ApexDetailsPane *self)
{
    gtk_widget_activate_action (GTK_WIDGET (self), "view.open-with-default-application", NULL);
}

static void
on_star (ApexDetailsPane *self)
{
    gboolean is_selection;
    g_autoptr (NautilusFile) file = shown_file (self, &is_selection);
    gboolean starred = file != NULL && is_starred (file);

    if (is_selection)
    {
        gtk_widget_activate_action (GTK_WIDGET (self), starred ? "view.unstar" : "view.star", NULL);
    }
    else
    {
        gtk_widget_activate_action (GTK_WIDGET (self),
                                    starred ? "slot.unstar-current-directory" : "slot.star-current-directory",
                                    NULL);
    }
}

static GtkWidget *
fact_label (const char *css_class)
{
    GtkWidget *label = gtk_label_new (NULL);

    gtk_label_set_xalign (GTK_LABEL (label), 0);
    gtk_label_set_wrap (GTK_LABEL (label), TRUE);
    gtk_label_set_wrap_mode (GTK_LABEL (label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_selectable (GTK_LABEL (label), TRUE);
    gtk_widget_set_hexpand (label, TRUE);
    if (css_class != NULL)
    {
        gtk_widget_add_css_class (label, css_class);
    }

    return label;
}

static GtkWidget *
facts (ApexDetailsPane *self)
{
    GtkWidget *grid = gtk_grid_new ();
    const char *names[] = { N_("Size"), N_("Modified"), N_("Location") };
    GtkWidget **values[] = { &self->size, &self->modified, &self->location };

    gtk_widget_add_css_class (grid, "apex-details-facts");
    for (guint row = 0; row < G_N_ELEMENTS (names); row++)
    {
        GtkWidget *name = gtk_label_new (_(names[row]));

        gtk_label_set_xalign (GTK_LABEL (name), 0);
        gtk_label_set_yalign (GTK_LABEL (name), 0);
        gtk_widget_add_css_class (name, "apex-details-key");
        *values[row] = fact_label (row == 2 ? "apex-details-path" : NULL);
        gtk_grid_attach (GTK_GRID (grid), name, 0, row, 1, 1);
        gtk_grid_attach (GTK_GRID (grid), *values[row], 1, row, 1, 1);
    }

    return grid;
}

static GtkWidget *
actions (ApexDetailsPane *self)
{
    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);

    gtk_widget_add_css_class (box, "apex-details-actions");
    gtk_widget_set_vexpand (box, TRUE);
    gtk_widget_set_valign (box, GTK_ALIGN_END);

    self->open = gtk_button_new_with_label (_("Open"));
    gtk_widget_set_hexpand (self->open, TRUE);
    gtk_widget_add_css_class (self->open, "suggested-action");
    gtk_widget_add_css_class (self->open, "pill");
    g_signal_connect_swapped (self->open, "clicked", G_CALLBACK (on_open), self);
    gtk_box_append (GTK_BOX (box), self->open);

    self->star = gtk_button_new_from_icon_name ("non-starred-symbolic");
    gtk_widget_add_css_class (self->star, "circular");
    gtk_widget_set_halign (self->star, GTK_ALIGN_END);
    gtk_widget_set_hexpand (self->star, FALSE);
    g_signal_connect_swapped (self->star, "clicked", G_CALLBACK (on_star), self);
    gtk_box_append (GTK_BOX (box), self->star);

    return box;
}

static void
apex_details_pane_dispose (GObject *object)
{
    ApexDetailsPane *self = APEX_DETAILS_PANE (object);

    g_clear_object (&self->watch);
    g_clear_object (&self->file_signals);
    g_clear_pointer (&self->box, gtk_widget_unparent);
    G_OBJECT_CLASS (apex_details_pane_parent_class)->dispose (object);
}

static void
apex_details_pane_class_init (ApexDetailsPaneClass *klass)
{
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

    G_OBJECT_CLASS (klass)->dispose = apex_details_pane_dispose;
    gtk_widget_class_set_layout_manager_type (widget_class, GTK_TYPE_BIN_LAYOUT);
    gtk_widget_class_set_css_name (widget_class, "apex-details-pane");
}

static void
apex_details_pane_init (ApexDetailsPane *self)
{
    GtkWidget *preview_frame = adw_bin_new ();
    GtkWidget *heading = gtk_box_new (GTK_ORIENTATION_VERTICAL, 3);

    self->box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 18);
    gtk_widget_set_parent (self->box, GTK_WIDGET (self));

    self->preview = gtk_image_new ();
    gtk_image_set_pixel_size (GTK_IMAGE (self->preview), PREVIEW_ICON_SIZE);
    adw_bin_set_child (ADW_BIN (preview_frame), self->preview);
    gtk_widget_add_css_class (preview_frame, "apex-details-preview");
    gtk_box_append (GTK_BOX (self->box), preview_frame);

    self->name = fact_label ("apex-details-name");
    self->kind = fact_label ("apex-details-kind");
    gtk_label_set_selectable (GTK_LABEL (self->kind), FALSE);
    gtk_box_append (GTK_BOX (heading), self->name);
    gtk_box_append (GTK_BOX (heading), self->kind);
    gtk_box_append (GTK_BOX (self->box), heading);

    gtk_box_append (GTK_BOX (self->box), facts (self));
    gtk_box_append (GTK_BOX (self->box), actions (self));

    self->file_signals = g_signal_group_new (NAUTILUS_TYPE_FILE);
    g_signal_group_connect_swapped (self->file_signals, "changed", G_CALLBACK (update), self);
}

GtkWidget *
apex_details_pane_new (ApexSlotWatch *watch)
{
    ApexDetailsPane *self = g_object_new (APEX_TYPE_DETAILS_PANE, NULL);

    self->watch = g_object_ref (watch);
    g_signal_connect_object (watch, "content-changed", G_CALLBACK (update), self, G_CONNECT_SWAPPED);
    g_signal_connect_object (nautilus_tag_manager_get (), "starred-changed", G_CALLBACK (update), self,
                             G_CONNECT_SWAPPED);
    update (self);
    return GTK_WIDGET (self);
}
