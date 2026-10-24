/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include "ptyxis-window.h"

#include "apex-session.h"

G_BEGIN_DECLS

#define APEX_TYPE_PANES (apex_panes_get_type ())

G_DECLARE_FINAL_TYPE (ApexPanes, apex_panes, APEX, PANES, GtkWidget)

ApexPanes *apex_panes_attach         (PtyxisWindow *window,
                                      AdwTabView   *tab_view);
void       apex_panes_split          (ApexPanes    *self,
                                      ApexSplit     split);
PtyxisTab *apex_panes_focused_second (ApexPanes    *self);
void       apex_pane_exited          (PtyxisTab    *tab);

G_END_DECLS
