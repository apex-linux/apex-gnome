/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

#define APEX_TYPE_DISK_FOOTER (apex_disk_footer_get_type ())

G_DECLARE_FINAL_TYPE (ApexDiskFooter, apex_disk_footer, APEX, DISK_FOOTER, GtkBox)

GtkWidget *apex_disk_footer_new (void);
void apex_disk_footer_refresh (ApexDiskFooter *self);

G_END_DECLS
