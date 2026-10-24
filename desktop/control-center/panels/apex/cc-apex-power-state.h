/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

typedef enum {
    CC_APEX_GPU_OFF,
    CC_APEX_GPU_ON,
    CC_APEX_GPU_WAKING,
    CC_APEX_GPU_SLEEPING,
    CC_APEX_GPU_ALWAYS_ON,
} CcApexGpuState;

CcApexGpuState cc_apex_power_gpu_state (const char *runtime_status);
const char *cc_apex_power_gpu_status (CcApexGpuState state);
const char *cc_apex_power_gpu_subtitle (CcApexGpuState state);
char *cc_apex_power_gpu_name (const char *model_from_database);
gboolean cc_apex_power_refresh_pair (GVariant *current_state, int *low, int *high);
char *cc_apex_power_refresh_line (GVariant *current_state);

G_END_DECLS
