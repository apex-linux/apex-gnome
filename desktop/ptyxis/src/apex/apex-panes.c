/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "config.h"

#include <glib/gi18n.h>

#include "apex-glyph.h"
#include "apex-panes.h"

#define PANE_GLYPH_SIZE 14
#define FRAME_KEY "apex-pane-frame"
#define OWNER_KEY "apex-pane-owner"
#define SECOND_FOCUSED_KEY "apex-second-focused"

typedef struct
{
  GtkWidget   *glyph;
  GtkWidget   *title;
  GtkWidget   *path;
  GtkWidget   *tag;
  ApexSession *session;
} PaneHeader;

struct _ApexPanes
{
  GtkWidget     parent_instance;

  PtyxisWindow *window;
  AdwTabView   *tab_view;
  GtkWidget    *paned;
  GtkWidget    *first;
  GtkWidget    *seconds;
  PaneHeader   *first_header;
  ApexSession  *selected;
  gboolean      second_focused;
};

G_DEFINE_FINAL_TYPE (ApexPanes, apex_panes, GTK_TYPE_WIDGET)

static void
pane_header_update (PaneHeader *h)
{
  ApexStatus status;

  if (h->session == NULL)
    return;

  status = apex_session_get_pane_status (h->session);
  apex_glyph_set_kind (APEX_GLYPH (h->glyph), status == APEX_STATUS_NEEDS_YOU ? APEX_GLYPH_NEEDS_YOU : APEX_GLYPH_NONE);
  gtk_widget_set_visible (h->glyph, status == APEX_STATUS_NEEDS_YOU);
  gtk_label_set_label (GTK_LABEL (h->title), apex_session_get_pane_title (h->session));
  gtk_label_set_label (GTK_LABEL (h->path), apex_session_get_path (h->session));
  gtk_label_set_label (GTK_LABEL (h->tag), apex_session_get_tag (h->session));
}

static void
pane_header_set_session (PaneHeader  *h,
                         ApexSession *session)
{
  if (h->session == session)
    return;

  if (h->session != NULL)
    g_signal_handlers_disconnect_by_data (h->session, h);
  g_set_object (&h->session, session);

  if (session != NULL)
    {
      g_signal_connect_swapped (session, "notify::status", G_CALLBACK (pane_header_update), h);
      g_signal_connect_swapped (session, "notify::path", G_CALLBACK (pane_header_update), h);
      g_signal_connect_swapped (session, "notify::tag", G_CALLBACK (pane_header_update), h);
      pane_header_update (h);
    }
}

static void
pane_header_free (gpointer data)
{
  PaneHeader *h = data;

  pane_header_set_session (h, NULL);
  g_free (h);
}

static GtkWidget *
pane_label (const char *css_class,
            gboolean    ellipsize)
{
  GtkWidget *label = gtk_label_new (NULL);

  gtk_widget_add_css_class (label, css_class);
  gtk_label_set_single_line_mode (GTK_LABEL (label), TRUE);
  if (ellipsize)
    {
      gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_END);
      gtk_label_set_xalign (GTK_LABEL (label), 0);
      gtk_widget_set_hexpand (label, TRUE);
    }
  return label;
}

static GtkWidget *
pane_frame (GtkWidget   *body,
            PaneHeader **out_header,
            gboolean     closable)
{
  GtkWidget *frame = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  PaneHeader *h = g_new0 (PaneHeader, 1);

  h->glyph = apex_glyph_new (APEX_GLYPH_NONE, PANE_GLYPH_SIZE);
  h->title = pane_label ("apex-pane-title", FALSE);
  h->path = pane_label ("apex-path", TRUE);
  h->tag = pane_label ("apex-tag", FALSE);

  gtk_widget_add_css_class (frame, "apex-pane");
  gtk_widget_add_css_class (header, "apex-pane-header");
  gtk_widget_add_css_class (body, "apex-pane-body");
  gtk_widget_set_vexpand (body, TRUE);
  gtk_widget_set_visible (header, FALSE);

  gtk_box_append (GTK_BOX (header), h->glyph);
  gtk_box_append (GTK_BOX (header), h->title);
  gtk_box_append (GTK_BOX (header), h->path);
  gtk_box_append (GTK_BOX (header), h->tag);

  if (closable)
    {
      GtkWidget *close = gtk_button_new_from_icon_name ("window-close-symbolic");

      gtk_widget_add_css_class (close, "flat");
      gtk_widget_set_tooltip_text (close, _("Close Pane"));
      gtk_actionable_set_action_name (GTK_ACTIONABLE (close), "apex.close-pane");
      gtk_box_append (GTK_BOX (header), close);
    }

  gtk_box_append (GTK_BOX (frame), header);
  gtk_box_append (GTK_BOX (frame), body);
  g_object_set_data_full (G_OBJECT (frame), "apex-pane-header", h, pane_header_free);

  *out_header = h;
  return frame;
}

