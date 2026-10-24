/* SPDX-License-Identifier: GPL-3.0-or-later */

#include <glib/gi18n.h>

#include "apex-glyph.h"
#include "apex-session-row.h"
#include "apex-sidebar.h"

#define WHEN_TICK_SECONDS 30
#define FOOTER_GLYPH_SIZE 14

typedef struct
{
  ApexStatus  status;
  GtkWidget  *box;
  GtkWidget  *label;
} FooterCount;

struct _ApexSidebar
{
  AdwBin          parent_instance;

  AdwTabView     *tab_view;
  GtkSorter      *sorter;
  GListModel     *sessions;
  GtkListBox     *list;
  FooterCount     counts[4];
  ApexSession    *selected;
  guint           tick_id;
  gboolean        syncing;
};

enum {
  PROP_0,
  PROP_SELECTED_SESSION,
  N_PROPS
};

G_DEFINE_FINAL_TYPE (ApexSidebar, apex_sidebar, ADW_TYPE_BIN)

static GParamSpec *properties[N_PROPS];

static const ApexStatus footer_order[] = {
  APEX_STATUS_NEEDS_YOU, APEX_STATUS_RUNNING, APEX_STATUS_FAILED, APEX_STATUS_DONE,
};

static char *
count_text (ApexStatus status,
            guint      n)
{
  switch (status)
    {
    case APEX_STATUS_NEEDS_YOU:
      return g_strdup_printf (ngettext ("%u session needs you", "%u sessions need you", n), n);
    case APEX_STATUS_RUNNING:
      return g_strdup_printf (_("%u running"), n);
    case APEX_STATUS_FAILED:
      return g_strdup_printf (_("%u failed"), n);
    case APEX_STATUS_DONE:
    case APEX_STATUS_IDLE:
    default:
      return g_strdup_printf (_("%u done"), n);
    }
}

static guint
count_sessions (ApexSidebar *self,
                ApexStatus   status,
                const char  *group_key)
{
  guint n_items = g_list_model_get_n_items (self->sessions);
  guint n = 0;

  for (guint i = 0; i < n_items; i++)
    {
      g_autoptr(ApexSession) session = g_list_model_get_item (self->sessions, i);

      if (apex_session_get_status (session) == status &&
          (group_key == NULL || g_strcmp0 (apex_session_get_group_key (session), group_key) == 0))
        n++;
    }

  return n;
}

static void
apex_sidebar_update_footer (ApexSidebar *self)
{
  for (guint i = 0; i < G_N_ELEMENTS (self->counts); i++)
    {
      FooterCount *c = &self->counts[i];
      guint n = count_sessions (self, c->status, NULL);
      g_autofree char *number = g_strdup_printf ("%u", n);
      g_autofree char *text = count_text (c->status, n);

      gtk_label_set_label (GTK_LABEL (c->label), number);
      gtk_accessible_update_property (GTK_ACCESSIBLE (c->box), GTK_ACCESSIBLE_PROPERTY_LABEL, text, -1);
      gtk_widget_set_tooltip_text (c->box, text);
    }
}

static ApexGlyphKind
group_glyph (const char *group_key)
{
  switch (group_key[0])
    {
    case '1':
      return APEX_GLYPH_CONTAINER;
    case '2':
      return APEX_GLYPH_REMOTE;
    default:
      return APEX_GLYPH_HOST;
    }
}

