/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

/* The protocol between apex-toolbox-exec, on the host, and apex-toolbox-bridge, the one
 * process per toolbox that spawns what Builder runs there (E2; the E1 report's §5).
 *
 * Request, client to bridge: one sendmsg() of a ApexBridgeHeader whose SCM_RIGHTS carry
 * n_fds descriptors, the process's 0 to n_fds - 1, then payload_len bytes of NUL-ended
 * strings: the working directory, argc, the argc arguments, then KEY=VALUE environment
 * entries until the end. After it, the client sends a signal number (int32) for each
 * signal it is asked to pass on.
 *
 * Reply, bridge to client: one ApexBridgeStatus when the process ends, then EOF. */

#include <stdint.h>

#define APEX_BRIDGE_MAGIC   0x41504258u /* "APBX" */
#define APEX_BRIDGE_MAX_FDS 64
#define APEX_BRIDGE_MAX_PAYLOAD (1024 * 1024)

typedef struct
{
  uint32_t magic;
  uint32_t n_fds;
  uint32_t payload_len;
} ApexBridgeHeader;

typedef struct
{
  int32_t signaled; /* 1 when the process was killed by a signal, 0 when it exited */
  int32_t value;    /* the signal number, or the exit status */
} ApexBridgeStatus;

/* The socket, at the same path from the host and, under /run/host, from the toolbox. */
#define APEX_BRIDGE_SOCKET_FORMAT "%s/apex-toolbox-%.12s.sock"
