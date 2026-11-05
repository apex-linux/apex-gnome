/* SPDX-License-Identifier: GPL-3.0-or-later */

#define G_LOG_DOMAIN "gbp-apex-workbench-addin"

#include "config.h"

#include <json-glib/json-glib.h>

#include <libide-foundry.h>
#include <libide-gui.h>
#include <libide-threading.h>

#include "apex-i18n.h"
#include "apex-toolbox.h"
#include "gbp-apex-workbench-addin.h"

/* ADR 0017: builds and language servers run in a toolbox on bootc, never on the host. */
#define APEX_TOOLBOX_NAME  "fedora-toolbox-45"
#define APEX_TOOLBOX_IMAGE "registry.fedoraproject.org/fedora-toolbox:45"
#define APEX_TOOLBOX_SETUP \
  "sudo dnf -y install rust-analyzer cargo rust python3-lsp-server python3-pyflakes nodejs-npm && " \
  "sudo npm install -g --no-fund --no-audit typescript-language-server typescript"

struct _GbpApexWorkbenchAddin
{
  GObject          parent_instance;
  IdeWorkbench    *workbench;
  IdeNotification *notif;
  GSimpleActionGroup *actions;
  JsonObject      *toolbox;
  gulong           runtimes_changed_id;
  guint            creating : 1;
};

static void workbench_addin_iface_init (IdeWorkbenchAddinInterface *iface);

G_DEFINE_FINAL_TYPE_WITH_CODE (GbpApexWorkbenchAddin, gbp_apex_workbench_addin, G_TYPE_OBJECT,
                               G_IMPLEMENT_INTERFACE (IDE_TYPE_WORKBENCH_ADDIN, workbench_addin_iface_init))

static void
gbp_apex_workbench_addin_notify (GbpApexWorkbenchAddin *self,
                                 const char            *title,
                                 const char            *body,
                                 gboolean               offer_create)
{
  IdeContext *context;

  if (self->workbench == NULL)
    return;

  context = ide_workbench_get_context (self->workbench);

  if (self->notif != NULL)
    ide_notification_withdraw (self->notif);
  g_clear_object (&self->notif);

  self->notif = ide_notification_new ();
  ide_notification_set_id (self->notif, "org.apex.code.toolbox");
  ide_notification_set_icon_name (self->notif, "ui-container-toolbx-symbolic");
  ide_notification_set_title (self->notif, title);
  ide_notification_set_body (self->notif, body);
  if (offer_create)
    ide_notification_add_button (self->notif, APEX_("Create Toolbox"), NULL, "context.workbench.apex.create-toolbox");
  ide_notification_attach (self->notif, IDE_OBJECT (context));
}

static void gbp_apex_workbench_addin_apply (GbpApexWorkbenchAddin *self);

static void
gbp_apex_workbench_addin_runtimes_changed_cb (GbpApexWorkbenchAddin *self)
{
  if (self->workbench != NULL && self->toolbox != NULL)
    gbp_apex_workbench_addin_apply (self);
}

/* The fallback "Default" config, never saved, moves to the toolbox; a config the user saved keeps its runtime.
 * Only once the runtime is known: preparing the config sets its prefix, which would mark it dirty after us. */
static void
gbp_apex_workbench_addin_apply (GbpApexWorkbenchAddin *self)
{
  g_autofree char *runtime_id = NULL;
  g_autofree char *workdir_path = NULL;
  g_autoptr(GFile) workdir = NULL;
  IdeConfigManager *config_manager;
  g_autoptr(JsonObject) container = NULL;
  IdeRuntimeManager *runtime_manager;
  IdeContext *context;
  IdeConfig *config;

  context = ide_workbench_get_context (self->workbench);
  config_manager = ide_config_manager_from_context (context);
  runtime_manager = ide_runtime_manager_from_context (context);
  runtime_id = g_strdup_printf ("podman:%s", json_object_get_string_member (self->toolbox, "Id"));

  if (ide_runtime_manager_get_runtime (runtime_manager, runtime_id) == NULL)
    {
      if (self->runtimes_changed_id == 0)
        self->runtimes_changed_id = g_signal_connect_object (runtime_manager, "items-changed",
                                                             G_CALLBACK (gbp_apex_workbench_addin_runtimes_changed_cb),
                                                             self, G_CONNECT_SWAPPED);
      return;
    }

  g_clear_signal_handler (&self->runtimes_changed_id, runtime_manager);
  container = g_steal_pointer (&self->toolbox);

  if ((config = ide_config_manager_get_current (config_manager)) &&
      g_strcmp0 (ide_config_get_id (config), "default") == 0 &&
      g_strcmp0 (ide_config_get_runtime_id (config), "host") == 0 &&
      !ide_config_get_dirty (config))
    {
      g_debug ("Default config moves to %s", runtime_id);
      ide_config_set_runtime_id (config, runtime_id);
      ide_config_set_dirty (config, FALSE);
    }

  workdir = ide_context_ref_workdir (context);
  workdir_path = g_file_get_path (workdir);

  if (workdir_path != NULL && !apex_podman_container_shares_path (container, workdir_path))
    {
      g_autofree char *body = NULL;

      g_debug ("%s is not shared with the toolbox", workdir_path);
      /* TRANSLATORS: %s is the project's folder */
      body = g_strdup_printf (APEX_("%s is outside the folders the toolbox shares, so its language servers cannot start. Move the project into your home folder."),
                              workdir_path);
      gbp_apex_workbench_addin_notify (self, APEX_("Project Outside the Toolbox"), body, FALSE);
    }
}