static GtkWidget *
frame_header_widget (GtkWidget *frame)
{
  return gtk_widget_get_first_child (frame);
}

static GtkWidget *
second_frame (ApexSession *session)
{
  ApexSession *second = session != NULL ? apex_session_get_second (session) : NULL;

  return second != NULL ? g_object_get_data (G_OBJECT (apex_session_get_tab (second)), FRAME_KEY) : NULL;
}

static void
apex_panes_update_dimming (ApexPanes *self)
{
  GtkWidget *second = second_frame (self->selected);
  gboolean split = second != NULL;

  if (split && self->second_focused)
    gtk_widget_add_css_class (self->first, "apex-dimmed");
  else
    gtk_widget_remove_css_class (self->first, "apex-dimmed");

  if (second != NULL)
    {
      if (self->second_focused)
        gtk_widget_remove_css_class (second, "apex-dimmed");
      else
        gtk_widget_add_css_class (second, "apex-dimmed");
    }
}

static void
apex_panes_apply_layout (ApexPanes *self)
{
  GtkWidget *second = second_frame (self->selected);
  gboolean split = second != NULL;

  gtk_widget_set_visible (frame_header_widget (self->first), split);
  gtk_widget_set_visible (self->seconds, split);

  if (split)
    {
      ApexSplit mode = apex_session_get_split (self->selected);

      gtk_orientable_set_orientation (GTK_ORIENTABLE (self->paned),
                                      mode == APEX_SPLIT_DOWN ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL);
      gtk_stack_set_visible_child (GTK_STACK (self->seconds), second);
      gtk_widget_set_visible (frame_header_widget (second), TRUE);
    }

  self->second_focused = split && self->selected != NULL &&
                         GPOINTER_TO_INT (g_object_get_data (G_OBJECT (self->selected), SECOND_FOCUSED_KEY));
  apex_panes_update_dimming (self);
}

static void
apex_panes_center_divider (ApexPanes *self)
{
  gboolean vertical = gtk_orientable_get_orientation (GTK_ORIENTABLE (self->paned)) == GTK_ORIENTATION_VERTICAL;
  int size = vertical ? gtk_widget_get_height (self->paned) : gtk_widget_get_width (self->paned);

  if (size > 0)
    gtk_paned_set_position (GTK_PANED (self->paned), size / 2);
}

static void
apex_panes_focus_pane (ApexPanes *self,
                       gboolean   second)
{
  ApexSession *pane;

  if (self->selected == NULL)
    return;

  self->second_focused = second && second_frame (self->selected) != NULL;
  g_object_set_data (G_OBJECT (self->selected), SECOND_FOCUSED_KEY, GINT_TO_POINTER (self->second_focused));
  apex_panes_update_dimming (self);

  pane = self->second_focused ? apex_session_get_second (self->selected) : self->selected;
  if (gtk_window_is_active (GTK_WINDOW (self->window)))
    apex_session_focused (pane);
}

static void
first_focus_enter_cb (GtkEventControllerFocus *focus,
                      ApexPanes               *self)
{
  apex_panes_focus_pane (self, FALSE);
}

static void
second_focus_enter_cb (GtkEventControllerFocus *focus,
                       ApexPanes               *self)
{
  GtkWidget *frame = gtk_event_controller_get_widget (GTK_EVENT_CONTROLLER (focus));

  if (frame == second_frame (self->selected))
    apex_panes_focus_pane (self, TRUE);
}

static void
watch_focus (GtkWidget *widget,
             GCallback  callback,
             ApexPanes *self)
{
  GtkEventController *focus = gtk_event_controller_focus_new ();

  g_signal_connect_object (focus, "enter", callback, self, 0);
  gtk_widget_add_controller (widget, focus);
}

static gboolean
grab_focus_idle (gpointer data)
{
  g_autoptr(PtyxisTab) tab = data;

  if (gtk_widget_get_mapped (GTK_WIDGET (tab)))
    ptyxis_tab_grab_focus (tab);
  return G_SOURCE_REMOVE;
}

static void
focus_tab_later (PtyxisTab *tab)
{
  g_idle_add_full (G_PRIORITY_LOW, grab_focus_idle, g_object_ref (tab), NULL);
}

