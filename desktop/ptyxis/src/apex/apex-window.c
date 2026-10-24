/* SPDX-License-Identifier: GPL-3.0-or-later */

#include <glib/gi18n.h>

#include "apex-sidebar.h"
#include "apex-window.h"

#define SIDEBAR_WIDTH 272
#define STOCK_ENV "APEX_PTYXIS_STOCK"
#define SIDEBAR_KEY "apex-sidebar"

static GtkWidget *
template_child (PtyxisWindow *window,
                const char   *name)
{
  return GTK_WIDGET (gtk_widget_get_template_child (GTK_WIDGET (window), PTYXIS_TYPE_WINDOW, name));
}

static void
load_css_once (void)
{
  static gboolean loaded;
  g_autoptr(GtkCssProvider) provider = NULL;

  if (loaded)
    return;

  loaded = TRUE;
  provider = gtk_css_provider_new ();
  gtk_css_provider_load_from_resource (provider, "/org/gnome/Ptyxis/apex/apex.css");
  gtk_style_context_add_provider_for_display (gdk_display_get_default (),
                                              GTK_STYLE_PROVIDER (provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
}

static GtkWidget *
title_label (const char *css_class,
             gboolean    ellipsize)
{
  GtkWidget *label = gtk_label_new (NULL);

  gtk_widget_add_css_class (label, css_class);
  gtk_label_set_single_line_mode (GTK_LABEL (label), TRUE);
  if (ellipsize)
    gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_END);
  return label;
}

static GtkWidget *
session_title (ApexSidebar *sidebar)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *title = title_label ("apex-title", FALSE);
  GtkWidget *path = title_label ("apex-path", TRUE);
  GtkWidget *tag = title_label ("apex-tag", FALSE);
  GBindingGroup *bindings = g_binding_group_new ();

  gtk_widget_add_css_class (box, "apex-session-title");
  gtk_widget_set_valign (box, GTK_ALIGN_CENTER);
  gtk_box_append (GTK_BOX (box), title);
  gtk_box_append (GTK_BOX (box), path);
  gtk_box_append (GTK_BOX (box), tag);

  g_binding_group_bind (bindings, "title", title, "label", G_BINDING_SYNC_CREATE);
  g_binding_group_bind (bindings, "path", path, "label", G_BINDING_SYNC_CREATE);
  g_binding_group_bind (bindings, "tag", tag, "label", G_BINDING_SYNC_CREATE);
  g_object_bind_property (sidebar, "selected-session", bindings, "source", G_BINDING_SYNC_CREATE);
  g_object_set_data_full (G_OBJECT (box), "apex-bindings", bindings, g_object_unref);

  return box;
}

static GMenuModel *
session_menu (void)
{
  GMenu *menu = g_menu_new ();
  GMenu *section = g_menu_new ();

  g_menu_append (section, _("_Rename…"), "win.set-title");
  g_menu_append (section, _("Change _Profile…"), "win.set-profile");
  g_menu_append_section (menu, NULL, G_MENU_MODEL (section));
  g_object_unref (section);

  section = g_menu_new ();
  g_menu_append (section, _("Move to New _Window"), "page.detach");
  g_menu_append (section, _("_Close Session"), "page.close");
  g_menu_append_section (menu, NULL, G_MENU_MODEL (section));
  g_object_unref (section);

  return G_MENU_MODEL (menu);
}

