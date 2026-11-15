/* SPDX-License-Identifier: GPL-3.0-or-later */

/* Boards 40 to 42's sidebar (apex's docs/design/apex-code-boards-40-42.md, section 6): a segmented
 * switcher over Builder's own start frame; pages the boards do not show go to the bottom panel. */

#define G_LOG_DOMAIN "gbp-apex-sidebar"

#include "config.h"

#include <adwaita.h>
#include <libide-editor.h>
#include <libide-gui.h>

#include "apex-i18n.h"
#include "gbp-apex-outline-pane.h"
#include "gbp-apex-sidebar.h"

typedef struct
{
  const char *type_name;
  const char *name;
  const char *icon_name;
} View;

/* The board's order: Project, Outline, Search, Version control; the later views add their panes. */
static const View views[] = {
  { "GbpProjectTreePane", APEX_N_("Project"), "text-x-generic-symbolic" },
  { "GbpApexOutlinePane", APEX_N_("Outline"), "view-list-symbolic" },
};

static const View *
view_of (PanelWidget *page)
{
  const char *type_name = G_OBJECT_TYPE_NAME (page);

  for (guint i = 0; i < G_N_ELEMENTS (views); i++)
    if (g_strcmp0 (type_name, views[i].type_name) == 0)
      return &views[i];

  return NULL;
}

static guint
rank_of (PanelWidget *page)
{
  const View *view = view_of (page);

  return view != NULL ? (guint) (view - views) : G_N_ELEMENTS (views);
}

const char *
gbp_apex_sidebar_view_name (PanelWidget *page)
{
  const View *view = view_of (page);

  return view != NULL ? APEX_(view->name) : NULL;
}

/* The frame's pages are AdwTabPages; each one's child is the PanelWidget. */
static PanelWidget *
page_at (GListModel *pages,
         guint       position)
{
  g_autoptr(AdwTabPage) tab = g_list_model_get_item (pages, position);

  return tab != NULL ? g_object_ref (PANEL_WIDGET (adw_tab_page_get_child (tab))) : NULL;
}

struct _GbpApexSidebarHeader
{
  GtkWidget       parent_instance;
  PanelFrame     *frame;
  GListModel     *pages;
  GtkWidget      *box;
  GtkWidget      *prefix;
  AdwToggleGroup *group;
  GtkWidget      *suffix;
  gulong          items_changed_id;
  guint           syncing : 1;
};

enum { PROP_0, PROP_FRAME, N_PROPS };

static void frame_header_iface_init (PanelFrameHeaderInterface *iface);

G_DEFINE_FINAL_TYPE_WITH_CODE (GbpApexSidebarHeader, gbp_apex_sidebar_header, GTK_TYPE_WIDGET,
                               G_IMPLEMENT_INTERFACE (PANEL_TYPE_FRAME_HEADER, frame_header_iface_init))

/* AdwToggleGroup marks its tabs checked; a tab list's reader wants the selected one. */
static void
sync_selected (GbpApexSidebarHeader *self)
{
  for (GtkWidget *child = gtk_widget_get_first_child (GTK_WIDGET (self->group));
       child != NULL;
       child = gtk_widget_get_next_sibling (child))
    {
      if (GTK_IS_TOGGLE_BUTTON (child))
        gtk_accessible_update_state (GTK_ACCESSIBLE (child), GTK_ACCESSIBLE_STATE_SELECTED,
                                     gtk_toggle_button_get_active (GTK_TOGGLE_BUTTON (child)), -1);
    }
}

static void
select_page (GbpApexSidebarHeader *self,
             PanelWidget          *page)
{
  g_autofree char *name = NULL;

  if (page == NULL || self->pages == NULL)
    return;

  for (guint i = 0; i < g_list_model_get_n_items (self->pages); i++)
    {
      g_autoptr(PanelWidget) item = page_at (self->pages, i);

      if (item == page)
        name = g_strdup_printf ("%u", i);
    }

  self->syncing = TRUE;
  adw_toggle_group_set_active_name (self->group, name);
  self->syncing = FALSE;
  sync_selected (self);
}

static void
add_toggle (GbpApexSidebarHeader *self,
            PanelWidget          *page,
            guint                 position)
{
  g_autofree char *name = g_strdup_printf ("%u", position);
  const View *view = view_of (page);
  AdwToggle *toggle = adw_toggle_new ();
  const char *label = view != NULL ? APEX_(view->name) : panel_widget_get_title (page);

  adw_toggle_set_name (toggle, name);
  adw_toggle_set_icon_name (toggle, view != NULL ? view->icon_name : panel_widget_get_icon_name (page));
  adw_toggle_set_tooltip (toggle, label);
  adw_toggle_group_add (self->group, toggle);
}

