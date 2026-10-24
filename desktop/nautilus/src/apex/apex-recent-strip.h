/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <gtk/gtk.h>

#include "apex-slot-watch.h"

G_BEGIN_DECLS

#define APEX_TYPE_RECENT_STRIP (apex_recent_strip_get_type ())

G_DECLARE_FINAL_TYPE (ApexRecentStrip, apex_recent_strip, APEX, RECENT_STRIP, GtkWidget)

GtkWidget *apex_recent_strip_new (ApexSlotWatch *watch,
                                  GAction       *enabled);

G_END_DECLS
