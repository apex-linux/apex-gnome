/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-glyph.h"
#include "apex-session-row.h"

struct _ApexSessionRow
{
  GtkListBoxRow  parent_instance;

  ApexSession   *session;
  GtkWidget     *title;
  GtkWidget     *subtitle;
  GtkWidget     *when;
  GtkWidget     *glyph;
  GtkWidget     *progress;
};

G_DEFINE_FINAL_TYPE (ApexSessionRow, apex_session_row, GTK_TYPE_LIST_BOX_ROW)

static GtkWidget *
row_label (const char *css_class,
           gboolean    ellipsize)
{
  GtkWidget *label = gtk_label_new (NULL);

  gtk_label_set_xalign (GTK_LABEL (label), 0);
  gtk_widget_add_css_class (label, css_class);
  if (ellipsize)
    gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_END);
  return label;
}

static void
apex_session_row_update_status (ApexSessionRow *self)
{
  ApexStatus status = apex_session_get_status (self->session);
  g_autofree char *when = apex_session_dup_when (self->session);

  apex_glyph_set_kind (APEX_GLYPH (self->glyph), apex_glyph_kind_for_status (status));
  if (status == APEX_STATUS_NEEDS_YOU)
    gtk_widget_add_css_class (GTK_WIDGET (self), "needs-you");
  else
    gtk_widget_remove_css_class (GTK_WIDGET (self), "needs-you");

  gtk_label_set_label (GTK_LABEL (self->when), when);
}

static void
apex_session_row_update_progress (ApexSessionRow *self)
{
  double progress = apex_session_get_progress (self->session);

  gtk_widget_set_visible (self->progress, progress >= 0);
  gtk_progress_bar_set_fraction (GTK_PROGRESS_BAR (self->progress), MAX (progress, 0));
}

static void
apex_session_row_update_text (ApexSessionRow *self)
{
  const char *subtitle = apex_session_get_subtitle (self->session);

  gtk_label_set_label (GTK_LABEL (self->title), apex_session_get_title (self->session));
  gtk_label_set_label (GTK_LABEL (self->subtitle), subtitle != NULL ? subtitle : apex_session_get_tag (self->session));
}

static void
apex_session_row_dispose (GObject *object)
{
  ApexSessionRow *self = (ApexSessionRow *)object;

  g_clear_object (&self->session);

  G_OBJECT_CLASS (apex_session_row_parent_class)->dispose (object);
}

static void
apex_session_row_class_init (ApexSessionRowClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = apex_session_row_dispose;
}

static void
apex_session_row_init (ApexSessionRow *self)
{
  GtkWidget *overlay = gtk_overlay_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *text = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);

  gtk_widget_add_css_class (GTK_WIDGET (self), "apex-session");

  self->title = row_label ("apex-row-title", TRUE);
  self->subtitle = row_label ("apex-row-subtitle", TRUE);
  self->when = row_label ("apex-row-when", FALSE);
  self->glyph = apex_glyph_new (APEX_GLYPH_NONE, 16);
  self->progress = gtk_progress_bar_new ();
  gtk_widget_set_valign (self->progress, GTK_ALIGN_END);
  gtk_widget_set_can_target (self->progress, FALSE);
  gtk_accessible_update_property (GTK_ACCESSIBLE (self->progress),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL, "Progress", -1);

  gtk_widget_set_hexpand (text, TRUE);
  gtk_widget_set_valign (text, GTK_ALIGN_CENTER);
  gtk_box_append (GTK_BOX (text), self->title);
  gtk_box_append (GTK_BOX (text), self->subtitle);
  gtk_box_append (GTK_BOX (box), text);
  gtk_box_append (GTK_BOX (box), self->when);
  gtk_box_append (GTK_BOX (box), self->glyph);
  gtk_widget_add_css_class (box, "content");

  gtk_overlay_set_child (GTK_OVERLAY (overlay), box);
  gtk_overlay_add_overlay (GTK_OVERLAY (overlay), self->progress);
  gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (self), overlay);
}

GtkWidget *
apex_session_row_new (ApexSession *session)
{
  ApexSessionRow *self = g_object_new (APEX_TYPE_SESSION_ROW, NULL);

  self->session = g_object_ref (session);

  g_signal_connect_object (session, "notify::status", G_CALLBACK (apex_session_row_update_status), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (session, "notify::when", G_CALLBACK (apex_session_row_update_status), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (session, "notify::progress", G_CALLBACK (apex_session_row_update_progress), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (session, "notify::title", G_CALLBACK (apex_session_row_update_text), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (session, "notify::subtitle", G_CALLBACK (apex_session_row_update_text), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (session, "notify::tag", G_CALLBACK (apex_session_row_update_text), self, G_CONNECT_SWAPPED);

  apex_session_row_update_text (self);
  apex_session_row_update_status (self);
  apex_session_row_update_progress (self);

  return GTK_WIDGET (self);
}

ApexSession *
apex_session_row_get_session (ApexSessionRow *self)
{
  return self->session;
}
