/* SPDX-License-Identifier: GPL-3.0-or-later */

/* Boards 40 to 42's Version control view (apex's docs/design/apex-code-boards-40-42.md, section 7.4):
 * the project's changed files from Builder's own VCS, each with the lines git diff counts. */

#define G_LOG_DOMAIN "gbp-apex-vcs"

#include "config.h"

#include <libide-editor.h>
#include <libide-gui.h>
#include <libide-threading.h>
#include <libide-vcs.h>

#include "apex-i18n.h"
#include "gbp-apex-sidebar.h"
#include "gbp-apex-vcs-pane.h"

#define REFRESH_DELAY_MSEC 500

struct _GbpApexVcsPane
{
  IdePane       parent_instance;
  GtkLabel     *count;
  GtkBox       *changes;
  GtkWidget    *empty;
  IdeVcs       *vcs;
  GCancellable *cancellable;
  guint         n_changes;
  guint         refresh_source;
};

enum { PROP_0, PROP_N_CHANGES, N_PROPS };

static GParamSpec *properties[N_PROPS];

G_DEFINE_FINAL_TYPE (GbpApexVcsPane, gbp_apex_vcs_pane, IDE_TYPE_PANE)

typedef struct
{
  GbpApexVcsPane *self;
  GCancellable   *cancellable;
  GPtrArray      *infos;
  GFile          *workdir;
} Refresh;

static void
refresh_free (Refresh *refresh)
{
  g_object_unref (refresh->self);
  g_object_unref (refresh->cancellable);
  g_clear_pointer (&refresh->infos, g_ptr_array_unref);
  g_clear_object (&refresh->workdir);
  g_free (refresh);
}

static gboolean
is_change (IdeVcsFileStatus status)
{
  return status == IDE_VCS_FILE_STATUS_ADDED || status == IDE_VCS_FILE_STATUS_CHANGED ||
         status == IDE_VCS_FILE_STATUS_DELETED || status == IDE_VCS_FILE_STATUS_RENAMED ||
         status == IDE_VCS_FILE_STATUS_UNTRACKED;
}

static void
change_clicked (GtkButton      *button,
                GbpApexVcsPane *self)
{
  GFile *file = g_object_get_data (G_OBJECT (button), "apex-file");
  IdeWorkspace *workspace = ide_widget_get_workspace (GTK_WIDGET (self));
  g_autoptr(IdeLocation) location = NULL;

  if (file == NULL || workspace == NULL)
    return;

  location = ide_location_new (file, 0, 0);
  ide_editor_focus_location (workspace, NULL, location);
}

