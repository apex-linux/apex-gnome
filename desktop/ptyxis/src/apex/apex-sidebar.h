/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <adwaita.h>

#include "apex-session.h"

G_BEGIN_DECLS

#define APEX_TYPE_SIDEBAR (apex_sidebar_get_type ())

G_DECLARE_FINAL_TYPE (ApexSidebar, apex_sidebar, APEX, SIDEBAR, AdwBin)

GtkWidget   *apex_sidebar_new                  (AdwTabView  *tab_view,
                                                GMenuModel  *primary_menu);
ApexSession *apex_sidebar_get_selected_session (ApexSidebar *self);

G_END_DECLS
