/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-search-chips.h"

#include "apex-format.h"

#include <glib/gi18n.h>

#include "nautilus-file.h"
#include "nautilus-view-item.h"

typedef struct
{
    const char *label;
    ApexKind kinds;
} Chip;

static const Chip chips[] = {
    { N_("All"), APEX_KIND_OTHER },
    { N_("Folders"), APEX_KIND_FOLDER },
    { N_("Documents"), APEX_KIND_DOCUMENT },
    { N_("Images"), APEX_KIND_IMAGE },
    { N_("Audio & Video"), APEX_KIND_MEDIA },
};

struct _ApexSearchChips
{
    GtkWidget parent_instance;

    ApexSlotWatch *watch;
    GSignalGroup *results_signals;
    GtkWidget *box;
    GtkWidget *buttons[G_N_ELEMENTS (chips)];
    GtkWidget *counts[G_N_ELEMENTS (chips)];
    GtkFilter *filter;
    GWeakRef filtered_slot;
    guint selected;
};

G_DEFINE_FINAL_TYPE (ApexSearchChips, apex_search_chips, GTK_TYPE_WIDGET)

static ApexKind
item_kind (gpointer item)
{
    NautilusFile *file = nautilus_view_item_get_file (NAUTILUS_VIEW_ITEM (item));

    return apex_kind_of (nautilus_file_get_mime_type (file), nautilus_file_is_directory (file));
}

static gboolean
matches_selected_chip (gpointer item,
                       gpointer user_data)
{
    ApexSearchChips *self = user_data;

    return self->selected == 0 || (item_kind (item) & chips[self->selected].kinds) != 0;
}

static void
update_counts (ApexSearchChips *self)
{
    g_autoptr (GListModel) results = g_signal_group_dup_target (self->results_signals);
    guint counts[G_N_ELEMENTS (chips)] = { 0 };
    guint n = results != NULL ? g_list_model_get_n_items (results) : 0;

    for (guint i = 0; i < n; i++)
    {
        g_autoptr (GObject) item = g_list_model_get_item (results, i);
        ApexKind kind = item_kind (item);

        counts[0]++;
        for (guint c = 1; c < G_N_ELEMENTS (chips); c++)
        {
            counts[c] += (kind & chips[c].kinds) != 0;
        }
    }

    for (guint c = 0; c < G_N_ELEMENTS (chips); c++)
    {
        g_autofree char *text = g_strdup_printf ("%u", counts[c]);
        g_autofree char *label = g_strdup_printf ("%s %u", _(chips[c].label), counts[c]);

        gtk_label_set_label (GTK_LABEL (self->counts[c]), text);
        gtk_accessible_update_property (GTK_ACCESSIBLE (self->buttons[c]), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
    }
}

static void
apply_filter (ApexSearchChips *self)
{
    g_autoptr (NautilusWindowSlot) previous = g_weak_ref_get (&self->filtered_slot);
    NautilusWindowSlot *slot = apex_slot_watch_get_slot (self->watch);
    gboolean filtering = self->selected != 0 && apex_slot_watch_is_searching (self->watch);

    if (previous != NULL && previous != slot)
    {
        nautilus_window_slot_set_filter (previous, NULL);
    }

    if (slot != NULL)
    {
        nautilus_window_slot_set_filter (slot, filtering ? self->filter : NULL);
    }

    g_weak_ref_set (&self->filtered_slot, filtering ? slot : NULL);
    gtk_filter_changed (self->filter, GTK_FILTER_CHANGE_DIFFERENT);
}

static void
select_chip (ApexSearchChips *self,
             guint            index)
{
    self->selected = index;
    for (guint c = 0; c < G_N_ELEMENTS (chips); c++)
    {
        gtk_toggle_button_set_active (GTK_TOGGLE_BUTTON (self->buttons[c]), c == index);
    }

    apply_filter (self);
}

static void
on_chip_toggled (GtkToggleButton *button,
                 ApexSearchChips *self)
{
    guint index = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (button), "apex-chip"));

    if (gtk_toggle_button_get_active (button) && index != self->selected)
    {
        select_chip (self, index);
    }
}

