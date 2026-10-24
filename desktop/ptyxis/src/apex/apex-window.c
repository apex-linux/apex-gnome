/* SPDX-License-Identifier: GPL-3.0-or-later */

#include <glib/gi18n.h>

#include "apex-panes.h"
#include "apex-sidebar.h"
#include "apex-window.h"

#define SIDEBAR_WIDTH 272
#define STOCK_ENV "APEX_PTYXIS_STOCK"
#define SIDEBAR_KEY "apex-sidebar"
#define PANES_KEY "apex-panes"

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

typedef struct
{
  GtkWidget       *title;
  GtkWidget       *path;
  GtkWidget       *tag;
  GtkToggleButton *right;
  GtkToggleButton *down;
  ApexSession     *session;
  gboolean         syncing;
} SessionHeader;

static void
session_header_update (SessionHeader *h)
{
  ApexSplit split = h->session != NULL ? apex_session_get_split (h->session) : APEX_SPLIT_NONE;

  if (h->session == NULL)
    return;

  gtk_label_set_label (GTK_LABEL (h->title), apex_session_get_title (h->session));
  gtk_label_set_label (GTK_LABEL (h->path), split != APEX_SPLIT_NONE ? _("2 panes") : apex_session_get_path (h->session));
  gtk_label_set_label (GTK_LABEL (h->tag), apex_session_get_tag (h->session));
  gtk_widget_set_visible (h->tag, split == APEX_SPLIT_NONE);

  h->syncing = TRUE;
  gtk_toggle_button_set_active (h->right, split == APEX_SPLIT_RIGHT);
  gtk_toggle_button_set_active (h->down, split == APEX_SPLIT_DOWN);
  h->syncing = FALSE;
}

static void
session_header_selected_cb (ApexSidebar   *sidebar,
                            GParamSpec    *pspec,
                            SessionHeader *h)
{
  ApexSession *session = apex_sidebar_get_selected_session (sidebar);

  if (h->session != NULL)
    g_signal_handlers_disconnect_by_data (h->session, h);
  g_set_object (&h->session, session);

  if (session != NULL)
    {
      g_signal_connect_swapped (session, "notify::title", G_CALLBACK (session_header_update), h);
      g_signal_connect_swapped (session, "notify::path", G_CALLBACK (session_header_update), h);
      g_signal_connect_swapped (session, "notify::tag", G_CALLBACK (session_header_update), h);
      g_signal_connect_swapped (session, "notify::split", G_CALLBACK (session_header_update), h);
    }
  session_header_update (h);
}

static void
split_toggled_cb (GtkToggleButton *button,
                  SessionHeader   *h)
{
  if (!h->syncing)
    gtk_widget_activate_action (GTK_WIDGET (button),
                                button == h->right ? "apex.split-right" : "apex.split-down", NULL);
}

static void
session_header_free (gpointer data)
{
  SessionHeader *h = data;

  if (h->session != NULL)
    g_signal_handlers_disconnect_by_data (h->session, h);
  g_clear_object (&h->session);
  g_free (h);
}

static GtkToggleButton *
split_button (const char    *icon_name,
              const char    *tooltip,
              SessionHeader *h)
{
  GtkWidget *button = gtk_toggle_button_new ();

  gtk_button_set_icon_name (GTK_BUTTON (button), icon_name);
  gtk_widget_set_tooltip_text (button, tooltip);
  gtk_widget_add_css_class (button, "flat");
  g_signal_connect (button, "toggled", G_CALLBACK (split_toggled_cb), h);
  return GTK_TOGGLE_BUTTON (button);
}

static GtkWidget *
session_title (ApexSidebar   *sidebar,
               SessionHeader *h)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);

  h->title = title_label ("apex-title", FALSE);
  h->path = title_label ("apex-path", TRUE);
  h->tag = title_label ("apex-tag", FALSE);

  gtk_widget_add_css_class (box, "apex-session-title");
  gtk_widget_set_valign (box, GTK_ALIGN_CENTER);
  gtk_box_append (GTK_BOX (box), h->title);
  gtk_box_append (GTK_BOX (box), h->path);
  gtk_box_append (GTK_BOX (box), h->tag);

  g_signal_connect (sidebar, "notify::selected-session", G_CALLBACK (session_header_selected_cb), h);
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
  SessionHeader *h = g_new0 (SessionHeader, 1);

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
  h->right = split_button ("view-dual-symbolic", _("Split Right"), h);
  h->down = split_button ("view-paged-symbolic", _("Split Down"), h);

  adw_header_bar_pack_start (header, session_title (sidebar, h));
  adw_header_bar_pack_end (header, menu_button);
  adw_header_bar_pack_end (header, find);
  adw_header_bar_pack_end (header, GTK_WIDGET (h->down));
  adw_header_bar_pack_end (header, GTK_WIDGET (h->right));
  g_object_set_data_full (G_OBJECT (header), "apex-session-header", h, session_header_free);
  session_header_selected_cb (sidebar, NULL, h);
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

  g_object_set_data (G_OBJECT (window), PANES_KEY, apex_panes_attach (window, tab_view));
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


  gtk_widget_add_css_class (GTK_WIDGET (window), "apex");
  g_signal_connect_object (adw_style_manager_get_default (), "notify::dark", G_CALLBACK (style_dark_cb), window, 0);
  style_dark_cb (adw_style_manager_get_default (), NULL, GTK_WIDGET (window));
}

PtyxisTab *
apex_window_focused_pane (PtyxisWindow *window)
{
  return apex_panes_focused_second (g_object_get_data (G_OBJECT (window), PANES_KEY));
}

gboolean
apex_window_shows_sessions (PtyxisWindow *window)
{
  return g_object_get_data (G_OBJECT (window), SIDEBAR_KEY) != NULL;
}
