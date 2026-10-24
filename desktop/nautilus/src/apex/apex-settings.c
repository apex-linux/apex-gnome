/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-settings.h"

#define APEX_SCHEMA "io.github.apex_linux.Apex.Desktop"

static GSettings *
apex_settings (void)
{
    static GSettings *settings;
    static gboolean looked_up;
    GSettingsSchemaSource *source;
    g_autoptr (GSettingsSchema) schema = NULL;

    if (looked_up)
    {
        return settings;
    }

    looked_up = TRUE;
    source = g_settings_schema_source_get_default ();
    schema = source != NULL ? g_settings_schema_source_lookup (source, APEX_SCHEMA, TRUE) : NULL;
    if (schema != NULL &&
        g_settings_schema_has_key (schema, APEX_KEY_DETAILS_PANE) &&
        g_settings_schema_has_key (schema, APEX_KEY_RECENT_STRIP))
    {
        settings = g_settings_new (APEX_SCHEMA);
    }

    return settings;
}

static void
on_change_state (GSimpleAction *action,
                 GVariant      *state,
                 gpointer       user_data)
{
    const char *key = user_data;
    GSettings *settings = apex_settings ();

    g_simple_action_set_state (action, state);
    if (settings != NULL)
    {
        g_settings_set_boolean (settings, key, g_variant_get_boolean (state));
    }
}

static void
on_key_changed (GSettings     *settings,
                const char    *key,
                GSimpleAction *action)
{
    g_simple_action_set_state (action, g_variant_new_boolean (g_settings_get_boolean (settings, key)));
}

GSimpleAction *
apex_settings_toggle_action (const char *action_name,
                             const char *key,
                             gboolean    fallback)
{
    GSettings *settings = apex_settings ();
    gboolean value = settings != NULL ? g_settings_get_boolean (settings, key) : fallback;
    GSimpleAction *action = g_simple_action_new_stateful (action_name, NULL, g_variant_new_boolean (value));
    g_autofree char *signal = g_strconcat ("changed::", key, NULL);

    g_signal_connect (action, "change-state", G_CALLBACK (on_change_state), (gpointer) key);
    if (settings != NULL)
    {
        g_signal_connect_object (settings, signal, G_CALLBACK (on_key_changed), action, G_CONNECT_DEFAULT);
    }

    return action;
}