/* A row: the name over its folder, then the added lines in --add and the removed in --mod. */
static GtkWidget *
change_row (GbpApexVcsPane *self,
            GFile          *workdir,
            IdeVcsFileInfo *info,
            GHashTable     *numstat)
{
  GFile *file = ide_vcs_file_info_get_file (info);
  g_autofree char *relative = g_file_get_relative_path (workdir, file);
  g_autofree char *name = g_file_get_basename (file);
  g_autofree char *dir = relative != NULL ? g_path_get_dirname (relative) : g_strdup ("");
  const char *counts = relative != NULL ? g_hash_table_lookup (numstat, relative) : NULL;
  g_autofree char *added = NULL;
  g_autofree char *removed = NULL;
  g_autofree char *label = NULL;
  GtkWidget *button = gtk_button_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *names = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *name_label = gtk_label_new (name);
  GtkWidget *dir_label = gtk_label_new (g_strcmp0 (dir, ".") == 0 ? "" : dir);

  gtk_widget_add_css_class (button, "change");
  gtk_label_set_xalign (GTK_LABEL (name_label), 0);
  gtk_label_set_ellipsize (GTK_LABEL (name_label), PANGO_ELLIPSIZE_END);
  gtk_label_set_xalign (GTK_LABEL (dir_label), 0);
  gtk_label_set_ellipsize (GTK_LABEL (dir_label), PANGO_ELLIPSIZE_END);
  gtk_widget_add_css_class (dir_label, "directory");
  gtk_widget_set_visible (dir_label, g_strcmp0 (dir, ".") != 0);
  gtk_widget_set_hexpand (names, TRUE);
  gtk_box_append (GTK_BOX (names), name_label);
  gtk_box_append (GTK_BOX (names), dir_label);
  gtk_box_append (GTK_BOX (box), names);

  if (counts != NULL)
    {
      g_auto(GStrv) parts = g_strsplit (counts, "\t", 2);
      GtkWidget *plus = gtk_label_new (NULL);
      GtkWidget *minus = gtk_label_new (NULL);

      added = g_strdup (parts[0]);
      removed = g_strdup (parts[1] != NULL ? parts[1] : "0");
      label = g_strdup_printf ("+%s", added);
      gtk_label_set_text (GTK_LABEL (plus), label);
      g_clear_pointer (&label, g_free);
      label = g_strdup_printf ("−%s", removed);
      gtk_label_set_text (GTK_LABEL (minus), label);
      g_clear_pointer (&label, g_free);
      gtk_widget_add_css_class (plus, "added");
      gtk_widget_add_css_class (minus, "removed");
      gtk_box_append (GTK_BOX (box), plus);
      gtk_box_append (GTK_BOX (box), minus);
    }

  gtk_button_set_child (GTK_BUTTON (button), box);
  if (added != NULL)
    label = g_strdup_printf (APEX_("%s in %s, %s added, %s removed"), name, dir, added, removed);
  else
    label = g_strdup_printf (APEX_("%s in %s"), name, dir);
  gtk_accessible_update_property (GTK_ACCESSIBLE (button), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
  gtk_widget_set_sensitive (button, ide_vcs_file_info_get_status (info) != IDE_VCS_FILE_STATUS_DELETED);
  g_object_set_data_full (G_OBJECT (button), "apex-file", g_object_ref (file), g_object_unref);
  g_signal_connect_object (button, "clicked", G_CALLBACK (change_clicked), self, 0);

  return button;
}

static int
compare_infos (gconstpointer a,
               gconstpointer b)
{
  g_autofree char *path_a = g_file_get_path (ide_vcs_file_info_get_file (*(IdeVcsFileInfo **) a));
  g_autofree char *path_b = g_file_get_path (ide_vcs_file_info_get_file (*(IdeVcsFileInfo **) b));

  return g_strcmp0 (path_a, path_b);
}

static void
show_changes (GbpApexVcsPane *self,
              GFile          *workdir,
              GPtrArray      *infos,
              GHashTable     *numstat)
{
  GtkWidget *child;
  g_autofree char *count = NULL;

  while ((child = gtk_widget_get_first_child (GTK_WIDGET (self->changes))))
    gtk_box_remove (self->changes, child);

  g_ptr_array_sort (infos, compare_infos);
  for (guint i = 0; i < infos->len; i++)
    gtk_box_append (self->changes, change_row (self, workdir, g_ptr_array_index (infos, i), numstat));

  self->n_changes = infos->len;
  count = g_strdup_printf ("%u", infos->len);
  gtk_label_set_text (self->count, count);
  gtk_widget_set_visible (self->empty, infos->len == 0);
  g_debug ("vcs: %u changes", infos->len);
  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_N_CHANGES]);
}

/* "ADDED\tREMOVED\tPATH" lines; a binary file's counts are "-". */
static void
numstat_cb (GObject      *object,
            GAsyncResult *result,
            gpointer      user_data)
{
  Refresh *refresh = user_data;
  g_autoptr(GHashTable) numstat = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
  g_autofree char *stdout_buf = NULL;
  g_auto(GStrv) lines = NULL;

  if (ide_subprocess_communicate_utf8_finish (IDE_SUBPROCESS (object), result, &stdout_buf, NULL, NULL) &&
      stdout_buf != NULL)
    {
      lines = g_strsplit (stdout_buf, "\n", -1);
      for (guint i = 0; lines[i] != NULL; i++)
        {
          g_auto(GStrv) parts = g_strsplit (lines[i], "\t", 3);

          if (g_strv_length (parts) == 3)
            g_hash_table_insert (numstat, g_strdup (parts[2]), g_strdup_printf ("%s\t%s", parts[0], parts[1]));
        }
    }

  if (!g_cancellable_is_cancelled (refresh->cancellable))
    show_changes (refresh->self, refresh->workdir, refresh->infos, numstat);

  refresh_free (refresh);
}