static JsonObject *
find_toolbox (JsonArray *containers)
{
  JsonObject *by_image = NULL;

  for (guint i = 0; i < json_array_get_length (containers); i++)
    {
      JsonObject *c = json_array_get_object_element (containers, i);
      JsonArray *names;

      if (c == NULL || !json_object_has_member (c, "Id"))
        continue;

      if (json_object_has_member (c, "Names") &&
          (names = json_object_get_array_member (c, "Names")))
        {
          for (guint j = 0; j < json_array_get_length (names); j++)
            if (g_strcmp0 (json_array_get_string_element (names, j), APEX_TOOLBOX_NAME) == 0)
              return c;
        }

      if (by_image == NULL &&
          json_object_has_member (c, "Image") &&
          g_strcmp0 (json_object_get_string_member (c, "Image"), APEX_TOOLBOX_IMAGE) == 0)
        by_image = c;
    }

  return by_image;
}

static void
gbp_apex_workbench_addin_ps_cb (GObject      *object,
                                GAsyncResult *result,
                                gpointer      user_data)
{
  IdeSubprocess *subprocess = (IdeSubprocess *)object;
  g_autoptr(GbpApexWorkbenchAddin) self = user_data;
  g_autoptr(JsonParser) parser = json_parser_new ();
  g_autofree char *stdout_buf = NULL;
  g_autoptr(GError) error = NULL;
  JsonObject *toolbox = NULL;
  JsonNode *root;

  if (self->workbench == NULL)
    return;

  if (!ide_subprocess_communicate_utf8_finish (subprocess, result, &stdout_buf, NULL, &error))
    {
      g_debug ("podman ps failed: %s", error->message);
      return;
    }

  if (stdout_buf != NULL &&
      json_parser_load_from_data (parser, stdout_buf, -1, NULL) &&
      (root = json_parser_get_root (parser)) &&
      JSON_NODE_HOLDS_ARRAY (root))
    toolbox = find_toolbox (json_node_get_array (root));

  if (toolbox != NULL)
    {
      g_clear_pointer (&self->toolbox, json_object_unref);
      self->toolbox = json_object_ref (toolbox);
      gbp_apex_workbench_addin_apply (self);
    }
  else if (!self->creating)
    gbp_apex_workbench_addin_notify (self,
                                     APEX_("No Toolbox for Builds"),
                                     APEX_("Apex Code builds and runs language servers in the fedora-toolbox-45 toolbox. Until it exists, they run on the host."),
                                     TRUE);
}

static void
gbp_apex_workbench_addin_find (GbpApexWorkbenchAddin *self)
{
  g_autoptr(IdeSubprocessLauncher) launcher = NULL;
  g_autoptr(IdeSubprocess) subprocess = NULL;
  g_autoptr(GError) error = NULL;

  launcher = ide_subprocess_launcher_new (G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE);
  ide_subprocess_launcher_set_run_on_host (launcher, TRUE);
  ide_subprocess_launcher_push_args (launcher,
                                     IDE_STRV_INIT ("podman", "ps", "--all", "--no-trunc",
                                                    "--filter", "label=com.github.containers.toolbox",
                                                    "--format", "json"));

  if (!(subprocess = ide_subprocess_launcher_spawn (launcher, NULL, &error)))
    {
      g_debug ("No podman: %s", error->message);
      return;
    }

  ide_subprocess_communicate_utf8_async (subprocess, NULL, NULL, gbp_apex_workbench_addin_ps_cb, g_object_ref (self));
}

static void
gbp_apex_workbench_addin_create_cb (GObject      *object,
                                    GAsyncResult *result,
                                    gpointer      user_data)
{
  IdeSubprocess *subprocess = (IdeSubprocess *)object;
  g_autoptr(GbpApexWorkbenchAddin) self = user_data;
  g_autoptr(GError) error = NULL;

  self->creating = FALSE;

  if (self->workbench == NULL)
    return;

  if (!ide_subprocess_wait_check_finish (subprocess, result, &error))
    gbp_apex_workbench_addin_notify (self, APEX_("Could Not Create the Toolbox"), error->message, TRUE);
  else
    gbp_apex_workbench_addin_notify (self,
                                     APEX_("Toolbox Ready"),
                                     APEX_("fedora-toolbox-45 has its language servers. Reopen the project to build and run them in the toolbox."),
                                     FALSE);
}

