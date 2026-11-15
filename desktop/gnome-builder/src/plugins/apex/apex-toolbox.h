/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <json-glib/json-glib.h>
#include <libide-foundry.h>

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

static inline gboolean
apex_podman_container_is_toolbox (JsonObject *container)
{
  JsonObject *labels;

  return container != NULL &&
         json_object_has_member (container, "Labels") &&
         JSON_NODE_HOLDS_OBJECT (json_object_get_member (container, "Labels")) &&
         (labels = json_object_get_object_member (container, "Labels")) != NULL &&
         (json_object_has_member (labels, "com.github.containers.toolbox") ||
          json_object_has_member (labels, "com.github.debarshiray.toolbox"));
}

/* E2: a toolbox's processes go through its one bridge (apex-toolbox-exec.c), not a podman
 * exec each; a TTY, another container, or APEX_TOOLBOX_BRIDGE=0 keeps podman exec. */
static inline gboolean
apex_podman_bridge_argv (IdeRunContext      *run_context,
                         JsonObject         *container,
                         const char         *id,
                         const char * const *argv,
                         const char * const *env,
                         const char         *cwd,
                         int                 max_dest_fd,
                         gboolean            has_tty)
{
  static const char exec_path[] = PACKAGE_LIBEXECDIR "/apex-toolbox-exec";

  if (has_tty || !apex_podman_container_is_toolbox (container) ||
      g_strcmp0 (g_getenv ("APEX_TOOLBOX_BRIDGE"), "0") == 0 ||
      !g_file_test (exec_path, G_FILE_TEST_IS_EXECUTABLE))
    return FALSE;

  ide_run_context_append_argv (run_context, exec_path);
  ide_run_context_append_args (run_context, IDE_STRV_INIT ("--container", id, "--user", g_get_user_name (), "--cwd", cwd));
  ide_run_context_append_argv (run_context, "--fds");
  ide_run_context_append_formatted (run_context, "%d", MAX (max_dest_fd + 1, 3));
  for (guint i = 0; env[i]; i++)
    ide_run_context_append_args (run_context, IDE_STRV_INIT ("--env", env[i]));
  if (g_environ_getenv ((char **)env, "PATH") == NULL)
    {
      ide_run_context_append_argv (run_context, "--env");
      ide_run_context_append_formatted (run_context, "PATH=%s", ide_get_user_default_path ());
    }
  ide_run_context_append_argv (run_context, "--");
  ide_run_context_append_args (run_context, argv);

  return TRUE;
}
