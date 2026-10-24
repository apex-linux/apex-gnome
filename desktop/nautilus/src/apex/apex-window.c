/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-window.h"

#include <glib/gi18n.h>

#include "apex-count-bar.h"
#include "apex-details-pane.h"
#include "apex-disk-footer.h"
#include "apex-recent-strip.h"
#include "apex-search-chips.h"
#include "apex-settings.h"
#include "apex-slot-watch.h"
#include "apex-view-controls.h"

#include "nautilus-view-controls.h"

#define STOCK_ENV "APEX_NAUTILUS_STOCK"
#define DETAILS_WIDTH 300
/* nautilus's sidebar is 180 px wide from 682 to 900 sp and collapses below, so the
 * content is under 720 sp exactly when the window is under 900 sp. */
#define DETAILS_OVERLAY_CONDITION "max-width: 720sp"
#define MAIN_MENU_APEX_SECTION 2

static void
load_css_once (void)
{
    static gboolean loaded;
    g_autoptr (GtkCssProvider) provider = NULL;

    if (loaded)
    {
        return;
    }

    loaded = TRUE;
    provider = gtk_css_provider_new ();
    gtk_css_provider_load_from_resource (provider, "/org/gnome/nautilus/apex/apex.css");
    gtk_style_context_add_provider_for_display (gdk_display_get_default (),
                                                GTK_STYLE_PROVIDER (provider),
                                                GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
}

static void
collect_descendants (GtkWidget  *widget,
                     GType       type,
                     GPtrArray  *found)
{
    if (G_TYPE_CHECK_INSTANCE_TYPE (widget, type))
    {
        g_ptr_array_add (found, widget);
        return;
    }

    for (GtkWidget *child = gtk_widget_get_first_child (widget); child != NULL;
         child = gtk_widget_get_next_sibling (child))
    {
        collect_descendants (child, type, found);
    }
}

static GSimpleAction *
add_toggle_action (AdwApplicationWindow *window,
                   const char           *name,
                   const char           *key,
                   gboolean              fallback)
{
    GSimpleAction *action = apex_settings_toggle_action (name, key, fallback);

    g_action_map_add_action (G_ACTION_MAP (window), G_ACTION (action));
    g_object_unref (action);
    return action;
}

static void
attach_disk_footer (AdwToolbarView *pane,
                    GtkWidget      *places_sidebar)
{
    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

    g_object_ref (places_sidebar);
    adw_toolbar_view_set_content (pane, box);
    gtk_box_append (GTK_BOX (box), places_sidebar);
    gtk_box_append (GTK_BOX (box), apex_disk_footer_new ());
    g_object_unref (places_sidebar);
}

static void
attach_main_menu_items (AdwToolbarView *pane)
{
    g_autoptr (GPtrArray) buttons = g_ptr_array_new ();
    g_autoptr (GMenu) section = g_menu_new ();
    GMenuModel *menu;

    collect_descendants (GTK_WIDGET (pane), GTK_TYPE_MENU_BUTTON, buttons);
    menu = buttons->len > 0 ? gtk_menu_button_get_menu_model (buttons->pdata[0]) : NULL;
    if (!G_IS_MENU (menu))
    {
        return;
    }

    g_menu_append (section, _("_Details Pane"), "win.show-details");
    g_menu_append (section, _("_Recent Files on Home"), "win.show-recent-strip");
    g_menu_insert_section (G_MENU (menu), MAIN_MENU_APEX_SECTION, NULL, G_MENU_MODEL (section));
}

static void
on_details_state (GSimpleAction      *action,
                  GParamSpec         *pspec,
                  AdwOverlaySplitView *split)
{
    g_autoptr (GVariant) state = g_action_get_state (G_ACTION (action));

    adw_overlay_split_view_set_show_sidebar (split, g_variant_get_boolean (state));
}

static void
on_details_shown (AdwOverlaySplitView *split,
                  GParamSpec          *pspec,
                  GSimpleAction       *action)
{
    g_autoptr (GVariant) state = g_action_get_state (G_ACTION (action));
    gboolean shown = adw_overlay_split_view_get_show_sidebar (split);

    if (g_variant_get_boolean (state) != shown)
    {
        g_simple_action_set_state (action, g_variant_new_boolean (shown));
    }
}

static GtkWidget *
details_split (ApexSlotWatch *watch,
               GtkWidget     *content,
               GSimpleAction *show_details)
{
    AdwOverlaySplitView *split = ADW_OVERLAY_SPLIT_VIEW (adw_overlay_split_view_new ());
    GtkWidget *bin = adw_breakpoint_bin_new ();
    AdwBreakpoint *overlay = adw_breakpoint_new (adw_breakpoint_condition_parse (DETAILS_OVERLAY_CONDITION));

    adw_overlay_split_view_set_sidebar_position (split, GTK_PACK_END);
    adw_overlay_split_view_set_min_sidebar_width (split, DETAILS_WIDTH);
    adw_overlay_split_view_set_max_sidebar_width (split, DETAILS_WIDTH);
    adw_overlay_split_view_set_enable_show_gesture (split, FALSE);
    adw_overlay_split_view_set_pin_sidebar (split, TRUE);
    adw_overlay_split_view_set_sidebar (split, apex_details_pane_new (watch));
    adw_overlay_split_view_set_content (split, content);
    g_signal_connect_object (show_details, "notify::state", G_CALLBACK (on_details_state), split, G_CONNECT_DEFAULT);
    g_signal_connect_object (split, "notify::show-sidebar", G_CALLBACK (on_details_shown), show_details,
                             G_CONNECT_DEFAULT);
    on_details_state (show_details, NULL, split);

    adw_breakpoint_add_setters (overlay, G_OBJECT (split), "collapsed", TRUE, NULL);
    adw_breakpoint_bin_add_breakpoint (ADW_BREAKPOINT_BIN (bin), overlay);
    gtk_widget_set_size_request (bin, 1, 1);
    adw_breakpoint_bin_set_child (ADW_BREAKPOINT_BIN (bin), GTK_WIDGET (split));
    return bin;
}

static void
attach_content (AdwToolbarView *content,
                GtkWidget      *tab_view,
                ApexSlotWatch  *watch,
                GSimpleAction  *show_details,
                GSimpleAction  *show_recent)
{
    GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

    g_object_ref (tab_view);
    adw_toolbar_view_set_content (content, details_split (watch, column, show_details));
    gtk_box_append (GTK_BOX (column), apex_recent_strip_new (watch, G_ACTION (show_recent)));
    gtk_widget_set_vexpand (tab_view, TRUE);
    gtk_box_append (GTK_BOX (column), tab_view);
    g_object_unref (tab_view);

    adw_toolbar_view_add_top_bar (content, apex_search_chips_new (watch));
    adw_toolbar_view_add_bottom_bar (content, apex_count_bar_new (watch));
}

static void
replace_view_controls (AdwApplicationWindow *window,
                       ApexSlotWatch        *watch)
{
    g_autoptr (GPtrArray) controls = g_ptr_array_new ();

    collect_descendants (GTK_WIDGET (window), NAUTILUS_TYPE_VIEW_CONTROLS, controls);
    for (guint i = 0; i < controls->len; i++)
    {
        GtkWidget *stock = controls->pdata[i];
        AdwSplitButton *split = ADW_SPLIT_BUTTON (adw_bin_get_child (ADW_BIN (stock)));
        g_autoptr (GtkPopover) options = GTK_POPOVER (g_object_ref (adw_split_button_get_popover (split)));
        GtkWidget *apex;

        adw_split_button_set_popover (split, NULL);
        apex = apex_view_controls_new (watch, options);
        gtk_widget_insert_after (apex, gtk_widget_get_parent (stock), stock);
        g_object_bind_property (stock, "visible", apex, "visible", G_BINDING_SYNC_CREATE);
        gtk_widget_set_child_visible (stock, FALSE);
    }
}

void
apex_window_attach (AdwApplicationWindow *window,
                    GtkWidget            *places_sidebar,
                    GtkWidget            *tab_view)
{
    ApexSlotWatch *watch;
    GSimpleAction *show_details;
    GSimpleAction *show_recent;
    AdwToolbarView *sidebar_pane;

    if (g_strcmp0 (g_getenv (STOCK_ENV), "1") == 0)
    {
        return;
    }

    load_css_once ();
    gtk_widget_add_css_class (GTK_WIDGET (window), "apex");
    watch = apex_slot_watch_new (GTK_WINDOW (window));
    g_object_set_data_full (G_OBJECT (window), "apex-slot-watch", watch, g_object_unref);
    show_details = add_toggle_action (window, "show-details", APEX_KEY_DETAILS_PANE, FALSE);
    show_recent = add_toggle_action (window, "show-recent-strip", APEX_KEY_RECENT_STRIP, TRUE);

    sidebar_pane = ADW_TOOLBAR_VIEW (gtk_widget_get_ancestor (places_sidebar, ADW_TYPE_TOOLBAR_VIEW));
    attach_disk_footer (sidebar_pane, places_sidebar);
    attach_main_menu_items (sidebar_pane);
    attach_content (ADW_TOOLBAR_VIEW (gtk_widget_get_ancestor (tab_view, ADW_TYPE_TOOLBAR_VIEW)),
                    tab_view, watch, show_details, show_recent);
    replace_view_controls (window, watch);
}
