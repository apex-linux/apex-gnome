/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-session-state.h"

#include <string.h>

void
apex_session_state_init (ApexSessionState *state,
                         gint64            now)
{
  memset (state, 0, sizeof *state);
  state->base = APEX_STATUS_IDLE;
  state->exit_code = APEX_EXIT_UNKNOWN;
  state->changed_at = now;
}

void
apex_session_state_clear (ApexSessionState *state)
{
  g_clear_pointer (&state->command, g_free);
}

gboolean
apex_session_state_preexec (ApexSessionState *state,
                            gint64            now)
{
  state->in_command = TRUE;
  state->exit_code = APEX_EXIT_UNKNOWN;
  g_clear_pointer (&state->command, g_free);
  state->base = APEX_STATUS_RUNNING;
  state->changed_at = now;
  return TRUE;
}

gboolean
apex_session_state_command (ApexSessionState *state,
                            const char       *cmdline)
{
  g_autofree char *display = apex_command_display (cmdline);

  if (!state->in_command || display == NULL || g_strcmp0 (display, state->command) == 0)
    return FALSE;

  g_free (state->command);
  state->command = g_steal_pointer (&display);
  return TRUE;
}

/* bash reports the last status at every prompt, an empty line included: only a
 * status that follows a preexec belongs to a command. */
gboolean
apex_session_state_postexec (ApexSessionState *state,
                             int               exit_code)
{
  if (!state->in_command)
    return FALSE;

  state->exit_code = exit_code;
  return FALSE;
}

gboolean
apex_session_state_precmd (ApexSessionState *state,
                           gint64            now)
{
  if (!state->in_command)
    return FALSE;

  state->in_command = FALSE;
  state->base = state->exit_code > 0 ? APEX_STATUS_FAILED : APEX_STATUS_DONE;
  state->changed_at = now;
  return TRUE;
}

/* VTE hands over the marks of one batch by termprop id, precmd first. At a prompt
 * they can only be a command that started and ended; in one, its end, then the next. */
gboolean
apex_session_state_shell (ApexSessionState *state,
                          ApexShellMarks    marks,
                          int               exit_code,
                          gint64            now)
{
  gboolean changed = FALSE;

  if (!state->in_command && (marks & APEX_SHELL_PREEXEC))
    {
      changed |= apex_session_state_preexec (state, now);
      marks &= ~APEX_SHELL_PREEXEC;
    }
  if (marks & APEX_SHELL_POSTEXEC)
    changed |= apex_session_state_postexec (state, exit_code);
  if (marks & APEX_SHELL_PRECMD)
    changed |= apex_session_state_precmd (state, now);
  if (marks & APEX_SHELL_PREEXEC)
    changed |= apex_session_state_preexec (state, now);

  return changed;
}

gboolean
apex_session_state_bell (ApexSessionState *state,
                         gboolean          focused,
                         gint64            now)
{
  if (focused || state->needs_you)
    return FALSE;

  state->needs_you = TRUE;
  state->changed_at = now;
  return TRUE;
}

gboolean
apex_session_state_focus (ApexSessionState *state)
{
  if (!state->needs_you)
    return FALSE;

  state->needs_you = FALSE;
  return TRUE;
}

gboolean
apex_session_state_set_remote (ApexSessionState *state,
                               gboolean          remote)
{
  if (state->remote == !!remote)
    return FALSE;

  state->remote = !!remote;
  return TRUE;
}

/* The prompts a remote shell sends never reach this side's integration, so its
 * session would read "running ssh" for as long as it stays open. */
ApexStatus
apex_session_state_status (const ApexSessionState *state)
{
  if (state->needs_you)
    return APEX_STATUS_NEEDS_YOU;

  if (state->remote)
    return APEX_STATUS_IDLE;

  return state->base;
}

static const char *
status_word (const ApexSessionState *state,
             char                   *buf,
             gsize                   len)
{
  switch (apex_session_state_status (state))
    {
    case APEX_STATUS_RUNNING:
      return "running";

    case APEX_STATUS_DONE:
      return "done";

    case APEX_STATUS_FAILED:
      g_snprintf (buf, len, "exit %d", state->exit_code);
      return buf;

    case APEX_STATUS_NEEDS_YOU:
      return "needs you";

    case APEX_STATUS_IDLE:
    default:
      return NULL;
    }
}

char *
apex_session_state_subtitle (const ApexSessionState *state)
{
  char buf[32];
  const char *word = status_word (state, buf, sizeof buf);

  if (state->command != NULL && word != NULL)
    return g_strdup_printf ("%s · %s", state->command, word);

  return g_strdup (state->command != NULL ? state->command : word);
}

char *
apex_command_display (const char *cmdline)
{
  g_auto(GStrv) words = NULL;
  GString *display = NULL;

  if (cmdline == NULL)
    return NULL;

  words = g_strsplit_set (cmdline, " \t\n", -1);
  for (guint i = 0; words[i] != NULL; i++)
    {
      if (words[i][0] == '\0')
        continue;

      if (display == NULL)
        {
          g_autofree char *program = g_path_get_basename (words[i]);
          display = g_string_new (program);
        }
      else
        g_string_append_printf (display, " %s", words[i]);
    }

  return display != NULL ? g_string_free (display, FALSE) : NULL;
}

char *
apex_relative_time (gint64 then,
                    gint64 now)
{
  gint64 secs = MAX (0, (now - then) / G_USEC_PER_SEC);

  if (secs < 60)
    return g_strdup ("now");
  if (secs < 60 * 60)
    return g_strdup_printf ("%" G_GINT64_FORMAT "m", secs / 60);
  if (secs < 24 * 60 * 60)
    return g_strdup_printf ("%" G_GINT64_FORMAT "h", secs / (60 * 60));
  return g_strdup_printf ("%" G_GINT64_FORMAT "d", secs / (24 * 60 * 60));
}

/* ssh(1)'s options that take an argument, so the destination is the first word after them. */
#define SSH_OPTIONS_WITH_ARGUMENT "BbcDEeFIiJLlmOoPpQRSWw"

char *
apex_ssh_host (const char *cmdline)
{
  g_auto(GStrv) argv = NULL;
  g_autofree char *program = NULL;
  const char *destination = NULL;
  const char *host;

  if (cmdline == NULL || !g_shell_parse_argv (cmdline, NULL, &argv, NULL))
    return NULL;

  program = g_path_get_basename (argv[0]);
  if (g_strcmp0 (program, "ssh") != 0)
    return NULL;

  for (guint i = 1; argv[i] != NULL && destination == NULL; i++)
    {
      const char *arg = argv[i];

      if (arg[0] != '-')
        destination = arg;
      else if (arg[1] != '\0' && arg[2] == '\0' && strchr (SSH_OPTIONS_WITH_ARGUMENT, arg[1]))
        i++;
    }

  if (destination == NULL)
    return NULL;

  if (g_str_has_prefix (destination, "ssh://"))
    destination += strlen ("ssh://");
  host = strrchr (destination, '@');
  host = host != NULL ? host + 1 : destination;

  return g_strndup (host, strcspn (host, ":/"));
}