static void
apex_panes_selected_page_cb (ApexPanes *self)
{
  AdwTabPage *page = adw_tab_view_get_selected_page (self->tab_view);
  g_autoptr(ApexSession) session = page != NULL ? apex_session_for_page (page) : NULL;

  if (session == self->selected)
    return;

  g_set_object (&self->selected, session);
  pane_header_set_session (self->first_header, session);
  apex_panes_apply_layout (self);
  apex_panes_focus_pane (self, self->second_focused);

  if (self->second_focused)
    focus_tab_later (apex_session_get_tab (apex_session_get_second (self->selected)));
}

static void
apex_panes_unsplit (ApexPanes   *self,
                    ApexSession *session)
{
  GtkWidget *frame = second_frame (session);
  PtyxisTab *first_tab = apex_session_get_tab (session);

  g_object_set_data (G_OBJECT (session), SECOND_FOCUSED_KEY, NULL);
  apex_session_set_second (session, NULL, APEX_SPLIT_NONE);
  if (frame != NULL)
    gtk_stack_remove (GTK_STACK (self->seconds), frame);

  if (session == self->selected)
    {
      apex_panes_apply_layout (self);
      focus_tab_later (first_tab);
    }
}

void
apex_panes_split (ApexPanes *self,
                  ApexSplit  split)
{
  ApexSession *session = self->selected;
  g_autoptr(PtyxisIpcContainer) container = NULL;
  g_autofree char *cwd = NULL;
  PtyxisTab *first_tab;
  PtyxisTab *tab;
  ApexSession *second;
  PaneHeader *header;
  GtkWidget *frame;

  if (session == NULL)
    return;

  if (apex_session_get_second (session) != NULL)
    {
      if (apex_session_get_split (session) == split)
        apex_panes_unsplit (self, session);
      else
        {
          apex_session_set_second (session, apex_session_get_second (session), split);
          apex_panes_apply_layout (self);
          apex_panes_center_divider (self);
        }
      return;
    }

  first_tab = apex_session_get_tab (session);
  tab = ptyxis_tab_new (ptyxis_tab_get_profile (first_tab));
  if ((cwd = ptyxis_tab_dup_current_directory_uri (first_tab)))
    ptyxis_tab_set_initial_working_directory_uri (tab, cwd);
  if ((container = ptyxis_tab_dup_container (first_tab)))
    ptyxis_tab_set_container (tab, container);

  frame = pane_frame (GTK_WIDGET (tab), &header, TRUE);
  g_object_set_data (G_OBJECT (tab), FRAME_KEY, frame);
  g_object_set_data (G_OBJECT (tab), OWNER_KEY, session);
  watch_focus (frame, G_CALLBACK (second_focus_enter_cb), self);
  gtk_stack_add_child (GTK_STACK (self->seconds), frame);

  second = apex_session_for_tab (tab);
  pane_header_set_session (header, second);
  apex_session_set_second (session, second, split);
  g_object_unref (second);

  g_object_set_data (G_OBJECT (session), SECOND_FOCUSED_KEY, GINT_TO_POINTER (TRUE));
  apex_panes_apply_layout (self);
  apex_panes_center_divider (self);
  focus_tab_later (tab);
}

PtyxisTab *
apex_panes_focused_second (ApexPanes *self)
{
  ApexSession *second;

  if (self == NULL || self->selected == NULL || !self->second_focused)
    return NULL;

  second = apex_session_get_second (self->selected);
  return second != NULL ? apex_session_get_tab (second) : NULL;
}

void
apex_pane_exited (PtyxisTab *tab)
{
  ApexSession *owner = g_object_get_data (G_OBJECT (tab), OWNER_KEY);
  GtkWidget *panes = gtk_widget_get_ancestor (GTK_WIDGET (tab), APEX_TYPE_PANES);

  if (owner != NULL && panes != NULL)
    apex_panes_unsplit (APEX_PANES (panes), owner);
}

static void
apex_panes_window_active_cb (ApexPanes *self)
{
  apex_panes_focus_pane (self, self->second_focused);
}

static void
apex_panes_page_detached_cb (ApexPanes  *self,
                             AdwTabPage *page)
{
  g_autoptr(ApexSession) session = apex_session_for_page (page);

  if (apex_session_get_second (session) != NULL)
    apex_panes_unsplit (self, session);
}

static void
split_right_action (GSimpleAction *action,
                    GVariant      *param,
                    gpointer       self)
{
  apex_panes_split (self, APEX_SPLIT_RIGHT);
}

static void
split_down_action (GSimpleAction *action,
                   GVariant      *param,
                   gpointer       self)
{
  apex_panes_split (self, APEX_SPLIT_DOWN);
}

