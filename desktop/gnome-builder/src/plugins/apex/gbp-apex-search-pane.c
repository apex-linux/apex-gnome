/* SPDX-License-Identifier: GPL-3.0-or-later */

/* Boards 40 to 42's Search view (apex's docs/design/apex-code-boards-40-42.md, section 7.3), from
 * Builder's own Find in Files: its grep model scans the project, its panel takes the results. */

#define G_LOG_DOMAIN "gbp-apex-search"

#include "config.h"

#include <string.h>

#include <adwaita.h>
#include <libide-editor.h>
#include <libide-gui.h>

#include "../grep/gbp-grep-model.h"
#include "../grep/gbp-grep-panel.h"

#include "apex-i18n.h"
#include "gbp-apex-search-pane.h"
#include "gbp-apex-sidebar.h"

#define DIM_ALPHA 40632 /* --dim: the foreground at .62 */
#define MATCH_ALPHA 15728 /* the board's match: the accent at 24% */

struct _GbpApexSearchPane
{
  IdePane         parent_instance;
  GtkSearchEntry *entry;
  GtkButton      *show_all;
  GtkBox         *results;
  GbpGrepModel   *model;
  GCancellable   *cancellable;
};

G_DEFINE_FINAL_TYPE (GbpApexSearchPane, gbp_apex_search_pane, IDE_TYPE_PANE)

/* The board's directory: the last two folders, "apex/dock" for desktop/shell/js/ui/apex/dock. */
static char *
short_directory (const char *path)
{
  g_autofree char *dir = g_path_get_dirname (path);
  const char *last;
  const char *before;

  if (g_strcmp0 (dir, ".") == 0)
    return g_strdup ("");
  if (!(last = strrchr (dir, G_DIR_SEPARATOR)))
    return g_steal_pointer (&dir);

  before = last;
  while (before > dir && before[-1] != G_DIR_SEPARATOR)
    before--;

  return g_strdup (before);
}

static void
clear_results (GbpApexSearchPane *self)
{
  GtkWidget *child;

  while ((child = gtk_widget_get_first_child (GTK_WIDGET (self->results))))
    gtk_box_remove (self->results, child);
  gtk_widget_set_visible (GTK_WIDGET (self->show_all), FALSE);
}

static void
hit_clicked (GtkButton         *button,
             GbpApexSearchPane *self)
{
  IdeLocation *location = g_object_get_data (G_OBJECT (button), "apex-location");
  IdeWorkspace *workspace = ide_widget_get_workspace (GTK_WIDGET (self));

  if (location != NULL && workspace != NULL)
    ide_editor_focus_location (workspace, NULL, location);
}

/* The line without its indent, the match at the accent's 24%, the context at --dim. */
static GtkWidget *
hit_row (GbpApexSearchPane      *self,
         const GbpGrepModelLine *line)
{
  const char *text = line->start_of_message;
  gsize skip = 0;
  GtkWidget *button;
  GtkWidget *label;
  PangoAttrList *attrs = pango_attr_list_new ();
  PangoAttribute *attr;
  g_autofree char *name = NULL;
  g_autoptr(GFile) file = gbp_grep_model_get_file (self->model, line->path);
  AdwStyleManager *style = adw_style_manager_get_default ();
  g_autoptr(GdkRGBA) accent = adw_style_manager_get_accent_color_rgba (style);

  while (text[skip] == ' ' || text[skip] == '\t')
    skip++;
  for (guint i = 0; i < line->matches->len; i++)
    skip = MIN (skip, (gsize) g_array_index (line->matches, GbpGrepModelMatch, i).match_begin_bytes);

  attr = pango_attr_foreground_alpha_new (DIM_ALPHA);
  pango_attr_list_insert (attrs, attr);
  for (guint i = 0; i < line->matches->len; i++)
    {
      const GbpGrepModelMatch *match = &g_array_index (line->matches, GbpGrepModelMatch, i);

      attr = pango_attr_foreground_alpha_new (G_MAXUINT16);
      attr->start_index = match->match_begin_bytes - skip;
      attr->end_index = match->match_end_bytes - skip;
      pango_attr_list_insert (attrs, attr);
      attr = pango_attr_background_new (accent->red * G_MAXUINT16, accent->green * G_MAXUINT16, accent->blue * G_MAXUINT16);
      attr->start_index = match->match_begin_bytes - skip;
      attr->end_index = match->match_end_bytes - skip;
      pango_attr_list_insert (attrs, attr);
      attr = pango_attr_background_alpha_new (MATCH_ALPHA);
      attr->start_index = match->match_begin_bytes - skip;
      attr->end_index = match->match_end_bytes - skip;
      pango_attr_list_insert (attrs, attr);
    }

  label = gtk_label_new (text + skip);
  gtk_label_set_attributes (GTK_LABEL (label), attrs);
  gtk_label_set_xalign (GTK_LABEL (label), 0);
  gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_END);
  pango_attr_list_unref (attrs);

  button = gtk_button_new ();
  gtk_widget_add_css_class (button, "hit");
  gtk_button_set_child (GTK_BUTTON (button), label);
  name = g_strdup_printf (APEX_("Line %u: %s"), line->line, text + skip);
  gtk_accessible_update_property (GTK_ACCESSIBLE (button), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
  g_object_set_data_full (G_OBJECT (button), "apex-location",
                          ide_location_new (file, line->line > 0 ? line->line - 1 : 0, -1),
                          g_object_unref);
  g_signal_connect_object (button, "clicked", G_CALLBACK (hit_clicked), self, 0);

  return button;
}