static void
rebuild (GbpApexSidebarHeader *self)
{
  self->syncing = TRUE;
  adw_toggle_group_remove_all (self->group);

  /* The board's order, whatever order the plugins added their pages in. */
  for (guint rank = 0; self->pages != NULL && rank <= G_N_ELEMENTS (views); rank++)
    {
      for (guint i = 0; i < g_list_model_get_n_items (self->pages); i++)
        {
          g_autoptr(PanelWidget) page = page_at (self->pages, i);

          if (rank_of (page) == rank)
            add_toggle (self, page, i);
        }
    }

  self->syncing = FALSE;

  if (self->frame != NULL)
    select_page (self, panel_frame_get_visible_child (self->frame));
}

static void
active_name_changed (GbpApexSidebarHeader *self)
{
  const char *name = adw_toggle_group_get_active_name (self->group);
  g_autoptr(PanelWidget) page = NULL;

  sync_selected (self);
  if (self->syncing || self->frame == NULL || name == NULL)
    return;

  if ((page = page_at (self->pages, (guint) g_ascii_strtoull (name, NULL, 10))))
    panel_frame_set_visible_child (self->frame, page);
}

static void
set_frame (GbpApexSidebarHeader *self,
           PanelFrame           *frame)
{
  if (self->frame == frame)
    return;

  if (self->pages != NULL)
    g_clear_signal_handler (&self->items_changed_id, self->pages);
  g_clear_object (&self->pages);
  g_set_weak_pointer (&self->frame, frame);

  if (frame != NULL)
    {
      self->pages = G_LIST_MODEL (panel_frame_get_pages (frame));
      self->items_changed_id = g_signal_connect_object (self->pages, "items-changed",
                                                        G_CALLBACK (rebuild), self, G_CONNECT_SWAPPED);
    }

  rebuild (self);
  g_object_notify (G_OBJECT (self), "frame");
}

static void
page_changed (PanelFrameHeader *header,
              PanelWidget      *page)
{
  select_page (GBP_APEX_SIDEBAR_HEADER (header), page);
}

/* Only the boards' views: a document dropped here would leave the grid, and its unsaved edits the
 * close prompt; any other pane would only move back to the bottom panel. */
static gboolean
can_drop (PanelFrameHeader *header,
          PanelWidget      *page)
{
  return view_of (page) != NULL;
}

static void
add_prefix (PanelFrameHeader *header,
            int               priority,
            GtkWidget        *child)
{
  gtk_box_append (GTK_BOX (GBP_APEX_SIDEBAR_HEADER (header)->prefix), child);
}

static void
add_suffix (PanelFrameHeader *header,
            int               priority,
            GtkWidget        *child)
{
  gtk_box_append (GTK_BOX (GBP_APEX_SIDEBAR_HEADER (header)->suffix), child);
}

static void
frame_header_iface_init (PanelFrameHeaderInterface *iface)
{
  iface->page_changed = page_changed;
  iface->can_drop = can_drop;
  iface->add_prefix = add_prefix;
  iface->add_suffix = add_suffix;
}

static void
gbp_apex_sidebar_header_dispose (GObject *object)
{
  GbpApexSidebarHeader *self = GBP_APEX_SIDEBAR_HEADER (object);

  set_frame (self, NULL);
  g_clear_pointer (&self->box, gtk_widget_unparent);

  G_OBJECT_CLASS (gbp_apex_sidebar_header_parent_class)->dispose (object);
}

static void
gbp_apex_sidebar_header_get_property (GObject    *object,
                                      guint       prop_id,
                                      GValue     *value,
                                      GParamSpec *pspec)
{
  if (prop_id == PROP_FRAME)
    g_value_set_object (value, GBP_APEX_SIDEBAR_HEADER (object)->frame);
  else
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
}

static void
gbp_apex_sidebar_header_set_property (GObject      *object,
                                      guint         prop_id,
                                      const GValue *value,
                                      GParamSpec   *pspec)
{
  if (prop_id == PROP_FRAME)
    set_frame (GBP_APEX_SIDEBAR_HEADER (object), g_value_get_object (value));
  else
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
}

static void
gbp_apex_sidebar_header_class_init (GbpApexSidebarHeaderClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

  object_class->dispose = gbp_apex_sidebar_header_dispose;
  object_class->get_property = gbp_apex_sidebar_header_get_property;
  object_class->set_property = gbp_apex_sidebar_header_set_property;
  g_object_class_override_property (object_class, PROP_FRAME, "frame");

  gtk_widget_class_set_layout_manager_type (widget_class, GTK_TYPE_BIN_LAYOUT);
  gtk_widget_class_set_css_name (widget_class, "apexsidebarviews");
}

static void
follow_dark (GtkWidget *widget)
{
  if (adw_style_manager_get_dark (adw_style_manager_get_default ()))
    gtk_widget_add_css_class (widget, "dark");
  else
    gtk_widget_remove_css_class (widget, "dark");
}

