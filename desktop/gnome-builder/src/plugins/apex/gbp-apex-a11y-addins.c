/* SPDX-License-Identifier: GPL-3.0-or-later */

#define G_LOG_DOMAIN "gbp-apex-a11y"

#include "config.h"

#include <adwaita.h>
#include <glib/gi18n.h>

#include "apex-i18n.h"
#include "gbp-apex-a11y-addins.h"
#include "gbp-apex-sidebar.h"

/* E0's AT-SPI gaps: the editor's text, the icon-only menu buttons, the diagnostics button,
 * the tab lists, the page's progress bar, the project tree and its filter, empty labels. */

struct _GbpApexWorkspaceAddin
{
  GObject         parent_instance;
  IdeWorkspace   *workspace;
  GbpApexSidebar *sidebar;
};

struct _GbpApexEditorPageAddin
{
  GObject        parent_instance;
  IdeEditorPage *page;
  gulong         title_id;
};

static void workspace_addin_iface_init (IdeWorkspaceAddinInterface *iface);
static void editor_page_addin_iface_init (IdeEditorPageAddinInterface *iface);

G_DEFINE_FINAL_TYPE_WITH_CODE (GbpApexWorkspaceAddin, gbp_apex_workspace_addin, G_TYPE_OBJECT,
                               G_IMPLEMENT_INTERFACE (IDE_TYPE_WORKSPACE_ADDIN, workspace_addin_iface_init))
G_DEFINE_FINAL_TYPE_WITH_CODE (GbpApexEditorPageAddin, gbp_apex_editor_page_addin, G_TYPE_OBJECT,
                               G_IMPLEMENT_INTERFACE (IDE_TYPE_EDITOR_PAGE_ADDIN, editor_page_addin_iface_init))

static const char *
menu_button_name (GtkWidget  *button,
                  const char *icon_name)
{
  if (icon_name == NULL && gtk_widget_get_ancestor (button, PANEL_TYPE_OMNI_BAR) != NULL)
    return APEX_("Build Details");
  if (g_strcmp0 (icon_name, "list-add-symbolic") == 0)
    return APEX_("New Page");
  if (g_strcmp0 (icon_name, "open-menu-symbolic") == 0)
    return APEX_("Sidebar Menu");
  if (g_strcmp0 (icon_name, "pan-down-symbolic") == 0)
    return APEX_("Open Pages");
  return NULL;
}

static const char *
split_button_name (const char *icon_name)
{
  if (g_strcmp0 (icon_name, "builder-run-start-symbolic") == 0)
    return APEX_("Run Options");
  return NULL;
}

/* IdeRunButton keeps "Run Project" or "Stop Running Project" on itself; libadwaita
 * labels the split's main button with its dropdown's name otherwise. */
static void
name_split_main (GtkWidget *split)
{
  const char *text = gtk_widget_get_tooltip_text (gtk_widget_get_parent (split));

  if (text == NULL)
    text = APEX_("Run Project");

  for (GtkWidget *child = gtk_widget_get_first_child (split); child; child = gtk_widget_get_next_sibling (child))
    if (GTK_IS_BUTTON (child) && !GTK_IS_MENU_BUTTON (child) && text != NULL)
      {
        gtk_accessible_reset_relation (GTK_ACCESSIBLE (child), GTK_ACCESSIBLE_RELATION_LABELLED_BY);
        gtk_accessible_update_property (GTK_ACCESSIBLE (child), GTK_ACCESSIBLE_PROPERTY_LABEL, text, -1);
      }
}

