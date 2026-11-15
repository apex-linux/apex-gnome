/* SPDX-License-Identifier: GPL-3.0-or-later */

/* apex-toolbox-bridge SOCKET: the one process per toolbox that runs what Builder runs there.
 *
 * apex-toolbox-exec starts it with `podman exec --detach`, from the host's libexec under
 * /run/host. A lock beside the socket keeps it to one per toolbox. For each request it
 * forks a handler, which spawns the process on the client's descriptors in its own
 * process group, passes on the client's signals, kills the group when the client goes,
 * and replies with how the process ended. No client copies stdio, so the host keeps one
 * conmon per toolbox instead of a podman client and a conmon per process. */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include "apex-toolbox-bridge.h"

static int
recv_all (int fd, void *buf, size_t len)
{
  for (size_t got = 0; got < len;)
    {
      ssize_t r = recv (fd, (char *)buf + got, len - got, 0);
      if (r < 0 && errno == EINTR)
        continue;
      if (r <= 0)
        return -1;
      got += r;
    }
  return 0;
}

/* The client's environment over the toolbox's, as `podman exec --env` gives it. */
static char **
merge_env (char **extra, int n_extra)
{
  int n = 0;
  char **env;

  while (environ[n])
    n++;
  env = calloc (n + n_extra + 1, sizeof *env);
  for (int i = 0; i < n; i++)
    env[i] = environ[i];

  for (int j = 0; j < n_extra; j++)
    {
      size_t key = strcspn (extra[j], "=");
      int i;

      for (i = 0; i < n; i++)
        if (strncmp (env[i], extra[j], key) == 0 && env[i][key] == '=')
          break;
      env[i] = extra[j];
      if (i == n)
        n++;
    }

  return env;
}

static void
spawn_child (char *cwd, char **argv, char **env, int *fds, int n_fds)
{
  /* Out of 0 to n_fds - 1 first, so that dup2 never closes one still to move. */
  for (int i = 0; i < n_fds; i++)
    fds[i] = fcntl (fds[i], F_DUPFD, n_fds + 3);
  for (int i = 0; i < n_fds; i++)
    {
      dup2 (fds[i], i);
      close (fds[i]);
    }
  closefrom (n_fds);

  setpgid (0, 0);
  signal (SIGPIPE, SIG_DFL);

  if (chdir (cwd) < 0)
    {
      dprintf (STDERR_FILENO, "apex-toolbox-bridge: %s: %s\n", cwd, strerror (errno));
      _exit (127);
    }

  environ = env;
  execvp (argv[0], argv);
  dprintf (STDERR_FILENO, "apex-toolbox-bridge: %s: %s\n", argv[0], strerror (errno));
  _exit (127);
}