void
gbp_apex_track_dark (GtkWidget *widget)
{
  g_signal_connect_object (adw_style_manager_get_default (), "notify::dark", G_CALLBACK (follow_dark), widget, G_CONNECT_SWAPPED);
  follow_dark (widget);
}

static void
gbp_apex_sidebar_header_init (GbpApexSidebarHeader *self)
{
  self->box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  self->prefix = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  self->suffix = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  /* As AdwInlineViewSwitcher does: a tab list's toggles are tabs. */
  self->group = g_object_new (ADW_TYPE_TOGGLE_GROUP, "accessible-role", GTK_ACCESSIBLE_ROLE_TAB_LIST, NULL);
  gtk_widget_set_hexpand (GTK_WIDGET (self->group), TRUE);
  adw_toggle_group_set_homogeneous (self->group, TRUE);
  gtk_box_append (GTK_BOX (self->box), self->prefix);
  gtk_box_append (GTK_BOX (self->box), GTK_WIDGET (self->group));
  gtk_box_append (GTK_BOX (self->box), self->suffix);
  gtk_widget_set_parent (self->box, GTK_WIDGET (self));
  g_signal_connect_object (self->group, "notify::active-name", G_CALLBACK (active_name_changed), self, G_CONNECT_SWAPPED);

  gtk_accessible_update_property (GTK_ACCESSIBLE (self->group), GTK_ACCESSIBLE_PROPERTY_LABEL, APEX_("Sidebar views"), -1);
  gbp_apex_track_dark (GTK_WIDGET (self));
}

/* The switcher on the workspace's first start frame, and the start frames' pages; the workspace addin holds it. */
struct _GbpApexSidebar
{
  GObject       parent_instance;
  IdeWorkspace *workspace;
  PanelFrame   *frame;
  PanelPaned   *paned;
  GPtrArray    *watched;
  GtkWidget    *outline;
  guint         relocate_source;
};

G_DEFINE_FINAL_TYPE (GbpApexSidebar, gbp_apex_sidebar, G_TYPE_OBJECT)

static void queue_relocate (GbpApexSidebar *self);

typedef struct
{
  GbpApexSidebar *self;
  GPtrArray      *others;
  GPtrArray      *strays;
} Sweep;

/* Every frame of the start area's paned: the first one's, and any a restored session split off. */
static void
sweep_frame (PanelFrame *frame,
             Sweep      *sweep)
{
  g_autoptr(GListModel) pages = NULL;

  pages = G_LIST_MODEL (panel_frame_get_pages (frame));
  if (!g_ptr_array_find (sweep->self->watched, pages, NULL))
    {
      g_signal_connect_object (pages, "items-changed", G_CALLBACK (queue_relocate), sweep->self, G_CONNECT_SWAPPED);
      g_ptr_array_add (sweep->self->watched, g_object_ref (pages));
    }

  for (guint i = 0; i < g_list_model_get_n_items (pages); i++)
    {
      g_autoptr(PanelWidget) page = page_at (pages, i);

      if (view_of (page) == NULL && IDE_IS_PANE (page))
        g_ptr_array_add (sweep->others, g_steal_pointer (&page));
      else if (view_of (page) != NULL && frame != sweep->self->frame)
        g_ptr_array_add (sweep->strays, g_steal_pointer (&page));
    }
}

static void
block_presented (GPtrArray *pages,
                 gboolean   block)
{
  guint presented = g_signal_lookup ("presented", PANEL_TYPE_WIDGET);

  for (guint i = 0; i < pages->len; i++)
    {
      if (block)
        g_signal_handlers_block_matched (g_ptr_array_index (pages, i), G_SIGNAL_MATCH_ID, presented, 0, NULL, NULL, NULL);
      else
        g_signal_handlers_unblock_matched (g_ptr_array_index (pages, i), G_SIGNAL_MATCH_ID, presented, 0, NULL, NULL, NULL);
    }
}

/* A page the boards do not show (Build Pipeline, Manuals, TODO/FIXMEs, Unit Tests) moves to the bottom
 * panel as a tab: still there, and reached as upstream reaches it. A board view in another start frame
 * joins the switcher's. Neither move "presents" a page: TODO/FIXMEs would mine the project for it. */
