/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-count-bar.h"

#include "apex-format.h"

#include <glib/gi18n.h>

#include "nautilus-file.h"
#include "nautilus-floating-bar.h"
#include "nautilus-files-view.h"
#include "nautilus-view-item.h"
#include "nautilus-view-model.h"
#include "nautilus-window-slot.h"

struct _ApexCountBar
{
    GtkWidget parent_instance;

    GtkWidget *label;
    GSignalGroup *slot_signals;
    GSignalGroup *view_signals;
    GSignalGroup *model_signals;
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
    g_autoptr (NautilusFilesView) view = g_signal_group_dup_target (self->view_signals);
    g_autofree char *text = NULL;

    if (view != NULL)
    {
        text = status_text (view, nautilus_files_view_get_private_model (view));
    }

    gtk_label_set_label (GTK_LABEL (self->label), text);
}

static void
follow_view (ApexCountBar *self)
{
    g_autoptr (NautilusWindowSlot) slot = g_signal_group_dup_target (self->slot_signals);
    NautilusFilesView *view = slot != NULL ? nautilus_window_slot_get_current_view (slot) : NULL;

    GtkWidget *floating_bar = view != NULL ? find_floating_bar (GTK_WIDGET (view)) : NULL;

    if (floating_bar != NULL)
    {
        gtk_widget_set_child_visible (floating_bar, FALSE);
    }

    g_signal_group_set_target (self->view_signals, view);
    g_signal_group_set_target (self->model_signals,
                               view != NULL ? nautilus_files_view_get_private_model (view) : NULL);
    update (self);
}

static void
on_active_slot (GtkWindow    *window,
                GParamSpec   *pspec,
                ApexCountBar *self)
{
    g_autoptr (NautilusWindowSlot) slot = NULL;

    g_object_get (window, "active-slot", &slot, NULL);
    g_signal_group_set_target (self->slot_signals, slot);
    follow_view (self);
}

static void
apex_count_bar_dispose (GObject *object)
{
    ApexCountBar *self = APEX_COUNT_BAR (object);

    g_clear_object (&self->slot_signals);
    g_clear_object (&self->view_signals);
    g_clear_object (&self->model_signals);
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

    self->slot_signals = g_signal_group_new (NAUTILUS_TYPE_WINDOW_SLOT);
    g_signal_group_connect_swapped (self->slot_signals, "notify::icon-name", G_CALLBACK (follow_view), self);
    g_signal_group_connect_swapped (self->slot_signals, "notify::location", G_CALLBACK (follow_view), self);

    self->view_signals = g_signal_group_new (NAUTILUS_TYPE_FILES_VIEW);
    g_signal_group_connect_swapped (self->view_signals, "notify::searching", G_CALLBACK (update), self);
    g_signal_group_connect_swapped (self->view_signals, "notify::loading", G_CALLBACK (update), self);

    self->model_signals = g_signal_group_new (NAUTILUS_TYPE_VIEW_MODEL);
    g_signal_group_connect_swapped (self->model_signals, "items-changed", G_CALLBACK (update), self);
    g_signal_group_connect_swapped (self->model_signals, "selection-changed", G_CALLBACK (update), self);
}

GtkWidget *
apex_count_bar_new (GtkWindow *window)
{
    ApexCountBar *self = g_object_new (APEX_TYPE_COUNT_BAR, NULL);

    g_signal_connect_object (window, "notify::active-slot", G_CALLBACK (on_active_slot), self, G_CONNECT_DEFAULT);
    on_active_slot (window, NULL, self);
    return GTK_WIDGET (self);
}
