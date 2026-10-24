/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include "ptyxis-window.h"

G_BEGIN_DECLS

void       apex_window_attach         (PtyxisWindow *window);
gboolean   apex_window_shows_sessions (PtyxisWindow *window);
PtyxisTab *apex_window_focused_pane   (PtyxisWindow *window);

G_END_DECLS
