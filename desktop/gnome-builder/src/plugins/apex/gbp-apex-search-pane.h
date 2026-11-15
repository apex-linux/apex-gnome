/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <libide-gui.h>

G_BEGIN_DECLS

#define GBP_TYPE_APEX_SEARCH_PANE (gbp_apex_search_pane_get_type())

G_DECLARE_FINAL_TYPE (GbpApexSearchPane, gbp_apex_search_pane, GBP, APEX_SEARCH_PANE, IdePane)

GbpApexSearchPane *gbp_apex_search_pane_new (void);

G_END_DECLS
