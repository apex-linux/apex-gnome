/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <libide-gui.h>

G_BEGIN_DECLS

#define GBP_TYPE_APEX_SIDEBAR_HEADER (gbp_apex_sidebar_header_get_type())
#define GBP_TYPE_APEX_SIDEBAR        (gbp_apex_sidebar_get_type())

G_DECLARE_FINAL_TYPE (GbpApexSidebarHeader, gbp_apex_sidebar_header, GBP, APEX_SIDEBAR_HEADER, GtkWidget)
G_DECLARE_FINAL_TYPE (GbpApexSidebar, gbp_apex_sidebar, GBP, APEX_SIDEBAR, GObject)

/* NULL for a workspace other than the primary one or an editor-only one. */
GbpApexSidebar *gbp_apex_sidebar_new (IdeWorkspace *workspace);

/* The board's view of a sidebar page, or NULL for a page the boards do not show. */
const char *gbp_apex_sidebar_view_name (PanelWidget *page);

/* After the workspace's session is restored: a split it restored may hold panes to move. */
void            gbp_apex_sidebar_session_restored (GbpApexSidebar *self);

/* The lane's check of can_drop() on a document page, only with APEX_BUILDER_SELFTEST set. */
void            gbp_apex_sidebar_selftest_drop    (GbpApexSidebar *self,
                                                   IdePage        *page);

G_END_DECLS
