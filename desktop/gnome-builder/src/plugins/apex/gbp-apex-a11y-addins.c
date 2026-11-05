/* SPDX-License-Identifier: GPL-3.0-or-later */

#define G_LOG_DOMAIN "gbp-apex-a11y"

#include "config.h"

#include <adwaita.h>

#include "apex-i18n.h"
#include "gbp-apex-a11y-addins.h"

/* E0's AT-SPI gaps: the editor's text and the icon-only menu buttons had no name. */

struct _GbpApexWorkspaceAddin
{
  GObject       parent_instance;
  IdeWorkspace *workspace;
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
name_widgets (GtkWidget *widget)
{
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

static void
gbp_apex_workspace_addin_load (IdeWorkspaceAddin *addin,
                               IdeWorkspace      *workspace)
{
  GBP_APEX_WORKSPACE_ADDIN (addin)->workspace = workspace;
  name_widgets (GTK_WIDGET (workspace));
}

static void
gbp_apex_workspace_addin_unload (IdeWorkspaceAddin *addin,
                                 IdeWorkspace      *workspace)
{
  GBP_APEX_WORKSPACE_ADDIN (addin)->workspace = NULL;
}

/* A new page can bring a new frame, and with it a tab bar. */
static void
gbp_apex_workspace_addin_page_changed (IdeWorkspaceAddin *addin,
                                       IdePage           *page)
{
  GbpApexWorkspaceAddin *self = GBP_APEX_WORKSPACE_ADDIN (addin);

  if (self->workspace != NULL)
    name_widgets (GTK_WIDGET (self->workspace));
}

static void
workspace_addin_iface_init (IdeWorkspaceAddinInterface *iface)
{
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
