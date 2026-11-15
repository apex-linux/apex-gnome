/* SPDX-License-Identifier: GPL-3.0-or-later */

/* apex-toolbox-exec: run one process in a toolbox through its bridge.
 *
 *   apex-toolbox-exec --container ID --user NAME --cwd DIR --fds N [--env K=V]... -- ARGV...
 *
 * Builder's podman runtime runs this on the host instead of `podman exec` (patch 0006).
 * It passes its descriptors 0 to N - 1 to the toolbox's bridge, starting the bridge with
 * `podman exec --detach` when none answers, passes on SIGTERM, SIGINT, SIGHUP and SIGQUIT,
 * and exits as the process did. Without a bridge it execs `podman exec`, as before. */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "apex-toolbox-bridge.h"

#ifndef PACKAGE_LIBEXECDIR
# define PACKAGE_LIBEXECDIR "/usr/libexec"
#endif

static const char *container;
static const char *user;
static const char *cwd;
static int n_fds = 3;
static char **envs;
static int n_envs;
static char **args;
static int n_args;
static int sock = -1;

static void
usage (void)
{
  fprintf (stderr, "usage: apex-toolbox-exec --container ID --user NAME --cwd DIR --fds N [--env K=V]... -- ARGV...\n");
  exit (125);
}

static void
parse (int argc, char **argv)
{
  envs = calloc (argc, sizeof *envs);

  for (int i = 1; i < argc; i++)
    {
      if (strcmp (argv[i], "--") == 0)
        {
          args = &argv[i + 1];
          n_args = argc - i - 1;
          break;
        }
      if (i + 1 >= argc)
        usage ();
      if (strcmp (argv[i], "--container") == 0)
        container = argv[++i];
      else if (strcmp (argv[i], "--user") == 0)
        user = argv[++i];
      else if (strcmp (argv[i], "--cwd") == 0)
        cwd = argv[++i];
      else if (strcmp (argv[i], "--fds") == 0)
        n_fds = atoi (argv[++i]);
      else if (strcmp (argv[i], "--env") == 0)
        envs[n_envs++] = argv[++i];
      else
        usage ();
    }

  if (container == NULL || user == NULL || cwd == NULL || n_args < 1 ||
      n_fds < 3 || n_fds > APEX_BRIDGE_MAX_FDS)
    usage ();
}

static void
socket_path (char *path, size_t size)
{
  const char *runtime_dir = getenv ("XDG_RUNTIME_DIR");

  if (runtime_dir == NULL || runtime_dir[0] != '/')
    runtime_dir = "/tmp";
  snprintf (path, size, APEX_BRIDGE_SOCKET_FORMAT, runtime_dir, container);
}

static int
connect_bridge (const char *path)
{
  struct sockaddr_un addr = { .sun_family = AF_UNIX };
  int fd;

  if (strlen (path) >= sizeof addr.sun_path)
    return -1;
  strcpy (addr.sun_path, path);

  if ((fd = socket (AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)) < 0)
    return -1;
  if (connect (fd, (struct sockaddr *)&addr, sizeof addr) == 0)
    {
      /* Above the process's descriptors, which a free low number would join. */
      int high = fcntl (fd, F_DUPFD_CLOEXEC, APEX_BRIDGE_MAX_FDS);
      close (fd);
      return high;
    }
  close (fd);
  return -1;
}

static int
run_quiet (char **argv)
{
  pid_t pid = fork ();
  int status;

  if (pid == 0)
    {
      int null = open ("/dev/null", O_RDWR | O_CLOEXEC);
      dup2 (null, STDIN_FILENO);
      dup2 (null, STDOUT_FILENO);
      dup2 (null, STDERR_FILENO);
      execvp (argv[0], argv);
      _exit (127);
    }
  if (pid < 0 || waitpid (pid, &status, 0) < 0)
    return -1;
  return WIFEXITED (status) ? WEXITSTATUS (status) : -1;
}

/* The bridge serves every client of its toolbox; the first client to miss it starts it,
 * and the bridge's lock makes a second start a no-op. */
static int
start_bridge (const char *path)
{
  char bridge[4096], socket_arg[4096], user_arg[512];
  char *argv[] = { "podman", "exec", "--detach", "--privileged", user_arg, (char *)container,
                   bridge, socket_arg, NULL };
  struct timespec pause = { 0, 50 * 1000 * 1000 };

  snprintf (bridge, sizeof bridge, "/run/host%s/apex-toolbox-bridge", PACKAGE_LIBEXECDIR);
  snprintf (socket_arg, sizeof socket_arg, "/run/host%s", path);
  snprintf (user_arg, sizeof user_arg, "--user=%s", user);

  if (run_quiet (argv) != 0)
    return -1;

  for (int i = 0; i < 100; i++)
    {
      int fd = connect_bridge (path);
      if (fd >= 0)
        return fd;
      nanosleep (&pause, NULL);
    }

  return -1;
}