static GtkWidget *
group_new (const char *path,
           guint       count)
{
  GtkWidget *group = g_object_new (GTK_TYPE_BOX,
                                   "orientation", GTK_ORIENTATION_VERTICAL,
                                   "spacing", 1,
                                   "accessible-role", GTK_ACCESSIBLE_ROLE_GROUP,
                                   NULL);
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  g_autofree char *base = g_path_get_basename (path);
  g_autofree char *dir = short_directory (path);
  g_autofree char *count_text = g_strdup_printf ("%u", count);
  GtkWidget *file = gtk_label_new (base);
  GtkWidget *directory = gtk_label_new (dir);
  GtkWidget *pill = gtk_label_new (count_text);

  gtk_widget_add_css_class (header, "header");
  gtk_widget_add_css_class (file, "file");
  gtk_widget_add_css_class (directory, "directory");
  gtk_label_set_ellipsize (GTK_LABEL (directory), PANGO_ELLIPSIZE_START);
  gtk_label_set_xalign (GTK_LABEL (directory), 0);
  gtk_widget_set_hexpand (directory, TRUE);
  gtk_widget_set_visible (directory, dir[0] != '\0');
  gtk_widget_add_css_class (pill, "count");
  gtk_box_append (GTK_BOX (header), file);
  gtk_box_append (GTK_BOX (header), directory);
  gtk_box_append (GTK_BOX (header), pill);
  gtk_box_append (GTK_BOX (group), header);
  gtk_accessible_update_property (GTK_ACCESSIBLE (group), GTK_ACCESSIBLE_PROPERTY_LABEL, base, -1);

  return group;
}

/* gbp_grep_model_get_line() fills one line for each call: count first, then build. */
static void
show_results (GbpApexSearchPane *self)
{
  GtkTreeModel *model = GTK_TREE_MODEL (self->model);
  g_autoptr(GHashTable) counts = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  g_autofree char *group_path = NULL;
  g_autofree char *label = NULL;
  GtkWidget *group = NULL;
  GtkTreeIter iter;
  guint total = 0;

  clear_results (self);

  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  for (gboolean ok = gtk_tree_model_get_iter_first (model, &iter); ok; ok = gtk_tree_model_iter_next (model, &iter))
    {
      const GbpGrepModelLine *line = NULL;

      gbp_grep_model_get_line (self->model, &iter, &line);
      if (line != NULL)
        g_hash_table_insert (counts, g_strdup (line->path),
                             GUINT_TO_POINTER (GPOINTER_TO_UINT (g_hash_table_lookup (counts, line->path)) + 1));
    }

  for (gboolean ok = gtk_tree_model_get_iter_first (model, &iter); ok; ok = gtk_tree_model_iter_next (model, &iter))
    {
      const GbpGrepModelLine *line = NULL;

      gbp_grep_model_get_line (self->model, &iter, &line);
      if (line == NULL)
        continue;

      if (group == NULL || g_strcmp0 (group_path, line->path) != 0)
        {
          g_free (group_path);
          group_path = g_strdup (line->path);
          group = group_new (line->path, GPOINTER_TO_UINT (g_hash_table_lookup (counts, line->path)));
          gtk_box_append (self->results, group);
        }

      gtk_box_append (GTK_BOX (group), hit_row (self, line));
      total++;
    }
  G_GNUC_END_IGNORE_DEPRECATIONS

  g_debug ("search: %u results", total);
  if (total == 0)
    return;

  label = g_strdup_printf (APEX_NG_("Show %u result in Find in Files", "Show %u results in Find in Files", total), total);
  gtk_button_set_label (self->show_all, label);
  gtk_widget_set_visible (GTK_WIDGET (self->show_all), TRUE);
}

static void
scan_cb (GObject      *object,
         GAsyncResult *result,
         gpointer      user_data)
{
  g_autoptr(GbpApexSearchPane) self = user_data;
  g_autoptr(GError) error = NULL;

  if (!gbp_grep_model_scan_finish (GBP_GREP_MODEL (object), result, &error))
    {
      if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        g_debug ("search: %s", error->message);
      return;
    }

  if ((GObject *) self->model == object)
    show_results (self);
}