static GtkWidget *
group_header (ApexSidebar *self,
              ApexSession *session,
              gboolean     first)
{
  const char *key = apex_session_get_group_key (session);
  const char *pill = apex_session_get_group_pill (session);
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *label = gtk_label_new (apex_session_get_group_label (session));
  guint needs = count_sessions (self, APEX_STATUS_NEEDS_YOU, key);

  gtk_widget_add_css_class (box, "apex-group");
  if (first)
    gtk_widget_add_css_class (box, "first");
  gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_END);
  gtk_label_set_xalign (GTK_LABEL (label), 0);

  gtk_box_append (GTK_BOX (box), apex_glyph_new (group_glyph (key), 16));
  gtk_box_append (GTK_BOX (box), label);

  if (pill != NULL)
    {
      GtkWidget *tag = gtk_label_new (pill);

      gtk_widget_add_css_class (tag, "apex-tag");
      gtk_box_append (GTK_BOX (box), tag);
    }

  if (needs > 0)
    {
      g_autofree char *text = g_strdup_printf (_("%u needs you"), needs);
      GtkWidget *needs_label = gtk_label_new (text);

      gtk_widget_set_hexpand (needs_label, TRUE);
      gtk_label_set_xalign (GTK_LABEL (needs_label), 1);
      gtk_widget_add_css_class (needs_label, "needs-you");
      gtk_box_append (GTK_BOX (box), needs_label);
    }

  return box;
}

static void
apex_sidebar_header_func (GtkListBoxRow *row,
                          GtkListBoxRow *before,
                          gpointer       user_data)
{
  ApexSidebar *self = user_data;
  ApexSession *session = apex_session_row_get_session (APEX_SESSION_ROW (row));

  if (before != NULL &&
      g_strcmp0 (apex_session_get_group_key (session),
                 apex_session_get_group_key (apex_session_row_get_session (APEX_SESSION_ROW (before)))) == 0)
    {
      gtk_list_box_row_set_header (row, NULL);
      return;
    }

  gtk_list_box_row_set_header (row, group_header (self, session, before == NULL));
}

static void
apex_sidebar_status_changed (ApexSidebar *self)
{
  apex_sidebar_update_footer (self);
  gtk_list_box_invalidate_headers (self->list);
}

static void
apex_sidebar_group_changed (ApexSidebar *self)
{
  gtk_sorter_changed (self->sorter, GTK_SORTER_CHANGE_DIFFERENT);
}

static void
apex_sidebar_select_row_of (ApexSidebar *self,
                            ApexSession *session)
{
  guint n_items = g_list_model_get_n_items (self->sessions);

  for (guint i = 0; i < n_items; i++)
    {
      g_autoptr(ApexSession) item = g_list_model_get_item (self->sessions, i);

      if (item == session)
        {
          self->syncing = TRUE;
          gtk_list_box_select_row (self->list, gtk_list_box_get_row_at_index (self->list, i));
          self->syncing = FALSE;
          return;
        }
    }
}

static void
apex_sidebar_selected_page_cb (ApexSidebar *self)
{
  AdwTabPage *page = adw_tab_view_get_selected_page (self->tab_view);
  g_autoptr(ApexSession) session = page != NULL ? apex_session_for_page (page) : NULL;

  if (g_set_object (&self->selected, session))
    g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_SELECTED_SESSION]);

  if (session != NULL)
    apex_sidebar_select_row_of (self, session);
}

static void
apex_sidebar_row_selected_cb (ApexSidebar   *self,
                              GtkListBoxRow *row)
{
  ApexSession *session;

  if (self->syncing || row == NULL)
    return;

  session = apex_session_row_get_session (APEX_SESSION_ROW (row));
  if (apex_session_get_page (session) != NULL)
    adw_tab_view_set_selected_page (self->tab_view, apex_session_get_page (session));
}

static void
apex_sidebar_items_changed_cb (ApexSidebar *self)
{
  guint n_items = g_list_model_get_n_items (self->sessions);

  for (guint i = 0; i < n_items; i++)
    {
      g_autoptr(ApexSession) session = g_list_model_get_item (self->sessions, i);

      if (g_object_get_data (G_OBJECT (session), "apex-sidebar") == self)
        continue;

      g_object_set_data (G_OBJECT (session), "apex-sidebar", self);
      g_signal_connect_object (session, "notify::status", G_CALLBACK (apex_sidebar_status_changed), self, G_CONNECT_SWAPPED);
      g_signal_connect_object (session, "notify::group-key", G_CALLBACK (apex_sidebar_group_changed), self, G_CONNECT_SWAPPED);
    }

  apex_sidebar_status_changed (self);
  if (self->selected != NULL)
    apex_sidebar_select_row_of (self, self->selected);
}