static void
handle (int client)
{
  ApexBridgeHeader header;
  int fds[APEX_BRIDGE_MAX_FDS];
  char control[CMSG_SPACE (sizeof fds)];
  struct iovec iov = { &header, sizeof header };
  struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = control, .msg_controllen = sizeof control };
  struct cmsghdr *cmsg;
  ApexBridgeStatus status = { 0, 127 };
  char *payload, *p, *end, *cwd, **argv, **extra, **env;
  int n_fds = 0, argc, n_extra = 0, pidfd, wstatus;
  pid_t pid;

  if (recvmsg (client, &msg, MSG_CMSG_CLOEXEC) != sizeof header || header.magic != APEX_BRIDGE_MAGIC ||
      header.payload_len == 0 || header.payload_len > APEX_BRIDGE_MAX_PAYLOAD)
    _exit (1);

  for (cmsg = CMSG_FIRSTHDR (&msg); cmsg; cmsg = CMSG_NXTHDR (&msg, cmsg))
    if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS)
      {
        n_fds = (cmsg->cmsg_len - CMSG_LEN (0)) / sizeof (int);
        memcpy (fds, CMSG_DATA (cmsg), n_fds * sizeof (int));
      }
  if (n_fds != (int)header.n_fds || n_fds < 3)
    _exit (1);

  payload = malloc (header.payload_len + 1);
  if (payload == NULL || recv_all (client, payload, header.payload_len) < 0)
    _exit (1);
  payload[header.payload_len] = '\0';

  /* cwd, argc, the arguments, then the environment, each NUL-ended. */
  end = payload + header.payload_len;
  cwd = payload;
  p = cwd + strlen (cwd) + 1;
  if (p >= end || (argc = atoi (p)) < 1)
    _exit (1);
  p += strlen (p) + 1;
  argv = calloc (argc + 1, sizeof *argv);
  extra = calloc (header.payload_len / 2 + 1, sizeof *extra);
  for (int i = 0; i < argc; i++, p += strlen (p) + 1)
    {
      if (p >= end)
        _exit (1);
      argv[i] = p;
    }
  for (; p < end; p += strlen (p) + 1)
    extra[n_extra++] = p;
  env = merge_env (extra, n_extra);

  if ((pid = fork ()) == 0)
    {
      close (client);
      spawn_child (cwd, argv, env, fds, n_fds);
    }
  for (int i = 0; i < n_fds; i++)
    close (fds[i]);
  if (pid < 0)
    goto reply;

  pidfd = syscall (SYS_pidfd_open, pid, 0);

  for (;;)
    {
      struct pollfd pfd[2] = { { client, POLLIN, 0 }, { pidfd, POLLIN, 0 } };

      if (poll (pfd, pidfd >= 0 ? 2 : 1, pidfd >= 0 ? -1 : 100) < 0 && errno != EINTR)
        break;

      if (pfd[0].revents & (POLLIN | POLLHUP | POLLERR))
        {
          int32_t signo;
          ssize_t r = recv (client, &signo, sizeof signo, MSG_DONTWAIT);

          if (r == sizeof signo && signo > 0 && signo < NSIG)
            kill (-pid, signo);
          else if (r == 0 || (r < 0 && errno != EAGAIN && errno != EINTR))
            {
              /* The client is gone: so is everything it ran. */
              kill (-pid, SIGKILL);
              waitpid (pid, NULL, 0);
              _exit (0);
            }
        }

      if (waitpid (pid, &wstatus, WNOHANG) == pid)
        {
          status.signaled = WIFSIGNALED (wstatus);
          status.value = WIFSIGNALED (wstatus) ? WTERMSIG (wstatus) : WEXITSTATUS (wstatus);
          break;
        }
    }

reply:
  send (client, &status, sizeof status, MSG_NOSIGNAL);
  _exit (0);
}

int
main (int argc, char **argv)
{
  struct sockaddr_un addr = { .sun_family = AF_UNIX };
  struct sigaction reap = { .sa_handler = SIG_IGN, .sa_flags = SA_NOCLDWAIT };
  char lock_path[sizeof addr.sun_path + 8];
  int lock, listener;

  if (argc != 2 || strlen (argv[1]) >= sizeof addr.sun_path)
    {
      fprintf (stderr, "usage: apex-toolbox-bridge SOCKET\n");
      return 2;
    }
  strcpy (addr.sun_path, argv[1]);

  snprintf (lock_path, sizeof lock_path, "%s.lock", argv[1]);
  if ((lock = open (lock_path, O_RDWR | O_CREAT | O_CLOEXEC, 0600)) < 0)
    return 1;
  if (flock (lock, LOCK_EX | LOCK_NB) < 0)
    return 0; /* another bridge serves this toolbox */

  unlink (argv[1]);
  if ((listener = socket (AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)) < 0 ||
      bind (listener, (struct sockaddr *)&addr, sizeof addr) < 0 ||
      chmod (argv[1], 0600) < 0 ||
      listen (listener, 64) < 0)
    return 1;

  /* Handlers are reaped by the kernel; each waits for its own process. */
  sigaction (SIGCHLD, &reap, NULL);
  signal (SIGPIPE, SIG_IGN);

  for (;;)
    {
      int client = accept4 (listener, NULL, NULL, SOCK_CLOEXEC);
      pid_t pid;

      if (client < 0)
        {
          if (errno == EINTR || errno == ECONNABORTED)
            continue;
          return 1;
        }

      if ((pid = fork ()) == 0)
        {
          struct sigaction dfl = { .sa_handler = SIG_DFL };

          sigaction (SIGCHLD, &dfl, NULL);
          close (listener);
          close (lock);
          handle (client);
        }
      close (client);
    }
}
