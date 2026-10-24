/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <config.h>

#include <glib/gi18n.h>
#include <math.h>
#include <string.h>

#include "cc-apex-power-state.h"

/* The values the kernel writes to a PCI device's power/runtime_status. */
CcApexGpuState
cc_apex_power_gpu_state (const char *runtime_status)
{
    if (g_strcmp0 (runtime_status, "suspended") == 0)
        return CC_APEX_GPU_OFF;
    if (g_strcmp0 (runtime_status, "active") == 0)
        return CC_APEX_GPU_ON;
    if (g_strcmp0 (runtime_status, "resuming") == 0)
        return CC_APEX_GPU_WAKING;
    if (g_strcmp0 (runtime_status, "suspending") == 0)
        return CC_APEX_GPU_SLEEPING;
    return CC_APEX_GPU_ALWAYS_ON;
}

const char *
cc_apex_power_gpu_status (CcApexGpuState state)
{
    switch (state) {
    case CC_APEX_GPU_OFF:
        return C_("graphics card", "Off");
    case CC_APEX_GPU_WAKING:
        return C_("graphics card", "Waking");
    case CC_APEX_GPU_SLEEPING:
        return C_("graphics card", "Powering Down");
    case CC_APEX_GPU_ON:
    case CC_APEX_GPU_ALWAYS_ON:
    default:
        return C_("graphics card", "On");
    }
}

const char *
cc_apex_power_gpu_subtitle (CcApexGpuState state)
{
    switch (state) {
    case CC_APEX_GPU_OFF:
    case CC_APEX_GPU_SLEEPING:
        return _("Powered down until an app asks for it");
    case CC_APEX_GPU_ON:
    case CC_APEX_GPU_WAKING:
        return _("Powered up for an app");
    case CC_APEX_GPU_ALWAYS_ON:
    default:
        return _("Its driver keeps it powered");
    }
}

/* hwdb names a chip and its product as "GA107M [GeForce RTX 3050 Mobile]"; the product is what people know. */
char *
cc_apex_power_gpu_name (const char *model_from_database)
{
    const char *open = model_from_database ? strchr (model_from_database, '[') : NULL;
    const char *close = open ? strchr (open, ']') : NULL;

    if (open != NULL && close != NULL && close > open + 1)
        return g_strdup_printf ("NVIDIA %.*s", (int) (close - open - 1), open + 1);
    if (model_from_database != NULL && *model_from_database != '\0')
        return g_strdup_printf ("NVIDIA %s", model_from_database);
    return g_strdup (_("NVIDIA Graphics"));
}

static gboolean
mode_flag (GVariant *mode, const char *flag)
{
    g_autoptr(GVariant) properties = g_variant_get_child_value (mode, 6);
    gboolean value = FALSE;

    return g_variant_lookup (properties, flag, "b", &value) && value;
}

/* As apex-session-agent picks them: the built-in panel's rates of 60 Hz or more at its current resolution. */
gboolean
cc_apex_power_refresh_pair (GVariant *current_state, int *low, int *high)
{
    g_autoptr(GVariant) monitors = NULL;
    GVariantIter iter;
    GVariant *monitor;

    if (current_state == NULL || !g_variant_is_of_type (current_state, G_VARIANT_TYPE ("(ua((ssss)a(siiddada{sv})a{sv})"
                                                                                       "a(iiduba(ssss)a{sv})a{sv})")))
        return FALSE;
    monitors = g_variant_get_child_value (current_state, 1);
    g_variant_iter_init (&iter, monitors);
    while ((monitor = g_variant_iter_next_value (&iter))) {
        g_autoptr(GVariant) owned = monitor;
        g_autoptr(GVariant) modes = g_variant_get_child_value (monitor, 1);
        g_autoptr(GVariant) properties = g_variant_get_child_value (monitor, 2);
        gboolean builtin = FALSE;
        int width = 0, height = 0;

        if (!g_variant_lookup (properties, "is-builtin", "b", &builtin) || !builtin)
            continue;
        for (gsize i = 0; i < g_variant_n_children (modes) && width == 0; i++) {
            g_autoptr(GVariant) mode = g_variant_get_child_value (modes, i);

            if (mode_flag (mode, "is-current"))
                g_variant_get (mode, "(&siiddad@a{sv})", NULL, &width, &height, NULL, NULL, NULL, NULL);
        }
        *low = G_MAXINT;
        *high = 0;
        for (gsize i = 0; i < g_variant_n_children (modes); i++) {
            g_autoptr(GVariant) mode = g_variant_get_child_value (modes, i);
            int w, h, hz;
            double rate;

            g_variant_get (mode, "(&siiddad@a{sv})", NULL, &w, &h, &rate, NULL, NULL, NULL);
            hz = (int) lround (rate);
            if (w != width || h != height || hz < 60)
                continue;
            *low = MIN (*low, hz);
            *high = MAX (*high, hz);
        }
        return *high > 0;
    }
    return FALSE;
}

char *
cc_apex_power_refresh_line (GVariant *current_state)
{
    int low = 0, high = 0;

    if (!cc_apex_power_refresh_pair (current_state, &low, &high))
        return g_strdup (_("The built-in display's lowest rate on battery, its highest when plugged in"));
    if (low == high)
        return g_strdup_printf (_("The built-in display runs at %d Hz either way"), high);
    return g_strdup_printf (_("%d Hz on battery, %d Hz when plugged in"), low, high);
}