static gboolean
apex_sidebar_tick_cb (gpointer data)
{
  ApexSidebar *self = data;
  guint n_items = g_list_model_get_n_items (self->sessions);

  for (guint i = 0; i < n_items; i++)
    {
      g_autoptr(ApexSession) session = g_list_model_get_item (self->sessions, i);
      apex_session_tick (session);
    }

  return G_SOURCE_CONTINUE;
}

static gpointer
map_page_to_session (gpointer item,
                     gpointer user_data)
{
  g_autoptr(AdwTabPage) page = item;

  return apex_session_for_page (page);
}

static int
compare_groups (gconstpointer a,
                gconstpointer b,
                gpointer      user_data)
{
  return g_strcmp0 (apex_session_get_group_key ((ApexSession *)a),
                    apex_session_get_group_key ((ApexSession *)b));
}

static GtkWidget *
create_row (gpointer item,
            gpointer user_data)
{
  return apex_session_row_new (item);
}

static GtkWidget *
header_button (const char *icon_name,
               const char *tooltip)
{
  GtkWidget *button = gtk_button_new_from_icon_name (icon_name);

  gtk_widget_set_tooltip_text (button, tooltip);
  return button;
}

static GtkWidget *
apex_sidebar_build_header (GMenuModel *primary_menu)
{
  GtkWidget *header = adw_header_bar_new ();
  GtkWidget *title = gtk_label_new (_("Terminal"));
  GtkWidget *new_session = header_button ("list-add-symbolic", _("New Session"));
  GtkWidget *menu = gtk_menu_button_new ();

  adw_header_bar_set_show_title (ADW_HEADER_BAR (header), FALSE);
  gtk_widget_add_css_class (title, "apex-sidebar-title");

  gtk_actionable_set_action_name (GTK_ACTIONABLE (new_session), "win.new-terminal");
  gtk_actionable_set_action_target (GTK_ACTIONABLE (new_session), "(ss)", "default", "");

  gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (menu), "open-menu-symbolic");
  gtk_menu_button_set_menu_model (GTK_MENU_BUTTON (menu), primary_menu);
  gtk_widget_set_tooltip_text (menu, _("Main Menu"));

  adw_header_bar_pack_start (ADW_HEADER_BAR (header), title);
  adw_header_bar_pack_end (ADW_HEADER_BAR (header), menu);
  adw_header_bar_pack_end (ADW_HEADER_BAR (header), new_session);

  return header;
}

static GtkWidget *
apex_sidebar_build_footer (ApexSidebar *self)
{
  GtkWidget *footer = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 16);

  gtk_widget_add_css_class (footer, "apex-sessions-footer");

  for (guint i = 0; i < G_N_ELEMENTS (footer_order); i++)
    {
      FooterCount *c = &self->counts[i];

      c->status = footer_order[i];
      c->box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
      c->label = gtk_label_new (NULL);
      gtk_accessible_update_property (GTK_ACCESSIBLE (c->box), GTK_ACCESSIBLE_PROPERTY_LABEL, "", -1);
      gtk_box_append (GTK_BOX (c->box), apex_glyph_new (apex_glyph_kind_for_status (c->status), FOOTER_GLYPH_SIZE));
      gtk_box_append (GTK_BOX (c->box), c->label);
      gtk_box_append (GTK_BOX (footer), c->box);
    }

  return footer;
}

static void
apex_sidebar_dispose (GObject *object)
{
  ApexSidebar *self = (ApexSidebar *)object;

  g_clear_handle_id (&self->tick_id, g_source_remove);
  g_clear_object (&self->selected);
  g_clear_object (&self->sessions);
  g_clear_object (&self->sorter);
  g_clear_weak_pointer (&self->tab_view);

  G_OBJECT_CLASS (apex_sidebar_parent_class)->dispose (object);
}

