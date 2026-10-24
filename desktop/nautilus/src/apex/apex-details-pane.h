/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <gtk/gtk.h>

#include "apex-slot-watch.h"

G_BEGIN_DECLS

#define APEX_TYPE_DETAILS_PANE (apex_details_pane_get_type ())

G_DECLARE_FINAL_TYPE (ApexDetailsPane, apex_details_pane, APEX, DETAILS_PANE, GtkWidget)

GtkWidget *apex_details_pane_new (ApexSlotWatch *watch);

G_END_DECLS
