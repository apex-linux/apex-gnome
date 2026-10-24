/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <gtk/gtk.h>

#include "apex-slot-watch.h"

G_BEGIN_DECLS

#define APEX_TYPE_VIEW_CONTROLS (apex_view_controls_get_type ())

G_DECLARE_FINAL_TYPE (ApexViewControls, apex_view_controls, APEX, VIEW_CONTROLS, GtkWidget)

GtkWidget *apex_view_controls_new (ApexSlotWatch *watch,
                                   GtkPopover    *view_options);

G_END_DECLS