static void
apex_sidebar_get_property (GObject    *object,
                           guint       prop_id,
                           GValue     *value,
                           GParamSpec *pspec)
{
  ApexSidebar *self = APEX_SIDEBAR (object);

  switch (prop_id)
    {
    case PROP_SELECTED_SESSION:
      g_value_set_object (value, self->selected);
      break;

    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
    }
}

static void
apex_sidebar_class_init (ApexSidebarClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->dispose = apex_sidebar_dispose;
  object_class->get_property = apex_sidebar_get_property;

  properties[PROP_SELECTED_SESSION] =
    g_param_spec_object ("selected-session", NULL, NULL, APEX_TYPE_SESSION,
                         G_PARAM_READABLE | G_PARAM_EXPLICIT_NOTIFY | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, N_PROPS, properties);
}

static void
apex_sidebar_init (ApexSidebar *self)
{
  gtk_widget_add_css_class (GTK_WIDGET (self), "apex-sidebar");
}

GtkWidget *
apex_sidebar_new (AdwTabView *tab_view,
                  GMenuModel *primary_menu)
{
  ApexSidebar *self = g_object_new (APEX_TYPE_SIDEBAR, NULL);
  GtkWidget *toolbar = adw_toolbar_view_new ();
  GtkWidget *scroller = gtk_scrolled_window_new ();
  GtkMapListModel *map;
  GtkWidget *list;

  g_set_weak_pointer (&self->tab_view, tab_view);

  map = gtk_map_list_model_new (G_LIST_MODEL (adw_tab_view_get_pages (tab_view)), map_page_to_session, NULL, NULL);
  self->sorter = GTK_SORTER (gtk_custom_sorter_new (compare_groups, NULL, NULL));
  self->sessions = G_LIST_MODEL (gtk_sort_list_model_new (G_LIST_MODEL (map), g_object_ref (self->sorter)));

  list = gtk_list_box_new ();
  self->list = GTK_LIST_BOX (list);
  gtk_widget_add_css_class (list, "apex-sessions");
  gtk_accessible_update_property (GTK_ACCESSIBLE (list), GTK_ACCESSIBLE_PROPERTY_LABEL, _("Sessions"), -1);
  gtk_list_box_bind_model (self->list, self->sessions, create_row, NULL, NULL);
  gtk_list_box_set_header_func (self->list, apex_sidebar_header_func, self, NULL);
  g_signal_connect_object (list, "row-selected", G_CALLBACK (apex_sidebar_row_selected_cb), self, G_CONNECT_SWAPPED);

  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_widget_set_vexpand (scroller, TRUE);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), list);

  adw_toolbar_view_add_top_bar (ADW_TOOLBAR_VIEW (toolbar), apex_sidebar_build_header (primary_menu));
  adw_toolbar_view_set_content (ADW_TOOLBAR_VIEW (toolbar), scroller);
  adw_toolbar_view_add_bottom_bar (ADW_TOOLBAR_VIEW (toolbar), apex_sidebar_build_footer (self));
  adw_bin_set_child (ADW_BIN (self), toolbar);

  g_signal_connect_object (self->sessions, "items-changed", G_CALLBACK (apex_sidebar_items_changed_cb), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (tab_view, "notify::selected-page", G_CALLBACK (apex_sidebar_selected_page_cb), self, G_CONNECT_SWAPPED);
  self->tick_id = g_timeout_add_seconds (WHEN_TICK_SECONDS, apex_sidebar_tick_cb, self);

  apex_sidebar_items_changed_cb (self);
  apex_sidebar_selected_page_cb (self);

  return GTK_WIDGET (self);
}

ApexSession *
apex_sidebar_get_selected_session (ApexSidebar *self)
{
  return self->selected;
}