static void
restyle_header (PtyxisWindow *window,
                ApexSidebar  *sidebar)
{
  AdwHeaderBar *header = ADW_HEADER_BAR (template_child (window, "header_bar"));
  g_autoptr(GMenuModel) menu = session_menu ();
  GtkWidget *menu_button = gtk_menu_button_new ();
  GtkWidget *find = gtk_button_new_from_icon_name ("edit-find-symbolic");

  gtk_widget_set_visible (template_child (window, "new_tab_box"), FALSE);
  gtk_widget_set_visible (template_child (window, "tab_overview_button"), FALSE);
  gtk_widget_set_visible (template_child (window, "primary_menu_button"), FALSE);

  gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (menu_button), "view-more-symbolic");
  gtk_menu_button_set_menu_model (GTK_MENU_BUTTON (menu_button), menu);
  gtk_widget_set_tooltip_text (menu_button, _("Session Menu"));

  gtk_actionable_set_action_name (GTK_ACTIONABLE (find), "win.search");
  gtk_widget_set_tooltip_text (find, _("Find"));

  gtk_widget_add_css_class (GTK_WIDGET (header), "apex-session-header");
  adw_header_bar_set_show_title (header, FALSE);
  adw_header_bar_pack_start (header, session_title (sidebar));
  adw_header_bar_pack_end (header, menu_button);
  adw_header_bar_pack_end (header, find);
}

static void
window_active_cb (GtkWindow   *window,
                  GParamSpec  *pspec,
                  ApexSidebar *sidebar)
{
  ApexSession *session = apex_sidebar_get_selected_session (sidebar);

  if (session != NULL && gtk_window_is_active (window))
    apex_session_focused (session);
}

/* Ptyxis sets its own color-scheme on the style manager, which GTK's
 * prefers-color-scheme media query does not follow. */
static void
style_dark_cb (AdwStyleManager *style_manager,
               GParamSpec      *pspec,
               GtkWidget       *window)
{
  if (adw_style_manager_get_dark (style_manager))
    gtk_widget_add_css_class (window, "apex-dark");
  else
    gtk_widget_remove_css_class (window, "apex-dark");
}

void
apex_window_attach (PtyxisWindow *window)
{
  AdwApplicationWindow *app_window = ADW_APPLICATION_WINDOW (window);
  AdwTabView *tab_view = ADW_TAB_VIEW (template_child (window, "tab_view"));
  GtkMenuButton *primary = GTK_MENU_BUTTON (template_child (window, "primary_menu_button"));
  g_autoptr(GtkWidget) content = NULL;
  GtkWidget *split;
  GtkWidget *sidebar;

  if (g_strcmp0 (g_getenv (STOCK_ENV), "1") == 0)
    return;

  load_css_once ();

  sidebar = apex_sidebar_new (tab_view, gtk_menu_button_get_menu_model (primary));
  g_object_set_data (G_OBJECT (window), SIDEBAR_KEY, sidebar);
  restyle_header (window, APEX_SIDEBAR (sidebar));

  content = g_object_ref (adw_application_window_get_content (app_window));
  adw_application_window_set_content (app_window, NULL);

  split = adw_overlay_split_view_new ();
  adw_overlay_split_view_set_min_sidebar_width (ADW_OVERLAY_SPLIT_VIEW (split), SIDEBAR_WIDTH);
  adw_overlay_split_view_set_max_sidebar_width (ADW_OVERLAY_SPLIT_VIEW (split), SIDEBAR_WIDTH);
  adw_overlay_split_view_set_sidebar (ADW_OVERLAY_SPLIT_VIEW (split), sidebar);
  adw_overlay_split_view_set_content (ADW_OVERLAY_SPLIT_VIEW (split), content);
  adw_application_window_set_content (app_window, split);

  g_signal_connect_object (window, "notify::is-active", G_CALLBACK (window_active_cb), sidebar, 0);

  gtk_widget_add_css_class (GTK_WIDGET (window), "apex");
  g_signal_connect_object (adw_style_manager_get_default (), "notify::dark", G_CALLBACK (style_dark_cb), window, 0);
  style_dark_cb (adw_style_manager_get_default (), NULL, GTK_WIDGET (window));
}

gboolean
apex_window_shows_sessions (PtyxisWindow *window)
{
  return g_object_get_data (G_OBJECT (window), SIDEBAR_KEY) != NULL;
}