/* Builder's VCS has no line counts: git diff --numstat gives them, from the work tree to HEAD. */
static void
count_lines (Refresh *refresh)
{
  g_autoptr(IdeSubprocessLauncher) launcher = ide_subprocess_launcher_new (G_SUBPROCESS_FLAGS_STDOUT_PIPE |
                                                                           G_SUBPROCESS_FLAGS_STDERR_SILENCE);
  g_autoptr(IdeSubprocess) subprocess = NULL;
  g_autofree char *cwd = g_file_get_path (refresh->workdir);
  g_autoptr(GHashTable) none = NULL;

  ide_subprocess_launcher_set_run_on_host (launcher, TRUE);
  ide_subprocess_launcher_set_cwd (launcher, cwd);
  ide_subprocess_launcher_push_args (launcher, IDE_STRV_INIT ("git", "diff", "--numstat", "HEAD", "--"));

  if (!(subprocess = ide_subprocess_launcher_spawn (launcher, refresh->cancellable, NULL)))
    {
      none = g_hash_table_new (g_str_hash, g_str_equal);
      show_changes (refresh->self, refresh->workdir, refresh->infos, none);
      refresh_free (refresh);
      return;
    }

  ide_subprocess_communicate_utf8_async (subprocess, NULL, refresh->cancellable, numstat_cb, refresh);
}

static void
list_status_cb (GObject      *object,
                GAsyncResult *result,
                gpointer      user_data)
{
  Refresh *refresh = user_data;
  g_autoptr(GListModel) model = NULL;
  g_autoptr(GError) error = NULL;

  if (!(model = ide_vcs_list_status_finish (IDE_VCS (object), result, &error)))
    {
      if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        g_debug ("vcs: %s", error->message);
      refresh_free (refresh);
      return;
    }

  refresh->infos = g_ptr_array_new_with_free_func (g_object_unref);
  for (guint i = 0; i < g_list_model_get_n_items (model); i++)
    {
      g_autoptr(IdeVcsFileInfo) info = g_list_model_get_item (model, i);

      if (is_change (ide_vcs_file_info_get_status (info)))
        g_ptr_array_add (refresh->infos, g_steal_pointer (&info));
    }

  count_lines (refresh);
}

static gboolean
refresh (gpointer user_data)
{
  GbpApexVcsPane *self = user_data;
  Refresh *state;
  GFile *workdir;

  self->refresh_source = 0;
  g_cancellable_cancel (self->cancellable);
  g_clear_object (&self->cancellable);

  if (self->vcs == NULL || !(workdir = ide_vcs_get_workdir (self->vcs)))
    return G_SOURCE_REMOVE;

  self->cancellable = g_cancellable_new ();
  state = g_new0 (Refresh, 1);
  state->self = g_object_ref (self);
  state->cancellable = g_object_ref (self->cancellable);
  state->workdir = g_object_ref (workdir);
  ide_vcs_list_status_async (self->vcs, workdir, TRUE, G_PRIORITY_LOW, self->cancellable, list_status_cb, state);

  return G_SOURCE_REMOVE;
}

static void
queue_refresh (GbpApexVcsPane *self)
{
  if (self->refresh_source == 0)
    self->refresh_source = g_timeout_add (REFRESH_DELAY_MSEC, refresh, self);
}

