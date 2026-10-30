/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "config.h"

#include <glib/gi18n.h>
#include <pwd.h>
#include <unistd.h>

#include "ptyxis-application.h"
#include "ptyxis-terminal.h"
#include "ptyxis-window.h"

#include "apex-session.h"

#define HOST_GROUP_KEY "0"
#define NO_PROGRESS (-1.0)

struct _ApexSession
{
  GObject           parent_instance;

  AdwTabPage       *page;
  PtyxisTab        *tab;
  ApexSessionState  state;

  char             *subtitle;
  char             *title;
  char             *path;
  char             *tag;
  char             *group_key;
  char             *group_label;
  char             *group_pill;
  double            progress;
  ApexSession      *second;
  ApexSplit         split;
};

enum {
  PROP_0,
  PROP_STATUS,
  PROP_TITLE,
  PROP_SUBTITLE,
  PROP_PATH,
  PROP_TAG,
  PROP_GROUP_KEY,
  PROP_PROGRESS,
  PROP_WHEN,
  PROP_SPLIT,
  N_PROPS
};

G_DEFINE_FINAL_TYPE (ApexSession, apex_session, G_TYPE_OBJECT)

static GParamSpec *properties[N_PROPS];

static void
notify (ApexSession *self,
        guint        prop)
{
  g_object_notify_by_pspec (G_OBJECT (self), properties[prop]);
}

static gboolean
set_str (ApexSession *self,
         char       **field,
         const char  *value,
         guint        prop)
{
  if (!g_set_str (field, value))
    return FALSE;

  notify (self, prop);
  return TRUE;
}

static const char *
user_shell (void)
{
  static char *shell;

  if (shell == NULL)
    {
      struct passwd *pw = getpwuid (getuid ());

      shell = g_path_get_basename (pw != NULL && pw->pw_shell != NULL ? pw->pw_shell : "sh");
    }

  return shell;
}

static void
apex_session_status_changed (ApexSession *self)
{
  g_autofree char *subtitle = apex_session_state_subtitle (&self->state);
  g_autofree char *program = NULL;

  set_str (self, &self->subtitle, subtitle, PROP_SUBTITLE);

  if (self->state.remote)
    program = g_strdup ("ssh");
  else if (self->state.in_command && self->state.command != NULL)
    program = g_strndup (self->state.command, strcspn (self->state.command, " "));
  set_str (self, &self->tag, program != NULL ? program : user_shell (), PROP_TAG);

  notify (self, PROP_STATUS);
  notify (self, PROP_WHEN);
}

static gboolean
is_focused (ApexSession *self)
{
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (self->tab));

  return PTYXIS_IS_WINDOW (root) &&
         gtk_window_is_active (GTK_WINDOW (root)) &&
         ptyxis_window_get_active_tab (PTYXIS_WINDOW (root)) == self->tab;
}

static void
apex_session_update_group (ApexSession *self)
{
  g_autoptr(PtyxisIpcContainer) container = NULL;
  g_autofree char *ssh_host = NULL;
  g_autofree char *key = NULL;
  PtyxisTerminal *terminal = ptyxis_tab_get_terminal (self->tab);
  const char *name = ptyxis_terminal_get_current_container_name (terminal);
  const char *runtime = ptyxis_terminal_get_current_container_runtime (terminal);
  const char *label = NULL;
  const char *pill = NULL;

  if (self->state.remote)
    ssh_host = apex_ssh_host (ptyxis_tab_get_command_line (self->tab));

  if (ssh_host != NULL)
    {
      label = ssh_host;
      pill = "ssh";
      key = g_strconcat ("2", ssh_host, NULL);
    }
  else if (name != NULL && name[0] != '\0')
    {
      label = name;
      pill = runtime != NULL && runtime[0] != '\0' ? runtime : "container";
      key = g_strconcat ("1", name, NULL);
    }
  else if ((container = ptyxis_tab_dup_container (self->tab)) &&
           g_strcmp0 (ptyxis_ipc_container_get_provider (container), "session") != 0)
    {
      label = ptyxis_ipc_container_get_display_name (container);
      pill = ptyxis_ipc_container_get_provider (container);
      key = g_strconcat ("1", label, NULL);
    }
  else
    {
      label = "This computer";
      key = g_strdup (HOST_GROUP_KEY);
    }

  g_set_str (&self->group_label, label);
  g_set_str (&self->group_pill, pill);
  set_str (self, &self->group_key, key, PROP_GROUP_KEY);
}

