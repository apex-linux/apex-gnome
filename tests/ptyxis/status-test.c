/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-session-state.h"

#define SECONDS(n) ((gint64) (n) * G_USEC_PER_SEC)

typedef struct
{
  ApexSessionState state;
} Fixture;

static void
fixture_set_up (Fixture       *f,
                gconstpointer  data)
{
  apex_session_state_init (&f->state, 0);
}

static void
fixture_tear_down (Fixture       *f,
                   gconstpointer  data)
{
  apex_session_state_clear (&f->state);
}

static void
assert_subtitle (const ApexSessionState *state,
                 const char             *expected)
{
  g_autofree char *subtitle = apex_session_state_subtitle (state);

  g_assert_cmpstr (subtitle, ==, expected);
}

static void
run_command (ApexSessionState *state,
             const char       *cmdline,
             int               exit_code,
             gint64            now)
{
  apex_session_state_preexec (state, now);
  if (cmdline != NULL)
    apex_session_state_command (state, cmdline);
  apex_session_state_postexec (state, exit_code);
  apex_session_state_precmd (state, now);
}

static void
test_new_session_is_idle (Fixture       *f,
                          gconstpointer  data)
{
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_IDLE);
  assert_subtitle (&f->state, NULL);
}

static void
test_preexec_runs (Fixture       *f,
                   gconstpointer  data)
{
  g_assert_true (apex_session_state_preexec (&f->state, SECONDS (5)));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_RUNNING);
  assert_subtitle (&f->state, "running");

  g_assert_true (apex_session_state_command (&f->state, "/usr/bin/just  vm-image"));
  assert_subtitle (&f->state, "just vm-image · running");
  g_assert_cmpint (f->state.changed_at, ==, SECONDS (5));
}

static void
test_success_is_done (Fixture       *f,
                      gconstpointer  data)
{
  run_command (&f->state, "cargo test", 0, SECONDS (9));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_DONE);
  assert_subtitle (&f->state, "cargo test · done");
  g_assert_cmpint (f->state.changed_at, ==, SECONDS (9));
}

static void
test_failure_shows_exit_code (Fixture       *f,
                              gconstpointer  data)
{
  run_command (&f->state, "rpmbuild -bb apex-desktop.spec", 1, SECONDS (1));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_FAILED);
  assert_subtitle (&f->state, "rpmbuild -bb apex-desktop.spec · exit 1");
}

static void
test_fast_command_without_cmdline (Fixture       *f,
                                   gconstpointer  data)
{
  run_command (&f->state, NULL, 1, SECONDS (1));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_FAILED);
  assert_subtitle (&f->state, "exit 1");
}

#define PROMPT_MARKS (APEX_SHELL_POSTEXEC | APEX_SHELL_PRECMD)
#define ALL_MARKS (PROMPT_MARKS | APEX_SHELL_PREEXEC)

static void
test_one_batch_command_ends (Fixture       *f,
                             gconstpointer  data)
{
  g_assert_true (apex_session_state_shell (&f->state, ALL_MARKS, 0, SECONDS (1)));
  g_assert_false (f->state.in_command);
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_DONE);

  g_assert_true (apex_session_state_shell (&f->state, ALL_MARKS, 2, SECONDS (2)));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_FAILED);
  assert_subtitle (&f->state, "exit 2");
}

static void
test_one_batch_in_a_command (Fixture       *f,
                             gconstpointer  data)
{
  apex_session_state_preexec (&f->state, SECONDS (1));

  g_assert_true (apex_session_state_shell (&f->state, PROMPT_MARKS, 1, SECONDS (2)));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_FAILED);

  apex_session_state_preexec (&f->state, SECONDS (3));
  g_assert_true (apex_session_state_shell (&f->state, ALL_MARKS, 1, SECONDS (4)));
  g_assert_true (f->state.in_command);
  g_assert_cmpint (f->state.exit_code, ==, APEX_EXIT_UNKNOWN);
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_RUNNING);
}

static void
test_one_batch_empty_prompt_keeps_status (Fixture       *f,
                                          gconstpointer  data)
{
  run_command (&f->state, "false", 1, SECONDS (1));

  g_assert_false (apex_session_state_shell (&f->state, PROMPT_MARKS, 0, SECONDS (30)));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_FAILED);
  g_assert_cmpint (f->state.changed_at, ==, SECONDS (1));
}

static void
test_empty_prompt_keeps_status (Fixture       *f,
                                gconstpointer  data)
{
  run_command (&f->state, "false", 1, SECONDS (1));

  g_assert_false (apex_session_state_postexec (&f->state, 0));
  g_assert_false (apex_session_state_precmd (&f->state, SECONDS (30)));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_FAILED);
  g_assert_cmpint (f->state.changed_at, ==, SECONDS (1));
}

static void
test_next_command_clears_failure (Fixture       *f,
                                  gconstpointer  data)
{
  run_command (&f->state, "false", 1, SECONDS (1));
  run_command (&f->state, "true", 0, SECONDS (2));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_DONE);
  assert_subtitle (&f->state, "true · done");
}

static void
test_command_outside_a_command_is_ignored (Fixture       *f,
                                           gconstpointer  data)
{
  g_assert_false (apex_session_state_command (&f->state, "bash"));
  assert_subtitle (&f->state, NULL);
}

static void
test_bell_unfocused_needs_you (Fixture       *f,
                               gconstpointer  data)
{
  apex_session_state_preexec (&f->state, SECONDS (1));
  apex_session_state_command (&f->state, "claude");

  g_assert_true (apex_session_state_bell (&f->state, FALSE, SECONDS (7)));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_NEEDS_YOU);
  assert_subtitle (&f->state, "claude · needs you");
  g_assert_cmpint (f->state.changed_at, ==, SECONDS (7));

  g_assert_false (apex_session_state_bell (&f->state, FALSE, SECONDS (8)));
  g_assert_cmpint (f->state.changed_at, ==, SECONDS (7));
}