static void
name_diagnostics (GtkWidget *button)
{
  IdeContext *context = ide_widget_get_context (button);
  IdeBuildManager *build_manager;
  g_autofree char *errors = NULL;
  g_autofree char *warnings = NULL;
  g_autofree char *label = NULL;
  guint n_errors;
  guint n_warnings;

  if (context == NULL)
    return;

  build_manager = ide_build_manager_from_context (context);
  n_errors = ide_build_manager_get_error_count (build_manager);
  n_warnings = ide_build_manager_get_warning_count (build_manager);
  errors = g_strdup_printf (APEX_NG_("%u error", "%u errors", n_errors), n_errors);
  warnings = g_strdup_printf (APEX_NG_("%u warning", "%u warnings", n_warnings), n_warnings);
  /* TRANSLATORS: the status bar's diagnostics button; the counts are "%u errors" and "%u warnings" */
  label = g_strdup_printf (APEX_("Build Diagnostics: %s, %s"), errors, warnings);
  gtk_accessible_update_property (GTK_ACCESSIBLE (button), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
}

static void
watch_diagnostics (GtkWidget *button)
{
  IdeContext *context = ide_widget_get_context (button);
  IdeBuildManager *build_manager;

  if (context == NULL || g_object_get_data (G_OBJECT (button), "apex-named") != NULL)
    return;

  g_object_set_data (G_OBJECT (button), "apex-named", GINT_TO_POINTER (1));
  build_manager = ide_build_manager_from_context (context);
  g_signal_connect_object (build_manager, "notify::error-count", G_CALLBACK (name_diagnostics), button, G_CONNECT_SWAPPED);
  g_signal_connect_object (build_manager, "notify::warning-count", G_CALLBACK (name_diagnostics), button, G_CONNECT_SWAPPED);
  name_diagnostics (button);
}

/* An empty status bar label (vim's command bar) is an empty node over AT-SPI, and the
 * hidden state does not remove it, so it is hidden while it has no text, even when its
 * owner shows it. */
static void
hide_if_empty (GtkLabel *label)
{
  const char *text = gtk_label_get_label (label);

  if (text == NULL || text[0] == 0)
    gtk_widget_set_visible (GTK_WIDGET (label), FALSE);
  else if (g_object_get_data (G_OBJECT (label), "apex-hid") != NULL)
    gtk_widget_set_visible (GTK_WIDGET (label), TRUE);

  g_object_set_data (G_OBJECT (label), "apex-hid", GINT_TO_POINTER (text == NULL || text[0] == 0));
}

static void
watch_label (GtkWidget *label)
{
  if (g_object_get_data (G_OBJECT (label), "apex-named") != NULL)
    return;

  g_object_set_data (G_OBJECT (label), "apex-named", GINT_TO_POINTER (1));
  g_signal_connect (label, "notify::label", G_CALLBACK (hide_if_empty), NULL);
  g_signal_connect (label, "notify::visible", G_CALLBACK (hide_if_empty), NULL);
  hide_if_empty (GTK_LABEL (label));
}

static void
label_widget (GtkWidget  *widget,
              const char *label)
{
  gtk_accessible_update_property (GTK_ACCESSIBLE (widget), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
}

static gboolean
is_diagnostics_button (GtkWidget *widget)
{
  return GTK_IS_MENU_BUTTON (widget) &&
         g_strcmp0 (gtk_widget_get_tooltip_text (widget), g_dgettext (GETTEXT_PACKAGE, "Display Build Diagnostics (Ctrl+Alt+?)")) == 0;
}

/* AdwTabBar's two tab lists, pinned tabs first, libpanel's switcher of a dock's panels, and
 * the diagnostics popover's switcher between errors and warnings. */
static void
name_tab_list (GtkWidget *widget)
{
  GtkWidget *bar = gtk_widget_get_ancestor (widget, ADW_TYPE_TAB_BAR);
  GtkWidget *popover;

  if (bar == NULL)
    {
      popover = gtk_widget_get_ancestor (widget, GTK_TYPE_POPOVER);
      if (PANEL_IS_FRAME_SWITCHER (widget) || gtk_widget_get_ancestor (widget, PANEL_TYPE_FRAME_SWITCHER) != NULL)
        label_widget (widget, APEX_("Panels"));
      else if (popover != NULL && is_diagnostics_button (gtk_widget_get_parent (popover)))
        label_widget (widget, APEX_("Diagnostics"));
      return;
    }

  if (g_object_get_data (G_OBJECT (bar), "apex-pinned") == NULL)
    g_object_set_data (G_OBJECT (bar), "apex-pinned", widget);
  label_widget (widget, g_object_get_data (G_OBJECT (bar), "apex-pinned") == widget ? APEX_("Pinned Pages") : APEX_("Pages"));
}

static void
name_widgets (GtkWidget *widget)
{
  GtkAccessibleRole role = gtk_accessible_get_accessible_role (GTK_ACCESSIBLE (widget));
  GtkWidget *panel;

  if (is_diagnostics_button (widget))
    watch_diagnostics (widget);
  else if (GTK_IS_LABEL (widget) && gtk_widget_get_ancestor (widget, PANEL_TYPE_STATUSBAR) != NULL &&
           gtk_widget_get_ancestor (widget, GTK_TYPE_POPOVER) == NULL &&
           gtk_widget_get_ancestor (widget, GTK_TYPE_BUTTON) == NULL)
    watch_label (widget);
  else if (role == GTK_ACCESSIBLE_ROLE_TAB_LIST)
    name_tab_list (widget);
  else if (GTK_IS_PROGRESS_BAR (widget) && gtk_widget_get_ancestor (widget, IDE_TYPE_PAGE) != NULL)
    label_widget (widget, APEX_("Progress"));
  else if (GTK_IS_SEARCH_ENTRY (widget) && gtk_search_entry_get_placeholder_text (GTK_SEARCH_ENTRY (widget)) != NULL)
    label_widget (widget, gtk_search_entry_get_placeholder_text (GTK_SEARCH_ENTRY (widget)));
  else if (GTK_IS_LIST_VIEW (widget) && (panel = gtk_widget_get_ancestor (widget, PANEL_TYPE_WIDGET)) != NULL &&
           !IDE_IS_PAGE (panel) && panel_widget_get_title (PANEL_WIDGET (panel)) != NULL)
    label_widget (widget, panel_widget_get_title (PANEL_WIDGET (panel)));

  if (GTK_IS_MENU_BUTTON (widget) && gtk_widget_get_tooltip_text (widget) == NULL)
    {
      const char *name = menu_button_name (widget, gtk_menu_button_get_icon_name (GTK_MENU_BUTTON (widget)));

      if (name != NULL)
        gtk_widget_set_tooltip_text (widget, name);
    }
  else if (ADW_IS_SPLIT_BUTTON (widget))
    {
      const char *name = split_button_name (adw_split_button_get_icon_name (ADW_SPLIT_BUTTON (widget)));

      if (name != NULL)
        adw_split_button_set_dropdown_tooltip (ADW_SPLIT_BUTTON (widget), name);

      /* IdeRunButton keeps "Run Project" or "Stop Running Project" on itself; its main button would otherwise take the dropdown's name. */
      if (name != NULL && g_object_get_data (G_OBJECT (widget), "apex-main-named") == NULL)
        {
          g_object_set_data (G_OBJECT (widget), "apex-main-named", GINT_TO_POINTER (1));
          g_signal_connect_object (gtk_widget_get_parent (widget), "notify::tooltip-text",
                                   G_CALLBACK (name_split_main), widget, G_CONNECT_SWAPPED);
          name_split_main (widget);
        }
    }

  for (GtkWidget *child = gtk_widget_get_first_child (widget); child; child = gtk_widget_get_next_sibling (child))
    name_widgets (child);
}

/* Other addins add their widgets (the status bar's diagnostics button) after this one loads. */
static gboolean
gbp_apex_workspace_addin_rescan (gpointer user_data)
{
  GbpApexWorkspaceAddin *self = user_data;

  if (self->workspace != NULL)
    name_widgets (GTK_WIDGET (self->workspace));

  return G_SOURCE_REMOVE;
}

static void
gbp_apex_workspace_addin_load (IdeWorkspaceAddin *addin,
                               IdeWorkspace      *workspace)
{
  GBP_APEX_WORKSPACE_ADDIN (addin)->workspace = workspace;
  GBP_APEX_WORKSPACE_ADDIN (addin)->sidebar = gbp_apex_sidebar_new (workspace);
  name_widgets (GTK_WIDGET (workspace));
  g_idle_add_full (G_PRIORITY_DEFAULT_IDLE, gbp_apex_workspace_addin_rescan, g_object_ref (addin), g_object_unref);
}

static void
gbp_apex_workspace_addin_unload (IdeWorkspaceAddin *addin,
                                 IdeWorkspace      *workspace)
{
  GBP_APEX_WORKSPACE_ADDIN (addin)->workspace = NULL;
  g_clear_object (&GBP_APEX_WORKSPACE_ADDIN (addin)->sidebar);
}

/* A new page can bring a new frame, and with it a tab bar. */
static void
gbp_apex_workspace_addin_page_changed (IdeWorkspaceAddin *addin,
                                       IdePage           *page)
{
  GbpApexWorkspaceAddin *self = GBP_APEX_WORKSPACE_ADDIN (addin);

  if (self->workspace != NULL)
    name_widgets (GTK_WIDGET (self->workspace));
  if (self->sidebar != NULL)
    gbp_apex_sidebar_selftest_drop (self->sidebar, page);
}

static void
gbp_apex_workspace_addin_restore_session (IdeWorkspaceAddin *addin,
                                          IdeSession        *session)
{
  GbpApexWorkspaceAddin *self = GBP_APEX_WORKSPACE_ADDIN (addin);

  if (self->sidebar != NULL)
    gbp_apex_sidebar_session_restored (self->sidebar);
}

static void
workspace_addin_iface_init (IdeWorkspaceAddinInterface *iface)
{
  iface->restore_session = gbp_apex_workspace_addin_restore_session;
  iface->load = gbp_apex_workspace_addin_load;
  iface->unload = gbp_apex_workspace_addin_unload;
  iface->page_changed = gbp_apex_workspace_addin_page_changed;
}

static void
gbp_apex_workspace_addin_class_init (GbpApexWorkspaceAddinClass *klass)
{
}

static void
gbp_apex_workspace_addin_init (GbpApexWorkspaceAddin *self)
{
}

static void
gbp_apex_editor_page_addin_name_view (GbpApexEditorPageAddin *self)
{
  g_autofree char *label = NULL;
  const char *title;

  if (self->page == NULL)
    return;

  title = panel_widget_get_title (PANEL_WIDGET (self->page));
  /* TRANSLATORS: the editor's accessible name; %s is the file */
  label = g_strdup_printf (APEX_("Editor for %s"), title ? title : "");
  gtk_accessible_update_property (GTK_ACCESSIBLE (ide_editor_page_get_view (self->page)),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL, label,
                                  -1);
}

static void
gbp_apex_editor_page_addin_load (IdeEditorPageAddin *addin,
                                 IdeEditorPage      *page)
{
  GbpApexEditorPageAddin *self = GBP_APEX_EDITOR_PAGE_ADDIN (addin);

  self->page = page;
  self->title_id = g_signal_connect_object (page, "notify::title",
                                            G_CALLBACK (gbp_apex_editor_page_addin_name_view),
                                            self, G_CONNECT_SWAPPED);
  gbp_apex_editor_page_addin_name_view (self);
}

static void
gbp_apex_editor_page_addin_unload (IdeEditorPageAddin *addin,
                                   IdeEditorPage      *page)
{
  GbpApexEditorPageAddin *self = GBP_APEX_EDITOR_PAGE_ADDIN (addin);

  g_clear_signal_handler (&self->title_id, page);
  self->page = NULL;
}

static void
editor_page_addin_iface_init (IdeEditorPageAddinInterface *iface)
{
  iface->load = gbp_apex_editor_page_addin_load;
  iface->unload = gbp_apex_editor_page_addin_unload;
}

static void
gbp_apex_editor_page_addin_class_init (GbpApexEditorPageAddinClass *klass)
{
}

static void
gbp_apex_editor_page_addin_init (GbpApexEditorPageAddin *self)
{
}
