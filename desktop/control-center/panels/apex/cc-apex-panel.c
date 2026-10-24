/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <config.h>

#include <adwaita.h>

#include "cc-apex-header.h"
#include "cc-apex-panel.h"

#define APEX_SCHEMA "io.github.apex_linux.Apex.Desktop"
#define BUTTONS_ALL "appmenu:minimize,maximize,close"
#define BUTTONS_CLOSE "appmenu:close"

struct _CcApexPanel {
    CcPanel parent_instance;

    GSettings *apex_settings;
    GSettings *interface_settings;
    GSettings *a11y_interface_settings;
    GSettings *wm_settings;
    GSettings *mutter_settings;

    GtkStack *stack;

    AdwSwitchRow *translucent_top_bar_row;
    AdwSwitchRow *show_focused_app_name_row;
    AdwSwitchRow *clock_show_date_row;
    AdwSwitchRow *show_battery_percentage_row;
    AdwSwitchRow *hot_corner_row;

    AdwActionRow *dock_icon_size_row;
    AdwToggleGroup *dock_icon_size_group;
    AdwSwitchRow *dock_intellihide_row;
    AdwSwitchRow *dock_running_indicators_row;
    AdwSwitchRow *dock_show_trash_row;

    AdwActionRow *window_corner_radius_row;
    AdwToggleGroup *window_corner_radius_group;
    AdwToggleGroup *titlebar_buttons_group;
    AdwSwitchRow *edge_tiling_row;

    AdwSwitchRow *reduce_transparency_row;
    AdwSwitchRow *reduce_motion_row;
};

CC_PANEL_REGISTER (CcApexPanel, cc_apex_panel)

static void
clock_show_date_changed_cb (CcApexPanel *self)
{
    gboolean on = adw_switch_row_get_active (self->clock_show_date_row);

    if (g_settings_get_boolean (self->interface_settings, "clock-show-weekday") != on)
        g_settings_set_boolean (self->interface_settings, "clock-show-weekday", on);
}

static void
reduce_motion_changed_cb (CcApexPanel *self)
{
    if (adw_switch_row_get_active (self->reduce_motion_row))
        g_settings_set_string (self->a11y_interface_settings, "reduced-motion", "reduce");
    else
        g_settings_reset (self->a11y_interface_settings, "reduced-motion");
}

static gboolean
radius_get_mapping (GValue *value, GVariant *variant, gpointer user_data)
{
    AdwToggleGroup *group = user_data;
    g_autofree char *name = g_strdup_printf ("%u", g_variant_get_uint32 (variant));

    g_value_set_string (value, adw_toggle_group_get_toggle_by_name (group, name) ? name : NULL);
    return TRUE;
}

static GVariant *
radius_set_mapping (const GValue *value, const GVariantType *expected_type, gpointer user_data)
{
    const char *name = g_value_get_string (value);

    if (name == NULL)
        return NULL;
    return g_variant_new_uint32 ((guint32) g_ascii_strtoull (name, NULL, 10));
}

static gboolean
buttons_get_mapping (GValue *value, GVariant *variant, gpointer user_data)
{
    const char *layout = g_variant_get_string (variant, NULL);

    if (g_str_equal (layout, BUTTONS_ALL))
        g_value_set_string (value, "all");
    else if (g_str_equal (layout, BUTTONS_CLOSE))
        g_value_set_string (value, "close");
    else
        g_value_set_string (value, NULL);
    return TRUE;
}

static GVariant *
buttons_set_mapping (const GValue *value, const GVariantType *expected_type, gpointer user_data)
{
    const char *name = g_value_get_string (value);

    if (g_strcmp0 (name, "all") == 0)
        return g_variant_new_string (BUTTONS_ALL);
    if (g_strcmp0 (name, "close") == 0)
        return g_variant_new_string (BUTTONS_CLOSE);
    return NULL;
}

/* An older schema without one of the keys hides that row rather than failing the panel. */
static gboolean
apex_key_exists (CcApexPanel *self, const char *key, gpointer row)
{
    g_autoptr(GSettingsSchema) schema = NULL;

    g_object_get (self->apex_settings, "settings-schema", &schema, NULL);
    if (g_settings_schema_has_key (schema, key))
        return TRUE;

    g_warning ("%s has no key %s; hiding its row", APEX_SCHEMA, key);
    gtk_widget_set_visible (GTK_WIDGET (row), FALSE);
    return FALSE;
}

static void
bind_apex_switch (CcApexPanel *self, const char *key, AdwSwitchRow *row)
{
    if (apex_key_exists (self, key, row))
        g_settings_bind (self->apex_settings, key, row, "active", G_SETTINGS_BIND_DEFAULT);
}

