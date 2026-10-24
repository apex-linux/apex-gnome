/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-count-bar.h"

#include "apex-format.h"
#include "apex-slot-watch.h"

#include <glib/gi18n.h>

#include "nautilus-file.h"
#include "nautilus-floating-bar.h"
#include "nautilus-files-view.h"
#include "nautilus-view-item.h"
#include "nautilus-view-model.h"

struct _ApexCountBar
{
    GtkWidget parent_instance;

    GtkWidget *label;
    ApexSlotWatch *watch;
};

G_DEFINE_FINAL_TYPE (ApexCountBar, apex_count_bar, GTK_TYPE_WIDGET)

static NautilusFile *
selected_file (GtkSelectionModel *model,
               GtkBitset         *selection)
{
    g_autoptr (GtkTreeListRow) row = g_list_model_get_item (G_LIST_MODEL (model),
                                                            gtk_bitset_get_minimum (selection));
    g_autoptr (NautilusViewItem) item = NULL;

    if (row == NULL)
    {
        return NULL;
    }

    item = gtk_tree_list_row_get_item (row);
    return item != NULL ? nautilus_view_item_get_file (item) : NULL;
}

static GtkWidget *
find_floating_bar (GtkWidget *widget)
{
    if (NAUTILUS_IS_FLOATING_BAR (widget))
    {
        return widget;
    }

    for (GtkWidget *child = gtk_widget_get_first_child (widget); child != NULL;
         child = gtk_widget_get_next_sibling (child))
    {
        GtkWidget *found = find_floating_bar (child);

        if (found != NULL)
        {
            return found;
        }
    }

    return NULL;
}

static char *
status_text (NautilusFilesView *view,
             NautilusViewModel *model)
{
    g_autoptr (GtkBitset) selection = gtk_selection_model_get_selection (GTK_SELECTION_MODEL (model));
    guint n_items = g_list_model_get_n_items (G_LIST_MODEL (model));
    gboolean searching = nautilus_files_view_is_searching (view);
    guint n_selected = gtk_bitset_get_size (selection);
    NautilusFile *file = n_selected == 1 ? selected_file (GTK_SELECTION_MODEL (model), selection) : NULL;

    if (n_items == 0 && nautilus_files_view_get_loading (view))
    {
        return g_strdup (searching ? _("Searching…") : _("Loading…"));
    }

    return apex_format_item_count (n_items, searching, n_selected,
                                   file != NULL ? nautilus_file_get_display_name (file) : NULL);
}

static void
update (ApexCountBar *self)
{
    NautilusFilesView *view = apex_slot_watch_get_view (self->watch);
    g_autofree char *text = view != NULL ? status_text (view, nautilus_files_view_get_private_model (view)) : NULL;

    gtk_label_set_label (GTK_LABEL (self->label), text);
}

static void
hide_floating_bar (ApexCountBar *self)
{
    NautilusFilesView *view = apex_slot_watch_get_view (self->watch);
    GtkWidget *floating_bar = view != NULL ? find_floating_bar (GTK_WIDGET (view)) : NULL;

    if (floating_bar != NULL)
    {
        gtk_widget_set_child_visible (floating_bar, FALSE);
    }
}

static void
apex_count_bar_dispose (GObject *object)
{
    ApexCountBar *self = APEX_COUNT_BAR (object);

    g_clear_object (&self->watch);
    g_clear_pointer (&self->label, gtk_widget_unparent);
    G_OBJECT_CLASS (apex_count_bar_parent_class)->dispose (object);
}

static void
apex_count_bar_class_init (ApexCountBarClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

    object_class->dispose = apex_count_bar_dispose;
    gtk_widget_class_set_layout_manager_type (widget_class, GTK_TYPE_BIN_LAYOUT);
    gtk_widget_class_set_css_name (widget_class, "apex-count-bar");
    gtk_widget_class_set_accessible_role (widget_class, GTK_ACCESSIBLE_ROLE_STATUS);
}

static void
apex_count_bar_init (ApexCountBar *self)
{
    self->label = gtk_label_new (NULL);
    gtk_label_set_ellipsize (GTK_LABEL (self->label), PANGO_ELLIPSIZE_MIDDLE);
    gtk_widget_set_parent (self->label, GTK_WIDGET (self));

}

GtkWidget *
apex_count_bar_new (ApexSlotWatch *watch)
{
    ApexCountBar *self = g_object_new (APEX_TYPE_COUNT_BAR, NULL);

    self->watch = g_object_ref (watch);
    g_signal_connect_object (watch, "view-changed", G_CALLBACK (hide_floating_bar), self, G_CONNECT_SWAPPED);
    g_signal_connect_object (watch, "content-changed", G_CALLBACK (update), self, G_CONNECT_SWAPPED);
    hide_floating_bar (self);
    update (self);
    return GTK_WIDGET (self);
}
