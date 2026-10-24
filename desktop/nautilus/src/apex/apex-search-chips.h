/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <gtk/gtk.h>

#include "apex-slot-watch.h"

G_BEGIN_DECLS

#define APEX_TYPE_SEARCH_CHIPS (apex_search_chips_get_type ())

G_DECLARE_FINAL_TYPE (ApexSearchChips, apex_search_chips, APEX, SEARCH_CHIPS, GtkWidget)

GtkWidget *apex_search_chips_new (ApexSlotWatch *watch);

G_END_DECLS