static char *
home_relative (const char *path)
{
  const char *home = g_get_home_dir ();
  gsize len = strlen (home);

  if (g_str_equal (path, home))
    return g_strdup ("~");
  if (g_str_has_prefix (path, home) && path[len] == G_DIR_SEPARATOR)
    return g_strconcat ("~", path + len, NULL);
  return g_strdup (path);
}

static void
apex_session_update_title (ApexSession *self)
{
  g_autofree char *uri = ptyxis_tab_dup_current_directory_uri (self->tab);
  g_autofree char *file_path = uri != NULL ? g_filename_from_uri (uri, NULL, NULL) : NULL;
  g_autofree char *path = file_path != NULL ? home_relative (file_path) : NULL;
  g_autofree char *title = NULL;
  const char *prefix = ptyxis_tab_get_title_prefix (self->tab);

  set_str (self, &self->path, path, PROP_PATH);

  if (prefix != NULL && prefix[0] != '\0')
    title = g_strdup (prefix);
  else if (self->state.remote && self->group_key[0] == '2')
    title = g_strdup (self->group_label);
  else if (path != NULL)
    title = g_str_equal (path, "~") ? g_strdup ("~") : g_path_get_basename (path);
  else
    title = ptyxis_tab_dup_title (self->tab);

  set_str (self, &self->title, title, PROP_TITLE);
}

static gboolean
apex_session_termprops_cb (ApexSession *self,
                           const int   *props,
                           int          n_props,
                           VteTerminal *terminal)
{
  ApexShellMarks marks = 0;
  guint64 exit_code = 0;

  for (int i = 0; i < n_props; i++)
    {
      if (props[i] == VTE_PROPERTY_ID_SHELL_PRECMD)
        marks |= APEX_SHELL_PRECMD;
      else if (props[i] == VTE_PROPERTY_ID_SHELL_PREEXEC)
        marks |= APEX_SHELL_PREEXEC;
      else if (props[i] == VTE_PROPERTY_ID_SHELL_POSTEXEC &&
               vte_terminal_get_termprop_uint_by_id (terminal, VTE_PROPERTY_ID_SHELL_POSTEXEC, &exit_code))
        marks |= APEX_SHELL_POSTEXEC;
    }

  if (apex_session_state_shell (&self->state, marks, (int) MIN (exit_code, G_MAXINT), g_get_real_time ()))
    apex_session_status_changed (self);
  if (marks & APEX_SHELL_PRECMD)
    apex_session_update_title (self);

  return FALSE;
}

static void
apex_session_bell_cb (ApexSession *self)
{
  if (apex_session_state_bell (&self->state, is_focused (self), g_get_real_time ()))
    apex_session_status_changed (self);
}

static void
apex_session_command_line_cb (ApexSession *self)
{
  if (apex_session_state_command (&self->state, ptyxis_tab_get_command_line (self->tab)))
    apex_session_status_changed (self);
  apex_session_update_group (self);
  apex_session_update_title (self);
}

static void
apex_session_leader_kind_cb (ApexSession *self)
{
  PtyxisProcessLeaderKind kind;

  g_object_get (self->tab, "process-leader-kind", &kind, NULL);
  if (apex_session_state_set_remote (&self->state, kind == PTYXIS_PROCESS_LEADER_KIND_REMOTE))
    apex_session_status_changed (self);
  apex_session_update_group (self);
  apex_session_update_title (self);
}

static void
apex_session_progress_cb (ApexSession *self)
{
  double progress = NO_PROGRESS;

  if (ptyxis_tab_get_progress (self->tab) == PTYXIS_TAB_PROGRESS_ACTIVE)
    progress = ptyxis_tab_get_progress_fraction (self->tab);

  if (progress != self->progress)
    {
      self->progress = progress;
      notify (self, PROP_PROGRESS);
    }
}

static void
apex_session_container_cb (ApexSession *self)
{
  apex_session_update_group (self);
}

static void
apex_session_dispose (GObject *object)
{
  ApexSession *self = (ApexSession *)object;

  g_clear_weak_pointer (&self->page);
  g_clear_weak_pointer (&self->tab);
  g_clear_object (&self->second);

  G_OBJECT_CLASS (apex_session_parent_class)->dispose (object);
}