static void
search_changed (GbpApexSearchPane *self)
{
  const char *query = gtk_editable_get_text (GTK_EDITABLE (self->entry));
  IdeContext *context = ide_widget_get_context (GTK_WIDGET (self));
  g_autoptr(GFile) workdir = NULL;

  g_cancellable_cancel (self->cancellable);
  g_clear_object (&self->cancellable);
  g_clear_object (&self->model);
  clear_results (self);

  if (context == NULL || query[0] == '\0')
    return;

  workdir = ide_context_ref_workdir (context);
  self->cancellable = g_cancellable_new ();
  self->model = gbp_grep_model_new (context);
  gbp_grep_model_set_directory (self->model, workdir);
  gbp_grep_model_set_recursive (self->model, TRUE);
  gbp_grep_model_set_query (self->model, query);
  gbp_grep_model_scan_async (self->model, self->cancellable, scan_cb, g_object_ref (self));
}

static GtkWidget *
find_panel (GtkWidget *widget)
{
  for (GtkWidget *child = gtk_widget_get_first_child (widget); child; child = gtk_widget_get_next_sibling (child))
    {
      GtkWidget *found;

      if (GBP_IS_GREP_PANEL (child))
        return child;
      if ((found = find_panel (child)))
        return found;
    }

  return NULL;
}

/* Builder's Find in Files panel, in the bottom panel, takes the same model: its list, and its Replace. */
static void
show_all_clicked (GbpApexSearchPane *self)
{
  IdeWorkspace *workspace = ide_widget_get_workspace (GTK_WIDGET (self));
  GtkWidget *panel;

  if (workspace == NULL || self->model == NULL || !(panel = find_panel (GTK_WIDGET (workspace))))
    return;

  gbp_grep_panel_set_model (GBP_GREP_PANEL (panel), self->model);
  panel_widget_raise (PANEL_WIDGET (panel));
}

static gboolean
gbp_apex_search_pane_grab_focus (GtkWidget *widget)
{
  return gtk_widget_grab_focus (GTK_WIDGET (GBP_APEX_SEARCH_PANE (widget)->entry));
}

GbpApexSearchPane *
gbp_apex_search_pane_new (void)
{
  return g_object_new (GBP_TYPE_APEX_SEARCH_PANE,
                       "id", "apex-search",
                       "title", APEX_("Search"),
                       "icon-name", "system-search-symbolic",
                       NULL);
}

static void
gbp_apex_search_pane_dispose (GObject *object)
{
  GbpApexSearchPane *self = GBP_APEX_SEARCH_PANE (object);

  g_cancellable_cancel (self->cancellable);
  g_clear_object (&self->cancellable);
  g_clear_object (&self->model);

  G_OBJECT_CLASS (gbp_apex_search_pane_parent_class)->dispose (object);
}

static void
gbp_apex_search_pane_class_init (GbpApexSearchPaneClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = gbp_apex_search_pane_dispose;
  GTK_WIDGET_CLASS (klass)->grab_focus = gbp_apex_search_pane_grab_focus;
}

static void
gbp_apex_search_pane_init (GbpApexSearchPane *self)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);
  GtkWidget *scroller = gtk_scrolled_window_new ();

  gtk_widget_add_css_class (GTK_WIDGET (self), "apexsearch");
  gbp_apex_track_dark (GTK_WIDGET (self));

  self->entry = GTK_SEARCH_ENTRY (gtk_search_entry_new ());
  gtk_search_entry_set_placeholder_text (self->entry, APEX_("Search in Project"));
  gtk_search_entry_set_search_delay (self->entry, 300);
  gtk_accessible_update_property (GTK_ACCESSIBLE (self->entry), GTK_ACCESSIBLE_PROPERTY_LABEL, APEX_("Search in Project"), -1);
  g_signal_connect_object (self->entry, "search-changed", G_CALLBACK (search_changed), self, G_CONNECT_SWAPPED);

  self->show_all = GTK_BUTTON (gtk_button_new ());
  gtk_widget_add_css_class (GTK_WIDGET (self->show_all), "show-all");
  gtk_widget_set_visible (GTK_WIDGET (self->show_all), FALSE);
  g_signal_connect_object (self->show_all, "clicked", G_CALLBACK (show_all_clicked), self, G_CONNECT_SWAPPED);

  self->results = GTK_BOX (gtk_box_new (GTK_ORIENTATION_VERTICAL, 8));
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), GTK_WIDGET (self->results));
  gtk_widget_set_vexpand (scroller, TRUE);

  gtk_box_append (GTK_BOX (box), GTK_WIDGET (self->entry));
  gtk_box_append (GTK_BOX (box), GTK_WIDGET (self->show_all));
  gtk_box_append (GTK_BOX (box), scroller);
  gtk_widget_set_vexpand (box, TRUE);
  panel_widget_set_child (PANEL_WIDGET (self), box);
}
