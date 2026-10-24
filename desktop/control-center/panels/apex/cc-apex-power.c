/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <config.h>

#include <glib/gi18n.h>
#include <gudev/gudev.h>

#include "cc-apex-power-state.h"
#include "cc-apex-power.h"

#define APEX_SCHEMA "io.github.apex_linux.Apex.Desktop"
#define REFRESH_KEY "lower-refresh-rate-on-battery"
#define NVIDIA_VENDOR "0x10de"
#define POLL_SECONDS 2

/* Board 24's Graphics and Display group, after stock's Power Mode. */
typedef struct {
    GtkWidget *group;
    GtkWidget *gpu_row;
    GtkWidget *gpu_status;
    GUdevDevice *gpu;
    guint poll_id;
    GtkWidget *refresh_row;
    GSettings *settings;
    GDBusProxy *display_config;
    GCancellable *cancellable;
} Power;

static void
power_free (gpointer data)
{
    Power *self = data;

    g_clear_handle_id (&self->poll_id, g_source_remove);
    g_cancellable_cancel (self->cancellable);
    g_clear_object (&self->cancellable);
    if (self->display_config != NULL)
        g_signal_handlers_disconnect_by_data (self->display_config, self);
    g_clear_object (&self->display_config);
    g_clear_object (&self->settings);
    g_clear_object (&self->gpu);
    g_free (self);
}

/* The NVIDIA display controller (PCI class 0x03xxxx), if the machine has one. */
static GUdevDevice *
find_nvidia_gpu (void)
{
    g_autoptr(GUdevClient) client = g_udev_client_new (NULL);
    GList *devices = g_udev_client_query_by_subsystem (client, "pci");
    GUdevDevice *found = NULL;

    for (GList *l = devices; l != NULL; l = l->next) {
        GUdevDevice *device = l->data;
        const char *vendor = g_udev_device_get_sysfs_attr (device, "vendor");
        const char *class = g_udev_device_get_sysfs_attr (device, "class");

        if (found == NULL && g_strcmp0 (vendor, NVIDIA_VENDOR) == 0 && class != NULL &&
            g_str_has_prefix (class, "0x03"))
            found = g_object_ref (device);
    }
    g_list_free_full (devices, g_object_unref);
    return found;
}

static gboolean
update_gpu (gpointer data)
{
    Power *self = data;
    CcApexGpuState state =
        cc_apex_power_gpu_state (g_udev_device_get_sysfs_attr_uncached (self->gpu, "power/runtime_status"));

    adw_action_row_set_subtitle (ADW_ACTION_ROW (self->gpu_row), cc_apex_power_gpu_subtitle (state));
    gtk_label_set_text (GTK_LABEL (self->gpu_status), cc_apex_power_gpu_status (state));
    if (state == CC_APEX_GPU_ON || state == CC_APEX_GPU_ALWAYS_ON)
        gtk_widget_add_css_class (self->gpu_row, "apex-gpu-on");
    else
        gtk_widget_remove_css_class (self->gpu_row, "apex-gpu-on");
    return G_SOURCE_CONTINUE;
}

/* runtime_status changes send no uevent, so it is read while the row shows; reading it does not wake the card. */
static void
on_gpu_row_mapped (Power *self)
{
    update_gpu (self);
    if (self->poll_id == 0)
        self->poll_id = g_timeout_add_seconds (POLL_SECONDS, update_gpu, self);
}

static void
on_gpu_row_unmapped (Power *self)
{
    g_clear_handle_id (&self->poll_id, g_source_remove);
}

static void
add_gpu_row (Power *self)
{
    g_autofree char *name = NULL;
    GtkWidget *status, *dot;

    self->gpu = find_nvidia_gpu ();
    if (self->gpu == NULL)
        return;
    name = cc_apex_power_gpu_name (g_udev_device_get_property (self->gpu, "ID_MODEL_FROM_DATABASE"));
    self->gpu_row = adw_action_row_new ();
    adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->gpu_row), name);
    status = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_valign (status, GTK_ALIGN_CENTER);
    gtk_widget_add_css_class (status, "apex-gpu-status");
    dot = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_valign (dot, GTK_ALIGN_CENTER);
    gtk_widget_add_css_class (dot, "apex-gpu-dot");
    self->gpu_status = gtk_label_new (NULL);
    gtk_box_append (GTK_BOX (status), dot);
    gtk_box_append (GTK_BOX (status), self->gpu_status);
    adw_action_row_add_suffix (ADW_ACTION_ROW (self->gpu_row), status);
    adw_preferences_group_add (ADW_PREFERENCES_GROUP (self->group), self->gpu_row);
    update_gpu (self);
    g_signal_connect_swapped (self->gpu_row, "map", G_CALLBACK (on_gpu_row_mapped), self);
    g_signal_connect_swapped (self->gpu_row, "unmap", G_CALLBACK (on_gpu_row_unmapped), self);
}