static void
test_bell_focused_is_ignored (Fixture       *f,
                              gconstpointer  data)
{
  g_assert_false (apex_session_state_bell (&f->state, TRUE, SECONDS (1)));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_IDLE);
}

static void
test_needs_you_holds_until_focus (Fixture       *f,
                                  gconstpointer  data)
{
  apex_session_state_preexec (&f->state, SECONDS (1));
  apex_session_state_bell (&f->state, FALSE, SECONDS (2));
  apex_session_state_postexec (&f->state, 0);
  apex_session_state_precmd (&f->state, SECONDS (3));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_NEEDS_YOU);

  g_assert_true (apex_session_state_focus (&f->state));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_DONE);
  g_assert_false (apex_session_state_focus (&f->state));
}

static void
test_remote_reads_idle (Fixture       *f,
                        gconstpointer  data)
{
  apex_session_state_preexec (&f->state, SECONDS (1));
  apex_session_state_command (&f->state, "ssh builder@apex-builder");
  g_assert_true (apex_session_state_set_remote (&f->state, TRUE));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_IDLE);
  assert_subtitle (&f->state, "ssh builder@apex-builder");

  apex_session_state_bell (&f->state, FALSE, SECONDS (2));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_NEEDS_YOU);

  apex_session_state_focus (&f->state);
  g_assert_false (apex_session_state_set_remote (&f->state, TRUE));
  g_assert_true (apex_session_state_set_remote (&f->state, FALSE));
  g_assert_cmpint (apex_session_state_status (&f->state), ==, APEX_STATUS_RUNNING);
}

static void
test_command_display (void)
{
  const struct { const char *in, *out; } cases[] = {
    { "/usr/bin/cargo test --workspace", "cargo test --workspace" },
    { "  just\tvm-image\n", "just vm-image" },
    { "claude", "claude" },
    { "", NULL },
    { NULL, NULL },
  };

  for (guint i = 0; i < G_N_ELEMENTS (cases); i++)
    {
      g_autofree char *display = apex_command_display (cases[i].in);
      g_assert_cmpstr (display, ==, cases[i].out);
    }
}

static void
test_relative_time (void)
{
  const struct { gint64 secs; const char *out; } cases[] = {
    { 0, "now" }, { 59, "now" }, { 60, "1m" }, { 4 * 60 + 59, "4m" },
    { 59 * 60, "59m" }, { 60 * 60, "1h" }, { 23 * 3600, "23h" }, { 48 * 3600, "2d" },
    { -5, "now" },
  };

  for (guint i = 0; i < G_N_ELEMENTS (cases); i++)
    {
      g_autofree char *when = apex_relative_time (SECONDS (100), SECONDS (100 + cases[i].secs));
      g_assert_cmpstr (when, ==, cases[i].out);
    }
}

static void
test_ssh_host (void)
{
  const struct { const char *in, *out; } cases[] = {
    { "ssh builder@apex-builder", "apex-builder" },
    { "/usr/bin/ssh -p 2222 -o StrictHostKeyChecking=no apex-builder uptime", "apex-builder" },
    { "ssh -4A ssh://me@host.example:2222", "host.example" },
    { "ssh -v", NULL },
    { "sshd -D", NULL },
    { "mosh host", NULL },
    { "ssh 'unterminated", NULL },
    { NULL, NULL },
  };

  for (guint i = 0; i < G_N_ELEMENTS (cases); i++)
    {
      g_autofree char *host = apex_ssh_host (cases[i].in);
      g_assert_cmpstr (host, ==, cases[i].out);
    }
}

#define ADD(path, fn) g_test_add (path, Fixture, NULL, fixture_set_up, fn, fixture_tear_down)

int
main (int   argc,
      char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  ADD ("/apex/status/new-session-is-idle", test_new_session_is_idle);
  ADD ("/apex/status/preexec-runs", test_preexec_runs);
  ADD ("/apex/status/success-is-done", test_success_is_done);
  ADD ("/apex/status/failure-shows-exit-code", test_failure_shows_exit_code);
  ADD ("/apex/status/fast-command-without-cmdline", test_fast_command_without_cmdline);
  ADD ("/apex/status/empty-prompt-keeps-status", test_empty_prompt_keeps_status);
  ADD ("/apex/status/one-batch-command-ends", test_one_batch_command_ends);
  ADD ("/apex/status/one-batch-in-a-command", test_one_batch_in_a_command);
  ADD ("/apex/status/one-batch-empty-prompt", test_one_batch_empty_prompt_keeps_status);
  ADD ("/apex/status/next-command-clears-failure", test_next_command_clears_failure);
  ADD ("/apex/status/command-outside-a-command", test_command_outside_a_command_is_ignored);
  ADD ("/apex/status/bell-unfocused-needs-you", test_bell_unfocused_needs_you);
  ADD ("/apex/status/bell-focused-is-ignored", test_bell_focused_is_ignored);
  ADD ("/apex/status/needs-you-holds-until-focus", test_needs_you_holds_until_focus);
  ADD ("/apex/status/remote-reads-idle", test_remote_reads_idle);
  g_test_add_func ("/apex/text/command-display", test_command_display);
  g_test_add_func ("/apex/text/relative-time", test_relative_time);
  g_test_add_func ("/apex/text/ssh-host", test_ssh_host);

  return g_test_run ();
}