static void
apex_session_finalize (GObject *object)
{
  ApexSession *self = (ApexSession *)object;

  apex_session_state_clear (&self->state);
  g_free (self->subtitle);
  g_free (self->title);
  g_free (self->path);
  g_free (self->tag);
  g_free (self->group_key);
  g_free (self->group_label);
  g_free (self->group_pill);

  G_OBJECT_CLASS (apex_session_parent_class)->finalize (object);
}

static void
apex_session_get_property (GObject    *object,
                           guint       prop_id,
                           GValue     *value,
                           GParamSpec *pspec)
{
  ApexSession *self = APEX_SESSION (object);

  switch (prop_id)
    {
    case PROP_STATUS:
      g_value_set_int (value, apex_session_get_status (self));
      break;

    case PROP_TITLE:
      g_value_set_string (value, self->title);
      break;

    case PROP_SUBTITLE:
      g_value_set_string (value, self->subtitle);
      break;

    case PROP_PATH:
      g_value_set_string (value, self->path);
      break;

    case PROP_TAG:
      g_value_set_string (value, self->tag);
      break;

    case PROP_GROUP_KEY:
      g_value_set_string (value, self->group_key);
      break;

    case PROP_PROGRESS:
      g_value_set_double (value, self->progress);
      break;

    case PROP_WHEN:
      g_value_take_string (value, apex_session_dup_when (self));
      break;

    case PROP_SPLIT:
      g_value_set_int (value, self->split);
      break;

    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
    }
}

static void
apex_session_class_init (ApexSessionClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  GParamFlags flags = G_PARAM_READABLE | G_PARAM_EXPLICIT_NOTIFY | G_PARAM_STATIC_STRINGS;

  object_class->dispose = apex_session_dispose;
  object_class->finalize = apex_session_finalize;
  object_class->get_property = apex_session_get_property;

  properties[PROP_STATUS] = g_param_spec_int ("status", NULL, NULL, 0, APEX_STATUS_NEEDS_YOU, 0, flags);
  properties[PROP_TITLE] = g_param_spec_string ("title", NULL, NULL, NULL, flags);
  properties[PROP_SUBTITLE] = g_param_spec_string ("subtitle", NULL, NULL, NULL, flags);
  properties[PROP_PATH] = g_param_spec_string ("path", NULL, NULL, NULL, flags);
  properties[PROP_TAG] = g_param_spec_string ("tag", NULL, NULL, NULL, flags);
  properties[PROP_GROUP_KEY] = g_param_spec_string ("group-key", NULL, NULL, NULL, flags);
  properties[PROP_PROGRESS] = g_param_spec_double ("progress", NULL, NULL, NO_PROGRESS, 1, NO_PROGRESS, flags);
  properties[PROP_WHEN] = g_param_spec_string ("when", NULL, NULL, NULL, flags);
  properties[PROP_SPLIT] = g_param_spec_int ("split", NULL, NULL, APEX_SPLIT_NONE, APEX_SPLIT_DOWN, APEX_SPLIT_NONE, flags);

  g_object_class_install_properties (object_class, N_PROPS, properties);
}

static void
apex_session_init (ApexSession *self)
{
  self->progress = NO_PROGRESS;
}

