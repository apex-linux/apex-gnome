// SPDX-License-Identifier: GPL-3.0-or-later
// Board 27's disk under $HOME on any runner: the footer reads "588 GB free of 1 TB".
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>

#define BLOCK 4096
#define TOTAL 244140625ULL
#define AVAIL 143554688ULL

static int at_home(const char *path)
{
    const char *home = getenv("HOME");
    size_t n = home ? strlen(home) : 0;
    return n > 1 && strncmp(path, home, n) == 0 && (path[n] == '\0' || path[n] == '/');
}

#define PIN(name, type)                                                                        \
    int name(const char *path, struct type *buf)                                               \
    {                                                                                          \
        static int (*real)(const char *, struct type *);                                       \
        if (!real)                                                                             \
            real = (int (*)(const char *, struct type *))dlsym(RTLD_NEXT, #name);              \
        int rc = real ? real(path, buf) : -1;                                                  \
        if (rc == 0 && at_home(path)) {                                                        \
            buf->f_bsize = buf->f_frsize = BLOCK;                                              \
            buf->f_blocks = TOTAL;                                                             \
            buf->f_bfree = buf->f_bavail = AVAIL;                                              \
        }                                                                                      \
        return rc;                                                                             \
    }

PIN(statfs, statfs)
PIN(statfs64, statfs64)
PIN(statvfs, statvfs)
PIN(statvfs64, statvfs64)
