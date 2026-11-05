/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <libide-gui.h>

G_BEGIN_DECLS

#define GBP_TYPE_APEX_WORKBENCH_ADDIN (gbp_apex_workbench_addin_get_type())

G_DECLARE_FINAL_TYPE (GbpApexWorkbenchAddin, gbp_apex_workbench_addin, GBP, APEX_WORKBENCH_ADDIN, GObject)

G_END_DECLS