static void
set_refresh_line (Power *self, GVariant *state)
{
    g_autofree char *line = cc_apex_power_refresh_line (state);

    adw_action_row_set_subtitle (ADW_ACTION_ROW (self->refresh_row), line);
}

static void
on_current_state (GObject *source, GAsyncResult *result, gpointer data)
{
    g_autoptr(GError) error = NULL;
    g_autoptr(GVariant) state = g_dbus_proxy_call_finish (G_DBUS_PROXY (source), result, &error);

    if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        set_refresh_line (data, state);
}

static void
read_display_state (Power *self)
{
    g_dbus_proxy_call (self->display_config, "GetCurrentState", NULL, G_DBUS_CALL_FLAGS_NONE, -1, self->cancellable,
                       on_current_state, self);
}

static void
on_display_signal (Power *self, const char *sender, const char *signal)
{
    if (g_strcmp0 (signal, "MonitorsChanged") == 0)
        read_display_state (self);
}

static void
on_display_config (GObject *source, GAsyncResult *result, gpointer data)
{
    g_autoptr(GError) error = NULL;
    GDBusProxy *proxy = g_dbus_proxy_new_for_bus_finish (result, &error);
    Power *self = data;

    if (proxy == NULL) {
        /* A cancelled call returns after power_free, so self is only read otherwise. */
        if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
            set_refresh_line (self, NULL);
        return;
    }
    self->display_config = proxy;
    g_signal_connect_swapped (proxy, "g-signal", G_CALLBACK (on_display_signal), self);
    read_display_state (self);
}

static void
add_refresh_row (Power *self)
{
    g_autoptr(GSettingsSchema) schema =
        g_settings_schema_source_lookup (g_settings_schema_source_get_default (), APEX_SCHEMA, TRUE);

    if (schema == NULL || !g_settings_schema_has_key (schema, REFRESH_KEY))
        return;
    self->settings = g_settings_new (APEX_SCHEMA);
    self->refresh_row = adw_switch_row_new ();
    adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->refresh_row), _("Lower Refresh Rate on Battery"));
    adw_preferences_row_set_use_underline (ADW_PREFERENCES_ROW (self->refresh_row), TRUE);
    g_settings_bind (self->settings, REFRESH_KEY, self->refresh_row, "active", G_SETTINGS_BIND_DEFAULT);
    adw_preferences_group_add (ADW_PREFERENCES_GROUP (self->group), self->refresh_row);
    g_dbus_proxy_new_for_bus (G_BUS_TYPE_SESSION, G_DBUS_PROXY_FLAGS_DO_NOT_LOAD_PROPERTIES, NULL,
                              "org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                              "org.gnome.Mutter.DisplayConfig", self->cancellable, on_display_config, self);
}

void
cc_apex_power_add (AdwPreferencesPage *page, GtkWidget *after)
{
    Power *self = g_new0 (Power, 1);
    AdwPreferencesGroup *group;
    int index = 0;

    self->cancellable = g_cancellable_new ();
    self->group = adw_preferences_group_new ();
    adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (self->group), _("Graphics and Display"));
    g_object_set_data_full (G_OBJECT (self->group), "apex-power", self, power_free);
    add_gpu_row (self);
    add_refresh_row (self);
    gtk_widget_set_visible (self->group, self->gpu_row != NULL || self->refresh_row != NULL);

    while ((group = adw_preferences_page_get_group (page, index)) != NULL && GTK_WIDGET (group) != after)
        index++;
    adw_preferences_page_insert (page, ADW_PREFERENCES_GROUP (self->group), group != NULL ? index + 1 : -1);
}
