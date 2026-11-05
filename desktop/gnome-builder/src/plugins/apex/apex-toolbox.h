/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <json-glib/json-glib.h>

/* Whether a container from `podman ps --format=json` mounts @path: podman exec --workdir
 * fails with exit 127 on a path it does not, and the language service respawned every 5 s. */
static inline gboolean
apex_podman_container_shares_path (JsonObject *container,
                                   const char *path)
{
  JsonArray *mounts;

  if (container == NULL || path == NULL || !json_object_has_member (container, "Mounts"))
    return TRUE;

  if (!(mounts = json_object_get_array_member (container, "Mounts")))
    return TRUE;

  for (guint i = 0; i < json_array_get_length (mounts); i++)
    {
      const char *mount = json_array_get_string_element (mounts, i);
      gsize len;

      if (mount == NULL || g_str_has_prefix (mount, "/dev"))
        continue;

      len = strlen (mount);
      while (len > 1 && mount[len - 1] == '/')
        len--;

      if (strncmp (path, mount, len) == 0 && (path[len] == '\0' || path[len] == '/' || len == 1))
        return TRUE;
    }

  return FALSE;
}
