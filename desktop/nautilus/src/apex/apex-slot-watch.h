/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <gtk/gtk.h>

#include "nautilus-files-view.h"
#include "nautilus-view-model.h"
#include "nautilus-window-slot.h"

G_BEGIN_DECLS

#define APEX_TYPE_SLOT_WATCH (apex_slot_watch_get_type ())

G_DECLARE_FINAL_TYPE (ApexSlotWatch, apex_slot_watch, APEX, SLOT_WATCH, GObject)

ApexSlotWatch *apex_slot_watch_new (GtkWindow *window);
NautilusWindowSlot *apex_slot_watch_get_slot (ApexSlotWatch *self);
NautilusFilesView *apex_slot_watch_get_view (ApexSlotWatch *self);
NautilusViewModel *apex_slot_watch_get_model (ApexSlotWatch *self);
GFile *apex_slot_watch_get_location (ApexSlotWatch *self);
gboolean apex_slot_watch_is_searching (ApexSlotWatch *self);
guint apex_slot_watch_get_view_id (ApexSlotWatch *self);

G_END_DECLS