static void
close_pane_action (GSimpleAction *action,
                   GVariant      *param,
                   gpointer       data)
{
  ApexPanes *self = data;

  if (self->selected != NULL && apex_session_get_second (self->selected) != NULL)
    apex_panes_unsplit (self, self->selected);
}

static void
apex_panes_add_actions (ApexPanes *self)
{
  static const GActionEntry entries[] = {
    { "split-right", split_right_action },
    { "split-down", split_down_action },
    { "close-pane", close_pane_action },
  };
  static const struct { const char *trigger, *action; } shortcuts[] = {
    { "<Control><Alt>r", "apex.split-right" },
    { "<Control><Alt>d", "apex.split-down" },
  };
  g_autoptr(GSimpleActionGroup) group = g_simple_action_group_new ();
  GtkEventController *controller = gtk_shortcut_controller_new ();

  g_action_map_add_action_entries (G_ACTION_MAP (group), entries, G_N_ELEMENTS (entries), self);
  gtk_widget_insert_action_group (GTK_WIDGET (self->window), "apex", G_ACTION_GROUP (group));

  gtk_shortcut_controller_set_scope (GTK_SHORTCUT_CONTROLLER (controller), GTK_SHORTCUT_SCOPE_GLOBAL);
  gtk_event_controller_set_propagation_phase (controller, GTK_PHASE_CAPTURE);
  for (guint i = 0; i < G_N_ELEMENTS (shortcuts); i++)
    gtk_shortcut_controller_add_shortcut (GTK_SHORTCUT_CONTROLLER (controller),
                                          gtk_shortcut_new (gtk_shortcut_trigger_parse_string (shortcuts[i].trigger),
                                                            gtk_named_action_new (shortcuts[i].action)));
  gtk_widget_add_controller (GTK_WIDGET (self->window), controller);
}

static void
apex_panes_dispose (GObject *object)
{
  ApexPanes *self = (ApexPanes *)object;

  g_clear_object (&self->selected);
  g_clear_pointer (&self->paned, gtk_widget_unparent);

  G_OBJECT_CLASS (apex_panes_parent_class)->dispose (object);
}

static void
apex_panes_class_init (ApexPanesClass *klass)
{
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

  G_OBJECT_CLASS (klass)->dispose = apex_panes_dispose;
  gtk_widget_class_set_layout_manager_type (widget_class, GTK_TYPE_BIN_LAYOUT);
  gtk_widget_class_set_css_name (widget_class, "apex-panes");
}

static void
apex_panes_init (ApexPanes *self)
{
}

ApexPanes *
apex_panes_attach (PtyxisWindow *window,
                   AdwTabView   *tab_view)
{
  ApexPanes *self = g_object_new (APEX_TYPE_PANES, "vexpand", TRUE, NULL);
  GtkWidget *toasts = gtk_widget_get_parent (GTK_WIDGET (tab_view));
  g_autoptr(GtkWidget) view = g_object_ref (GTK_WIDGET (tab_view));

  self->window = window;
  self->tab_view = tab_view;

  adw_toast_overlay_set_child (ADW_TOAST_OVERLAY (toasts), NULL);

  self->first = pane_frame (view, &self->first_header, FALSE);
  watch_focus (self->first, G_CALLBACK (first_focus_enter_cb), self);
  self->seconds = gtk_stack_new ();
  gtk_stack_set_hhomogeneous (GTK_STACK (self->seconds), FALSE);
  gtk_stack_set_vhomogeneous (GTK_STACK (self->seconds), FALSE);
  gtk_widget_set_visible (self->seconds, FALSE);

  self->paned = gtk_paned_new (GTK_ORIENTATION_HORIZONTAL);
  gtk_paned_set_start_child (GTK_PANED (self->paned), self->first);
  gtk_paned_set_end_child (GTK_PANED (self->paned), self->seconds);
  gtk_paned_set_shrink_start_child (GTK_PANED (self->paned), FALSE);
  gtk_paned_set_shrink_end_child (GTK_PANED (self->paned), FALSE);
  gtk_widget_set_parent (self->paned, GTK_WIDGET (self));

  adw_toast_overlay_set_child (ADW_TOAST_OVERLAY (toasts), GTK_WIDGET (self));

  apex_panes_add_actions (self);
  g_signal_connect_object (window, "notify::is-active", G_CALLBACK (apex_panes_window_active_cb), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (tab_view, "notify::selected-page", G_CALLBACK (apex_panes_selected_page_cb), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (tab_view, "page-detached", G_CALLBACK (apex_panes_page_detached_cb), self, G_CONNECT_SWAPPED);
  apex_panes_selected_page_cb (self);

  return self;
}