/* Without a bridge, the process runs as Builder would have run it. */
static void
exec_podman (void)
{
  char **argv = calloc (n_args + 2 * n_envs + 16, sizeof *argv);
  char user_arg[512], cwd_arg[4096], fds_arg[64];
  int n = 0;

  snprintf (user_arg, sizeof user_arg, "--user=%s", user);
  snprintf (cwd_arg, sizeof cwd_arg, "--workdir=%s", cwd);
  snprintf (fds_arg, sizeof fds_arg, "--preserve-fds=%d", n_fds - 3);

  argv[n++] = "podman";
  argv[n++] = "exec";
  argv[n++] = "--privileged";
  argv[n++] = "--interactive";
  argv[n++] = user_arg;
  argv[n++] = "--detach-keys=";
  argv[n++] = cwd_arg;
  if (n_fds > 3)
    argv[n++] = fds_arg;
  for (int i = 0; i < n_envs; i++)
    {
      argv[n++] = "--env";
      argv[n++] = envs[i];
    }
  argv[n++] = (char *)container;
  for (int i = 0; i < n_args; i++)
    argv[n++] = args[i];

  execvp ("podman", argv);
  perror ("apex-toolbox-exec: podman");
  exit (127);
}

static int
send_request (void)
{
  int fds[APEX_BRIDGE_MAX_FDS];
  char control[CMSG_SPACE (sizeof fds)];
  char argc_str[16];
  size_t len = 0, off = 0;
  char *payload;
  ApexBridgeHeader header = { APEX_BRIDGE_MAGIC, n_fds, 0 };
  struct iovec iov = { &header, sizeof header };
  struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = control,
                        .msg_controllen = CMSG_SPACE (n_fds * sizeof (int)) };
  struct cmsghdr *cmsg;

  snprintf (argc_str, sizeof argc_str, "%d", n_args);
  len += strlen (cwd) + 1 + strlen (argc_str) + 1;
  for (int i = 0; i < n_args; i++)
    len += strlen (args[i]) + 1;
  for (int i = 0; i < n_envs; i++)
    len += strlen (envs[i]) + 1;
  if (len > APEX_BRIDGE_MAX_PAYLOAD || !(payload = malloc (len)))
    return -1;

#define PUT(s) do { size_t l = strlen (s) + 1; memcpy (payload + off, s, l); off += l; } while (0)
  PUT (cwd);
  PUT (argc_str);
  for (int i = 0; i < n_args; i++)
    PUT (args[i]);
  for (int i = 0; i < n_envs; i++)
    PUT (envs[i]);
#undef PUT

  /* A descriptor Builder did not pass is replaced by /dev/null, as podman would see it closed. */
  for (int i = 0; i < n_fds; i++)
    fds[i] = fcntl (i, F_GETFD) < 0 ? open ("/dev/null", O_RDWR | O_CLOEXEC) : i;

  header.payload_len = len;
  memset (control, 0, sizeof control);
  cmsg = CMSG_FIRSTHDR (&msg);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN (n_fds * sizeof (int));
  memcpy (CMSG_DATA (cmsg), fds, n_fds * sizeof (int));

  if (sendmsg (sock, &msg, MSG_NOSIGNAL) != sizeof header)
    return -1;
  for (size_t done = 0; done < len;)
    {
      ssize_t r = send (sock, payload + done, len - done, MSG_NOSIGNAL);
      if (r <= 0)
        return -1;
      done += r;
    }

  free (payload);
  return 0;
}

static void
forward_signal (int signo)
{
  int32_t value = signo;
  int saved = errno;

  if (send (sock, &value, sizeof value, MSG_NOSIGNAL | MSG_DONTWAIT) < 0)
    {
      /* Nothing to do: the bridge kills the process when this client goes. */
    }
  errno = saved;
}

int
main (int argc, char **argv)
{
  char path[4096];
  ApexBridgeStatus status;
  size_t got = 0;
  struct sigaction sa = { .sa_handler = forward_signal };
  const int forwarded[] = { SIGTERM, SIGINT, SIGHUP, SIGQUIT };

  parse (argc, argv);
  socket_path (path, sizeof path);

  if ((sock = connect_bridge (path)) < 0 && (sock = start_bridge (path)) < 0)
    exec_podman ();

  for (size_t i = 0; i < sizeof forwarded / sizeof forwarded[0]; i++)
    sigaction (forwarded[i], &sa, NULL);
  signal (SIGPIPE, SIG_IGN);

  if (send_request () < 0)
    {
      fprintf (stderr, "apex-toolbox-exec: the bridge took no request\n");
      return 125;
    }

  while (got < sizeof status)
    {
      ssize_t r = recv (sock, (char *)&status + got, sizeof status - got, 0);
      if (r < 0 && errno == EINTR)
        continue;
      if (r <= 0)
        {
          fprintf (stderr, "apex-toolbox-exec: the bridge went away\n");
          return 125;
        }
      got += r;
    }

  if (status.signaled)
    {
      signal (status.value, SIG_DFL);
      raise (status.value);
      return 128 + status.value;
    }

  return status.value;
}