static void
create_toolbox_action (GSimpleAction *action,
                       GVariant      *param,
                       gpointer       user_data)
{
  GbpApexWorkbenchAddin *self = user_data;
  g_autoptr(IdeSubprocessLauncher) launcher = NULL;
  g_autoptr(IdeSubprocess) subprocess = NULL;
  g_autoptr(GError) error = NULL;

  if (self->creating || self->workbench == NULL)
    return;

  launcher = ide_subprocess_launcher_new (G_SUBPROCESS_FLAGS_STDOUT_SILENCE | G_SUBPROCESS_FLAGS_STDERR_SILENCE);
  ide_subprocess_launcher_set_run_on_host (launcher, TRUE);
  ide_subprocess_launcher_push_args (launcher,
                                     IDE_STRV_INIT ("sh", "-c",
                                                    "toolbox create --assumeyes --image " APEX_TOOLBOX_IMAGE " " APEX_TOOLBOX_NAME
                                                    " && toolbox run --container " APEX_TOOLBOX_NAME " sh -c '" APEX_TOOLBOX_SETUP "'"));

  if (!(subprocess = ide_subprocess_launcher_spawn (launcher, NULL, &error)))
    {
      gbp_apex_workbench_addin_notify (self, APEX_("Could Not Create the Toolbox"), error->message, TRUE);
      return;
    }

  self->creating = TRUE;
  gbp_apex_workbench_addin_notify (self,
                                   APEX_("Creating the Toolbox"),
                                   APEX_("Downloading fedora-toolbox-45 and installing its language servers."),
                                   FALSE);
  ide_notification_set_has_progress (self->notif, TRUE);
  ide_notification_set_progress_is_imprecise (self->notif, TRUE);
  ide_subprocess_wait_check_async (subprocess, NULL, gbp_apex_workbench_addin_create_cb, g_object_ref (self));
}

static void
gbp_apex_workbench_addin_load (IdeWorkbenchAddin *addin,
                               IdeWorkbench      *workbench)
{
  GBP_APEX_WORKBENCH_ADDIN (addin)->workbench = workbench;
}

static void
gbp_apex_workbench_addin_unload (IdeWorkbenchAddin *addin,
                                 IdeWorkbench      *workbench)
{
  GbpApexWorkbenchAddin *self = GBP_APEX_WORKBENCH_ADDIN (addin);

  if (self->notif != NULL)
    ide_notification_withdraw (self->notif);
  g_clear_object (&self->notif);
  self->workbench = NULL;
}

static void
gbp_apex_workbench_addin_project_loaded (IdeWorkbenchAddin *addin,
                                         IdeProjectInfo    *project_info)
{
  gbp_apex_workbench_addin_find (GBP_APEX_WORKBENCH_ADDIN (addin));
}

static GActionGroup *
gbp_apex_workbench_addin_ref_action_group (IdeWorkbenchAddin *addin)
{
  return g_object_ref (G_ACTION_GROUP (GBP_APEX_WORKBENCH_ADDIN (addin)->actions));
}

static void
workbench_addin_iface_init (IdeWorkbenchAddinInterface *iface)
{
  iface->load = gbp_apex_workbench_addin_load;
  iface->unload = gbp_apex_workbench_addin_unload;
  iface->project_loaded = gbp_apex_workbench_addin_project_loaded;
  iface->ref_action_group = gbp_apex_workbench_addin_ref_action_group;
}

static void
gbp_apex_workbench_addin_dispose (GObject *object)
{
  GbpApexWorkbenchAddin *self = (GbpApexWorkbenchAddin *)object;

  g_clear_object (&self->notif);
  g_clear_object (&self->actions);
  g_clear_pointer (&self->toolbox, json_object_unref);

  G_OBJECT_CLASS (gbp_apex_workbench_addin_parent_class)->dispose (object);
}

static void
gbp_apex_workbench_addin_class_init (GbpApexWorkbenchAddinClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = gbp_apex_workbench_addin_dispose;
}

static void
gbp_apex_workbench_addin_init (GbpApexWorkbenchAddin *self)
{
  static const GActionEntry entries[] = {
    { "create-toolbox", create_toolbox_action },
  };

  self->actions = g_simple_action_group_new ();
  g_action_map_add_action_entries (G_ACTION_MAP (self->actions), entries, G_N_ELEMENTS (entries), self);
}
