/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <libide-gui.h>

G_BEGIN_DECLS

#define GBP_TYPE_APEX_VCS_PANE (gbp_apex_vcs_pane_get_type())

G_DECLARE_FINAL_TYPE (GbpApexVcsPane, gbp_apex_vcs_pane, GBP, APEX_VCS_PANE, IdePane)

GbpApexVcsPane *gbp_apex_vcs_pane_new           (void);
/* The changed files the view lists: the switcher's badge. */
guint           gbp_apex_vcs_pane_get_n_changes (GbpApexVcsPane *self);

G_END_DECLS
