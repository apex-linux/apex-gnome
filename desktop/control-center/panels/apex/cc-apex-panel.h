/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#include <shell/cc-panel.h>

G_BEGIN_DECLS

#define CC_TYPE_APEX_PANEL (cc_apex_panel_get_type ())
G_DECLARE_FINAL_TYPE (CcApexPanel, cc_apex_panel, CC, APEX_PANEL, CcPanel)

G_END_DECLS
