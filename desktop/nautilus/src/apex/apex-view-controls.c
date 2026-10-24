/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-view-controls.h"

#include <adwaita.h>
#include <glib/gi18n.h>

#include "nautilus-view-info.h"

#define GRID "grid"
#define LIST "list"

struct _ApexViewControls
{
    GtkWidget parent_instance;

    ApexSlotWatch *watch;
    GtkWidget *box;
    AdwToggleGroup *modes;
    gboolean syncing;
};

G_DEFINE_FINAL_TYPE (ApexViewControls, apex_view_controls, GTK_TYPE_WIDGET)

static void
sync_mode (ApexViewControls *self)
{
    guint view_id = apex_slot_watch_get_view_id (self->watch);

    self->syncing = TRUE;
    gtk_widget_set_sensitive (GTK_WIDGET (self->modes), view_id != NAUTILUS_VIEW_INVALID_ID);
    if (view_id != NAUTILUS_VIEW_INVALID_ID)
    {
        adw_toggle_group_set_active_name (self->modes, view_id == NAUTILUS_VIEW_LIST_ID ? LIST : GRID);
    }

    self->syncing = FALSE;
}

static void
on_mode_picked (ApexViewControls *self)
{
    const char *name = adw_toggle_group_get_active_name (self->modes);
    guint view_id = g_strcmp0 (name, LIST) == 0 ? NAUTILUS_VIEW_LIST_ID : NAUTILUS_VIEW_GRID_ID;

    if (!self->syncing && view_id != apex_slot_watch_get_view_id (self->watch))
    {
        gtk_widget_activate_action (GTK_WIDGET (self), "slot.files-view-mode", "u", view_id);
    }
}

static AdwToggle *
mode_toggle (const char *name,
             const char *icon_name,
             const char *tooltip)
{
    AdwToggle *toggle = adw_toggle_new ();

    adw_toggle_set_name (toggle, name);
    adw_toggle_set_icon_name (toggle, icon_name);
    adw_toggle_set_tooltip (toggle, tooltip);
    return toggle;
}

static void
apex_view_controls_dispose (GObject *object)
{
    ApexViewControls *self = APEX_VIEW_CONTROLS (object);

    g_clear_object (&self->watch);
    g_clear_pointer (&self->box, gtk_widget_unparent);
    G_OBJECT_CLASS (apex_view_controls_parent_class)->dispose (object);
}

static void
apex_view_controls_class_init (ApexViewControlsClass *klass)
{
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

    G_OBJECT_CLASS (klass)->dispose = apex_view_controls_dispose;
    gtk_widget_class_set_layout_manager_type (widget_class, GTK_TYPE_BIN_LAYOUT);
    gtk_widget_class_set_css_name (widget_class, "apex-view-controls");
}

static void
apex_view_controls_init (ApexViewControls *self)
{
    GtkWidget *details = gtk_toggle_button_new ();

    self->box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_parent (self->box, GTK_WIDGET (self));
    gtk_widget_set_valign (self->box, GTK_ALIGN_CENTER);

    self->modes = ADW_TOGGLE_GROUP (adw_toggle_group_new ());
    adw_toggle_group_add (self->modes, mode_toggle (GRID, "view-grid-symbolic", _("Grid View")));
    adw_toggle_group_add (self->modes, mode_toggle (LIST, "view-list-symbolic", _("List View")));
    gtk_accessible_update_property (GTK_ACCESSIBLE (self->modes), GTK_ACCESSIBLE_PROPERTY_LABEL, _("View"), -1);
    g_signal_connect_swapped (self->modes, "notify::active-name", G_CALLBACK (on_mode_picked), self);
    gtk_box_append (GTK_BOX (self->box), GTK_WIDGET (self->modes));

    gtk_button_set_icon_name (GTK_BUTTON (details), "sidebar-show-right-symbolic");
    gtk_widget_set_tooltip_text (details, _("Details"));
    gtk_actionable_set_action_name (GTK_ACTIONABLE (details), "win.show-details");
    gtk_box_append (GTK_BOX (self->box), details);
}

GtkWidget *
apex_view_controls_new (ApexSlotWatch *watch,
                        GtkPopover    *view_options)
{
    ApexViewControls *self = g_object_new (APEX_TYPE_VIEW_CONTROLS, NULL);
    GtkWidget *options = gtk_menu_button_new ();

    self->watch = g_object_ref (watch);
    gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (options), "view-more-symbolic");
    gtk_widget_set_tooltip_text (options, _("View Options"));
    gtk_menu_button_set_popover (GTK_MENU_BUTTON (options), GTK_WIDGET (view_options));
    gtk_box_prepend (GTK_BOX (self->box), options);

    g_signal_connect_object (watch, "view-changed", G_CALLBACK (sync_mode), self, G_CONNECT_SWAPPED);
    sync_mode (self);
    return GTK_WIDGET (self);
}