static gboolean
relocate (gpointer user_data)
{
  GbpApexSidebar *self = user_data;
  g_autoptr(GPtrArray) others = g_ptr_array_new_with_free_func (g_object_unref);
  g_autoptr(GPtrArray) strays = g_ptr_array_new_with_free_func (g_object_unref);
  Sweep sweep = { self, others, strays };

  self->relocate_source = 0;
  if (self->frame == NULL || self->paned == NULL || self->workspace == NULL)
    return G_SOURCE_REMOVE;

  for (guint i = 0; i < panel_paned_get_n_children (self->paned); i++)
    {
      GtkWidget *child = panel_paned_get_nth_child (self->paned, i);

      if (PANEL_IS_FRAME (child))
        sweep_frame (PANEL_FRAME (child), &sweep);
    }

  block_presented (others, TRUE);
  for (guint i = 0; i < others->len; i++)
    {
      PanelWidget *page = g_ptr_array_index (others, i);
      PanelFrame *frame = PANEL_FRAME (gtk_widget_get_ancestor (GTK_WIDGET (page), PANEL_TYPE_FRAME));
      g_autoptr(PanelPosition) position = panel_position_new ();

      g_debug ("%s moves to the bottom panel", G_OBJECT_TYPE_NAME (page));
      panel_frame_remove (frame, page);
      panel_position_set_area (position, PANEL_AREA_BOTTOM);
      ide_workspace_add_pane (self->workspace, IDE_PANE (page), position);
    }
  block_presented (others, FALSE);

  for (guint i = 0; i < strays->len; i++)
    {
      PanelWidget *page = g_ptr_array_index (strays, i);

      g_debug ("%s joins the sidebar's switcher", G_OBJECT_TYPE_NAME (page));
      panel_frame_remove (PANEL_FRAME (gtk_widget_get_ancestor (GTK_WIDGET (page), PANEL_TYPE_FRAME)), page);
      panel_frame_add (self->frame, page);
    }

  return G_SOURCE_REMOVE;
}

static void
queue_relocate (GbpApexSidebar *self)
{
  if (self->relocate_source == 0)
    self->relocate_source = g_idle_add (relocate, self);
}

void
gbp_apex_sidebar_session_restored (GbpApexSidebar *self)
{
  g_return_if_fail (GBP_IS_APEX_SIDEBAR (self));

  queue_relocate (self);
}

GbpApexSidebar *
gbp_apex_sidebar_new (IdeWorkspace *workspace)
{
  GbpApexSidebar *self;
  g_autoptr(PanelPosition) position = NULL;
  PanelFrameHeader *header;

  if (!IDE_IS_PRIMARY_WORKSPACE (workspace) && !IDE_IS_EDITOR_WORKSPACE (workspace))
    return NULL;

  self = g_object_new (GBP_TYPE_APEX_SIDEBAR, NULL);
  self->workspace = workspace;
  position = panel_position_new ();
  panel_position_set_area (position, PANEL_AREA_START);
  if (!(self->frame = ide_workspace_get_frame_at_position (workspace, position)))
    return self;
  self->paned = PANEL_PANED (gtk_widget_get_ancestor (GTK_WIDGET (self->frame), PANEL_TYPE_PANED));

  header = PANEL_FRAME_HEADER (g_object_new (GBP_TYPE_APEX_SIDEBAR_HEADER, NULL));
  panel_frame_set_header (self->frame, header);
  panel_frame_header_set_frame (header, self->frame);
  self->outline = GTK_WIDGET (gbp_apex_outline_pane_new ());
  g_object_add_weak_pointer (G_OBJECT (self->outline), (gpointer *) &self->outline);
  ide_workspace_add_pane (workspace, IDE_PANE (self->outline), position);
  relocate (self);

  return self;
}

void
gbp_apex_sidebar_page_changed (GbpApexSidebar *self,
                               IdePage        *page)
{
  g_return_if_fail (GBP_IS_APEX_SIDEBAR (self));

  if (self->outline != NULL)
    gbp_apex_outline_pane_set_page (GBP_APEX_OUTLINE_PANE (self->outline), page);
}

static void
gbp_apex_sidebar_dispose (GObject *object)
{
  GbpApexSidebar *self = GBP_APEX_SIDEBAR (object);

  if (self->outline != NULL)
    g_object_remove_weak_pointer (G_OBJECT (self->outline), (gpointer *) &self->outline);
  self->outline = NULL;
  g_clear_handle_id (&self->relocate_source, g_source_remove);
  for (guint i = 0; self->watched != NULL && i < self->watched->len; i++)
    g_signal_handlers_disconnect_by_data (g_ptr_array_index (self->watched, i), self);
  g_clear_pointer (&self->watched, g_ptr_array_unref);
  self->frame = NULL;
  self->paned = NULL;
  self->workspace = NULL;

  G_OBJECT_CLASS (gbp_apex_sidebar_parent_class)->dispose (object);
}

static void
gbp_apex_sidebar_class_init (GbpApexSidebarClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = gbp_apex_sidebar_dispose;
}

static void
gbp_apex_sidebar_init (GbpApexSidebar *self)
{
  self->watched = g_ptr_array_new_with_free_func (g_object_unref);
}
