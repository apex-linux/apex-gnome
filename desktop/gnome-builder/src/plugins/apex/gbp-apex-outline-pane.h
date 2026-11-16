/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <libide-gui.h>

G_BEGIN_DECLS

#define GBP_TYPE_APEX_OUTLINE_PANE (gbp_apex_outline_pane_get_type())

G_DECLARE_FINAL_TYPE (GbpApexOutlinePane, gbp_apex_outline_pane, GBP, APEX_OUTLINE_PANE, IdePane)

GbpApexOutlinePane *gbp_apex_outline_pane_new        (void);
/* The outline follows the page's buffer; any page but an editor's empties it. */
void                gbp_apex_outline_pane_set_page   (GbpApexOutlinePane *self,
                                                      IdePage            *page);

G_END_DECLS