static void
bind_apex_settings (CcApexPanel *self)
{
    bind_apex_switch (self, "translucent-top-bar", self->translucent_top_bar_row);
    bind_apex_switch (self, "show-focused-app-name", self->show_focused_app_name_row);
    bind_apex_switch (self, "dock-intellihide", self->dock_intellihide_row);
    bind_apex_switch (self, "dock-running-indicators", self->dock_running_indicators_row);
    bind_apex_switch (self, "dock-show-trash", self->dock_show_trash_row);
    bind_apex_switch (self, "reduce-transparency", self->reduce_transparency_row);

    if (apex_key_exists (self, "dock-icon-size", self->dock_icon_size_row))
        g_settings_bind (self->apex_settings, "dock-icon-size", self->dock_icon_size_group, "active-name",
                         G_SETTINGS_BIND_DEFAULT);
    if (apex_key_exists (self, "window-corner-radius", self->window_corner_radius_row))
        g_settings_bind_with_mapping (self->apex_settings, "window-corner-radius", self->window_corner_radius_group,
                                      "active-name", G_SETTINGS_BIND_DEFAULT, radius_get_mapping,
                                      radius_set_mapping, self->window_corner_radius_group, NULL);
}

static void
cc_apex_panel_finalize (GObject *object)
{
    CcApexPanel *self = CC_APEX_PANEL (object);

    g_clear_object (&self->apex_settings);
    g_clear_object (&self->interface_settings);
    g_clear_object (&self->a11y_interface_settings);
    g_clear_object (&self->wm_settings);
    g_clear_object (&self->mutter_settings);

    G_OBJECT_CLASS (cc_apex_panel_parent_class)->finalize (object);
}

static void
cc_apex_panel_class_init (CcApexPanelClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

    object_class->finalize = cc_apex_panel_finalize;

    g_type_ensure (CC_TYPE_APEX_HEADER);

    gtk_widget_class_set_template_from_resource (widget_class, "/org/gnome/Settings/apex/cc-apex-panel.ui");

    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, stack);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, translucent_top_bar_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, show_focused_app_name_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, clock_show_date_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, show_battery_percentage_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, hot_corner_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, dock_icon_size_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, dock_icon_size_group);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, dock_intellihide_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, dock_running_indicators_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, dock_show_trash_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, window_corner_radius_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, window_corner_radius_group);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, titlebar_buttons_group);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, edge_tiling_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, reduce_transparency_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexPanel, reduce_motion_row);
}

static void
cc_apex_panel_init (CcApexPanel *self)
{
    g_autoptr(GSettingsSchema) apex_schema = NULL;

    gtk_widget_init_template (GTK_WIDGET (self));

    apex_schema = g_settings_schema_source_lookup (g_settings_schema_source_get_default (), APEX_SCHEMA, TRUE);
    if (apex_schema == NULL) {
        g_warning ("%s is not installed", APEX_SCHEMA);
        gtk_stack_set_visible_child_name (self->stack, "no-schema");
        return;
    }

    self->apex_settings = g_settings_new_full (apex_schema, NULL, NULL);
    self->interface_settings = g_settings_new ("org.gnome.desktop.interface");
    self->a11y_interface_settings = g_settings_new ("org.gnome.desktop.a11y.interface");
    self->wm_settings = g_settings_new ("org.gnome.desktop.wm.preferences");
    self->mutter_settings = g_settings_new ("org.gnome.mutter");

    bind_apex_settings (self);

    g_settings_bind (self->interface_settings, "clock-show-date", self->clock_show_date_row, "active",
                     G_SETTINGS_BIND_DEFAULT);
    g_settings_bind (self->interface_settings, "show-battery-percentage", self->show_battery_percentage_row,
                     "active", G_SETTINGS_BIND_DEFAULT);
    g_settings_bind (self->interface_settings, "enable-hot-corners", self->hot_corner_row, "active",
                     G_SETTINGS_BIND_DEFAULT);
    g_settings_bind_with_mapping (self->wm_settings, "button-layout", self->titlebar_buttons_group, "active-name",
                                  G_SETTINGS_BIND_DEFAULT, buttons_get_mapping, buttons_set_mapping, NULL, NULL);
    g_settings_bind (self->mutter_settings, "edge-tiling", self->edge_tiling_row, "active", G_SETTINGS_BIND_DEFAULT);
    g_settings_bind (self->interface_settings, "enable-animations", self->reduce_motion_row, "active",
                     G_SETTINGS_BIND_DEFAULT | G_SETTINGS_BIND_INVERT_BOOLEAN);

    /* After the bindings, so that opening the panel writes no second key. */
    g_signal_connect_swapped (self->clock_show_date_row, "notify::active", G_CALLBACK (clock_show_date_changed_cb),
                              self);
    g_signal_connect_swapped (self->reduce_motion_row, "notify::active", G_CALLBACK (reduce_motion_changed_cb), self);
}
