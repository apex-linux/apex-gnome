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

/* The outline follows the focused page (the workspace addin's page_changed). */
void        gbp_apex_sidebar_page_changed (GbpApexSidebar *self,
                                           IdePage        *page);

/* A "dark" class while AdwStyleManager is dark: Builder's style variant sets it, not prefers-color-scheme. */
void        gbp_apex_track_dark           (GtkWidget      *widget);

/* After the workspace's session is restored: a split it restored may hold panes to move. */
void            gbp_apex_sidebar_session_restored (GbpApexSidebar *self);

G_END_DECLS
