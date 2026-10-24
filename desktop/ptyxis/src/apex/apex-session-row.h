/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <gtk/gtk.h>

#include "apex-session.h"

G_BEGIN_DECLS

#define APEX_TYPE_SESSION_ROW (apex_session_row_get_type ())

G_DECLARE_FINAL_TYPE (ApexSessionRow, apex_session_row, APEX, SESSION_ROW, GtkListBoxRow)

GtkWidget   *apex_session_row_new         (ApexSession    *session);
ApexSession *apex_session_row_get_session (ApexSessionRow *self);

G_END_DECLS
