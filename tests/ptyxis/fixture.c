/* SPDX-License-Identifier: GPL-3.0-or-later */

#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Installed under the name of the program it stands in for (claude, just, cargo, rpmbuild,
 * ssh), so Ptyxis's agent sees that executable as the foreground process. */
#define RUN_SECONDS 2

static char *
slurp (const char *dir, const char *name, const char *ext, size_t *len)
{
  char path[4096];
  FILE *f;
  char *buf;
  long size;

  snprintf (path, sizeof path, "%s/%s.%s", dir, name, ext);
  if (!(f = fopen (path, "rb")))
    return NULL;
  fseek (f, 0, SEEK_END);
  size = ftell (f);
  rewind (f);
  buf = calloc (1, size + 1);
  *len = fread (buf, 1, size, f);
  fclose (f);
  return buf;
}

int
main (int argc, char *argv[])
{
  const char *dir = getenv ("APEX_FIXTURES");
  const char *name = basename (argv[0]);
  size_t len = 0;
  char *text;

  if (dir == NULL)
    return 127;

  if ((text = slurp (dir, name, "out", &len)))
    {
      fwrite (text, 1, len, stdout);
      fflush (stdout);
    }

  if ((text = slurp (dir, name, "exit", &len)))
    {
      sleep (RUN_SECONDS);
      return atoi (text);
    }

  if ((text = slurp (dir, name, "bell", &len)))
    {
      sleep (atoi (text));
      fputs ("\a", stdout);
      fflush (stdout);
    }

  for (;;)
    pause ();
}
