/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

#define APEX_TYPE_COUNT_BAR (apex_count_bar_get_type ())

G_DECLARE_FINAL_TYPE (ApexCountBar, apex_count_bar, APEX, COUNT_BAR, GtkWidget)

GtkWidget *apex_count_bar_new (GtkWindow *window);

G_END_DECLS