/* The VCS comes with the context, which a pane has once it is in a workspace. */
static void
gbp_apex_vcs_pane_root (GtkWidget *widget)
{
  GbpApexVcsPane *self = GBP_APEX_VCS_PANE (widget);
  IdeContext *context;

  GTK_WIDGET_CLASS (gbp_apex_vcs_pane_parent_class)->root (widget);

  if (self->vcs != NULL || !(context = ide_widget_get_context (widget)))
    return;

  self->vcs = g_object_ref (ide_vcs_from_context (context));
  g_signal_connect_object (self->vcs, "changed", G_CALLBACK (queue_refresh), self, G_CONNECT_SWAPPED);
  queue_refresh (self);
}

guint
gbp_apex_vcs_pane_get_n_changes (GbpApexVcsPane *self)
{
  g_return_val_if_fail (GBP_IS_APEX_VCS_PANE (self), 0);

  return self->n_changes;
}

GbpApexVcsPane *
gbp_apex_vcs_pane_new (void)
{
  return g_object_new (GBP_TYPE_APEX_VCS_PANE,
                       "id", "apex-vcs",
                       "title", APEX_("Version control"),
                       "icon-name", "builder-vcs-branch-symbolic",
                       NULL);
}

static void
gbp_apex_vcs_pane_dispose (GObject *object)
{
  GbpApexVcsPane *self = GBP_APEX_VCS_PANE (object);

  g_clear_handle_id (&self->refresh_source, g_source_remove);
  g_cancellable_cancel (self->cancellable);
  g_clear_object (&self->cancellable);
  g_clear_object (&self->vcs);

  G_OBJECT_CLASS (gbp_apex_vcs_pane_parent_class)->dispose (object);
}

static void
gbp_apex_vcs_pane_get_property (GObject    *object,
                                guint       prop_id,
                                GValue     *value,
                                GParamSpec *pspec)
{
  if (prop_id == PROP_N_CHANGES)
    g_value_set_uint (value, GBP_APEX_VCS_PANE (object)->n_changes);
  else
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
}

static void
gbp_apex_vcs_pane_class_init (GbpApexVcsPaneClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->dispose = gbp_apex_vcs_pane_dispose;
  object_class->get_property = gbp_apex_vcs_pane_get_property;
  GTK_WIDGET_CLASS (klass)->root = gbp_apex_vcs_pane_root;

  properties[PROP_N_CHANGES] = g_param_spec_uint ("n-changes", NULL, NULL, 0, G_MAXUINT, 0,
                                                  G_PARAM_READABLE | G_PARAM_EXPLICIT_NOTIFY | G_PARAM_STATIC_STRINGS);
  g_object_class_install_properties (object_class, N_PROPS, properties);
}

static void
gbp_apex_vcs_pane_init (GbpApexVcsPane *self)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget *title = gtk_label_new (APEX_("Changes"));
  GtkWidget *scroller = gtk_scrolled_window_new ();

  gtk_widget_add_css_class (GTK_WIDGET (self), "apexvcs");
  gbp_apex_track_dark (GTK_WIDGET (self));

  gtk_widget_add_css_class (header, "header");
  gtk_label_set_xalign (GTK_LABEL (title), 0);
  gtk_widget_set_hexpand (title, TRUE);
  self->count = GTK_LABEL (gtk_label_new ("0"));
  gtk_widget_add_css_class (GTK_WIDGET (self->count), "count");
  gtk_box_append (GTK_BOX (header), title);
  gtk_box_append (GTK_BOX (header), GTK_WIDGET (self->count));

  self->empty = gtk_label_new (APEX_("No changes"));
  gtk_widget_add_css_class (self->empty, "placeholder");
  gtk_label_set_xalign (GTK_LABEL (self->empty), 0);

  self->changes = GTK_BOX (gtk_box_new (GTK_ORIENTATION_VERTICAL, 0));
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), GTK_WIDGET (self->changes));
  gtk_widget_set_vexpand (scroller, TRUE);

  gtk_box_append (GTK_BOX (box), header);
  gtk_box_append (GTK_BOX (box), self->empty);
  gtk_box_append (GTK_BOX (box), scroller);
  gtk_widget_set_vexpand (box, TRUE);
  panel_widget_set_child (PANEL_WIDGET (self), box);
}