static ApexSession *
apex_session_new (PtyxisTab *tab)
{
  ApexSession *self = g_object_new (APEX_TYPE_SESSION, NULL);
  PtyxisTerminal *terminal;

  g_set_weak_pointer (&self->tab, tab);
  terminal = ptyxis_tab_get_terminal (self->tab);
  apex_session_state_init (&self->state, g_get_real_time ());

  g_signal_connect_object (terminal, "termprops-changed", G_CALLBACK (apex_session_termprops_cb), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (terminal, "termprop-changed::" VTE_TERMPROP_CONTAINER_NAME,
                           G_CALLBACK (apex_session_container_cb), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (terminal, "termprop-changed::" VTE_TERMPROP_CURRENT_DIRECTORY_URI,
                           G_CALLBACK (apex_session_update_title), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (self->tab, "bell", G_CALLBACK (apex_session_bell_cb), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (self->tab, "notify::command-line", G_CALLBACK (apex_session_command_line_cb), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (self->tab, "notify::process-leader-kind", G_CALLBACK (apex_session_leader_kind_cb), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (self->tab, "notify::progress", G_CALLBACK (apex_session_progress_cb), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (self->tab, "notify::progress-fraction", G_CALLBACK (apex_session_progress_cb), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (self->tab, "notify::title-prefix", G_CALLBACK (apex_session_update_title), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (self->tab, "notify::title", G_CALLBACK (apex_session_update_title), self, G_CONNECT_SWAPPED);

  apex_session_update_group (self);
  apex_session_update_title (self);
  apex_session_status_changed (self);
  apex_session_progress_cb (self);

  return self;
}

/* The session lives as long as its tab, so it keeps its state when the tab moves to
 * another window. */
ApexSession *
apex_session_for_tab (PtyxisTab *tab)
{
  ApexSession *self = g_object_get_data (G_OBJECT (tab), "apex-session");

  if (self == NULL)
    {
      self = apex_session_new (tab);
      g_object_set_data_full (G_OBJECT (tab), "apex-session", self, g_object_unref);
    }

  return g_object_ref (self);
}

ApexSession *
apex_session_for_page (AdwTabPage *page)
{
  ApexSession *self = apex_session_for_tab (PTYXIS_TAB (adw_tab_page_get_child (page)));

  g_set_weak_pointer (&self->page, page);
  return self;
}

AdwTabPage *
apex_session_get_page (ApexSession *self)
{
  return self->page;
}

PtyxisTab *
apex_session_get_tab (ApexSession *self)
{
  return self->tab;
}

ApexStatus
apex_session_get_pane_status (ApexSession *self)
{
  return apex_session_state_status (&self->state);
}

static int
status_rank (ApexStatus status)
{
  switch (status)
    {
    case APEX_STATUS_NEEDS_YOU:
      return 4;
    case APEX_STATUS_RUNNING:
      return 3;
    case APEX_STATUS_FAILED:
      return 2;
    case APEX_STATUS_DONE:
      return 1;
    case APEX_STATUS_IDLE:
    default:
      return 0;
    }
}

ApexStatus
apex_session_get_status (ApexSession *self)
{
  ApexStatus own = apex_session_get_pane_status (self);
  ApexStatus second;

  if (self->second == NULL)
    return own;

  second = apex_session_get_pane_status (self->second);
  return status_rank (second) > status_rank (own) ? second : own;
}

const char *
apex_session_get_pane_title (ApexSession *self)
{
  if (self->state.in_command && self->state.command != NULL)
    return self->state.command;
  return _("Shell");
}

ApexSession *
apex_session_get_second (ApexSession *self)
{
  return self->second;
}

ApexSplit
apex_session_get_split (ApexSession *self)
{
  return self->split;
}

static void
apex_session_second_status_cb (ApexSession *self)
{
  notify (self, PROP_STATUS);
}

void
apex_session_set_second (ApexSession *self,
                         ApexSession *second,
                         ApexSplit    split)
{
  if (self->second != NULL)
    g_signal_handlers_disconnect_by_func (self->second, apex_session_second_status_cb, self);

  g_set_object (&self->second, second);
  self->split = second != NULL ? split : APEX_SPLIT_NONE;

  if (second != NULL)
    g_signal_connect_object (second, "notify::status", G_CALLBACK (apex_session_second_status_cb), self, G_CONNECT_SWAPPED);

  notify (self, PROP_SPLIT);
  notify (self, PROP_STATUS);
}

const char *
apex_session_get_title (ApexSession *self)
{
  return self->title;
}

const char *
apex_session_get_subtitle (ApexSession *self)
{
  return self->subtitle;
}

const char *
apex_session_get_path (ApexSession *self)
{
  return self->path;
}

const char *
apex_session_get_tag (ApexSession *self)
{
  return self->tag;
}

const char *
apex_session_get_group_key (ApexSession *self)
{
  return self->group_key;
}

const char *
apex_session_get_group_label (ApexSession *self)
{
  return self->group_label;
}

const char *
apex_session_get_group_pill (ApexSession *self)
{
  return self->group_pill;
}

double
apex_session_get_progress (ApexSession *self)
{
  return self->progress;
}

char *
apex_session_dup_when (ApexSession *self)
{
  return apex_relative_time (self->state.changed_at, g_get_real_time ());
}

void
apex_session_focused (ApexSession *self)
{
  if (apex_session_state_focus (&self->state))
    apex_session_status_changed (self);
}

void
apex_session_tick (ApexSession *self)
{
  notify (self, PROP_WHEN);
}
