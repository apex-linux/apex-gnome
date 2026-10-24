/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <glib.h>

G_BEGIN_DECLS

typedef enum
{
  APEX_STATUS_IDLE,
  APEX_STATUS_RUNNING,
  APEX_STATUS_DONE,
  APEX_STATUS_FAILED,
  APEX_STATUS_NEEDS_YOU,
} ApexStatus;

#define APEX_EXIT_UNKNOWN (-1)

typedef struct
{
  ApexStatus  base;
  gboolean    needs_you;
  gboolean    remote;
  gboolean    in_command;
  int         exit_code;
  char       *command;
  gint64      changed_at;
} ApexSessionState;

void        apex_session_state_init      (ApexSessionState *state,
                                          gint64            now);
void        apex_session_state_clear     (ApexSessionState *state);

gboolean    apex_session_state_preexec   (ApexSessionState *state,
                                          gint64            now);
gboolean    apex_session_state_command   (ApexSessionState *state,
                                          const char       *cmdline);
gboolean    apex_session_state_postexec  (ApexSessionState *state,
                                          int               exit_code);
gboolean    apex_session_state_precmd    (ApexSessionState *state,
                                          gint64            now);
gboolean    apex_session_state_bell      (ApexSessionState *state,
                                          gboolean          focused,
                                          gint64            now);
gboolean    apex_session_state_focus     (ApexSessionState *state);
gboolean    apex_session_state_set_remote (ApexSessionState *state,
                                           gboolean          remote);

ApexStatus  apex_session_state_status    (const ApexSessionState *state);
char       *apex_session_state_subtitle  (const ApexSessionState *state);

char       *apex_command_display         (const char *cmdline);
char       *apex_relative_time           (gint64      then,
                                          gint64      now);
char       *apex_ssh_host                (const char *cmdline);

G_END_DECLS