static void
on_view_changed (ApexSearchChips *self)
{
    NautilusViewModel *model = apex_slot_watch_get_model (self->watch);

    g_signal_group_set_target (self->results_signals,
                               model != NULL ? nautilus_view_model_get_unfiltered (model) : NULL);
    select_chip (self, 0);
}

static void
on_content_changed (ApexSearchChips *self)
{
    gboolean searching = apex_slot_watch_is_searching (self->watch);

    if (!searching && self->selected != 0)
    {
        select_chip (self, 0);
    }

    gtk_widget_set_visible (GTK_WIDGET (self), searching);
    update_counts (self);
}

static GtkWidget *
chip_button (ApexSearchChips *self,
             guint            index)
{
    GtkWidget *button = gtk_toggle_button_new ();
    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);

    self->counts[index] = gtk_label_new ("0");
    gtk_widget_add_css_class (self->counts[index], "apex-chip-count");
    gtk_box_append (GTK_BOX (box), gtk_label_new (_(chips[index].label)));
    gtk_box_append (GTK_BOX (box), self->counts[index]);
    gtk_button_set_child (GTK_BUTTON (button), box);
    gtk_widget_add_css_class (button, "apex-chip");
    if (index > 0)
    {
        gtk_toggle_button_set_group (GTK_TOGGLE_BUTTON (button), GTK_TOGGLE_BUTTON (self->buttons[0]));
    }

    g_object_set_data (G_OBJECT (button), "apex-chip", GUINT_TO_POINTER (index));
    g_signal_connect (button, "toggled", G_CALLBACK (on_chip_toggled), self);
    return button;
}

static void
apex_search_chips_dispose (GObject *object)
{
    ApexSearchChips *self = APEX_SEARCH_CHIPS (object);
    g_autoptr (NautilusWindowSlot) filtered = g_weak_ref_get (&self->filtered_slot);

    if (filtered != NULL)
    {
        nautilus_window_slot_set_filter (filtered, NULL);
    }

    g_weak_ref_clear (&self->filtered_slot);
    g_clear_object (&self->watch);
    g_clear_object (&self->results_signals);
    g_clear_object (&self->filter);
    g_clear_pointer (&self->box, gtk_widget_unparent);
    G_OBJECT_CLASS (apex_search_chips_parent_class)->dispose (object);
}

static void
apex_search_chips_class_init (ApexSearchChipsClass *klass)
{
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

    G_OBJECT_CLASS (klass)->dispose = apex_search_chips_dispose;
    gtk_widget_class_set_layout_manager_type (widget_class, GTK_TYPE_BIN_LAYOUT);
    gtk_widget_class_set_css_name (widget_class, "apex-search-chips");
    gtk_widget_class_set_accessible_role (widget_class, GTK_ACCESSIBLE_ROLE_GROUP);
}

static void
apex_search_chips_init (ApexSearchChips *self)
{
    self->box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_parent (self->box, GTK_WIDGET (self));
    for (guint c = 0; c < G_N_ELEMENTS (chips); c++)
    {
        self->buttons[c] = chip_button (self, c);
        gtk_box_append (GTK_BOX (self->box), self->buttons[c]);
    }

    gtk_toggle_button_set_active (GTK_TOGGLE_BUTTON (self->buttons[0]), TRUE);
    gtk_accessible_update_property (GTK_ACCESSIBLE (self), GTK_ACCESSIBLE_PROPERTY_LABEL, _("Filter results"), -1);
    g_weak_ref_init (&self->filtered_slot, NULL);
    self->filter = GTK_FILTER (gtk_custom_filter_new (matches_selected_chip, self, NULL));
    self->results_signals = g_signal_group_new (G_TYPE_OBJECT);
    g_signal_group_connect_swapped (self->results_signals, "items-changed", G_CALLBACK (update_counts), self);
}

GtkWidget *
apex_search_chips_new (ApexSlotWatch *watch)
{
    ApexSearchChips *self = g_object_new (APEX_TYPE_SEARCH_CHIPS, NULL);

    self->watch = g_object_ref (watch);
    g_signal_connect_object (watch, "view-changed", G_CALLBACK (on_view_changed), self, G_CONNECT_SWAPPED);
    g_signal_connect_object (watch, "content-changed", G_CALLBACK (on_content_changed), self, G_CONNECT_SWAPPED);
    on_view_changed (self);
    on_content_changed (self);
    return GTK_WIDGET (self);
}
