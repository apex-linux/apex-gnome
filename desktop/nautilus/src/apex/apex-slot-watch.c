/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-slot-watch.h"

#include "nautilus-view-info.h"

struct _ApexSlotWatch
{
    GObject parent_instance;

    GSignalGroup *slot_signals;
    GSignalGroup *view_signals;
    GSignalGroup *model_signals;
};

enum
{
    SIGNAL_VIEW_CHANGED,
    SIGNAL_CONTENT_CHANGED,
    N_SIGNALS
};

static guint signals[N_SIGNALS];

G_DEFINE_FINAL_TYPE (ApexSlotWatch, apex_slot_watch, G_TYPE_OBJECT)

NautilusWindowSlot *
apex_slot_watch_get_slot (ApexSlotWatch *self)
{
    g_autoptr (NautilusWindowSlot) slot = g_signal_group_dup_target (self->slot_signals);

    return slot;
}

NautilusFilesView *
apex_slot_watch_get_view (ApexSlotWatch *self)
{
    g_autoptr (NautilusFilesView) view = g_signal_group_dup_target (self->view_signals);

    return view;
}

NautilusViewModel *
apex_slot_watch_get_model (ApexSlotWatch *self)
{
    NautilusFilesView *view = apex_slot_watch_get_view (self);

    return view != NULL ? nautilus_files_view_get_private_model (view) : NULL;
}

GFile *
apex_slot_watch_get_location (ApexSlotWatch *self)
{
    NautilusWindowSlot *slot = apex_slot_watch_get_slot (self);

    return slot != NULL ? nautilus_window_slot_get_location (slot) : NULL;
}

gboolean
apex_slot_watch_is_searching (ApexSlotWatch *self)
{
    NautilusFilesView *view = apex_slot_watch_get_view (self);

    return view != NULL && nautilus_files_view_is_searching (view);
}

guint
apex_slot_watch_get_view_id (ApexSlotWatch *self)
{
    NautilusFilesView *view = apex_slot_watch_get_view (self);

    return view != NULL ? nautilus_files_view_get_view_id (view) : NAUTILUS_VIEW_INVALID_ID;
}

static void
emit_content_changed (ApexSlotWatch *self)
{
    g_signal_emit (self, signals[SIGNAL_CONTENT_CHANGED], 0);
}

static void
follow_view (ApexSlotWatch *self)
{
    NautilusWindowSlot *slot = apex_slot_watch_get_slot (self);
    NautilusFilesView *view = slot != NULL ? nautilus_window_slot_get_current_view (slot) : NULL;

    g_signal_group_set_target (self->view_signals, view);
    g_signal_group_set_target (self->model_signals,
                               view != NULL ? nautilus_files_view_get_private_model (view) : NULL);
    g_signal_emit (self, signals[SIGNAL_VIEW_CHANGED], 0);
    emit_content_changed (self);
}

static void
on_active_slot (GtkWindow     *window,
                GParamSpec    *pspec,
                ApexSlotWatch *self)
{
    g_autoptr (NautilusWindowSlot) slot = NULL;

    g_object_get (window, "active-slot", &slot, NULL);
    g_signal_group_set_target (self->slot_signals, slot);
    follow_view (self);
}

static void
apex_slot_watch_dispose (GObject *object)
{
    ApexSlotWatch *self = APEX_SLOT_WATCH (object);

    g_clear_object (&self->slot_signals);
    g_clear_object (&self->view_signals);
    g_clear_object (&self->model_signals);
    G_OBJECT_CLASS (apex_slot_watch_parent_class)->dispose (object);
}

static void
apex_slot_watch_class_init (ApexSlotWatchClass *klass)
{
    G_OBJECT_CLASS (klass)->dispose = apex_slot_watch_dispose;

    signals[SIGNAL_VIEW_CHANGED] = g_signal_new ("view-changed", G_TYPE_FROM_CLASS (klass),
                                                 G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
                                                 G_TYPE_NONE, 0);
    signals[SIGNAL_CONTENT_CHANGED] = g_signal_new ("content-changed", G_TYPE_FROM_CLASS (klass),
                                                    G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
                                                    G_TYPE_NONE, 0);
}

static void
apex_slot_watch_init (ApexSlotWatch *self)
{
    self->slot_signals = g_signal_group_new (NAUTILUS_TYPE_WINDOW_SLOT);
    g_signal_group_connect_swapped (self->slot_signals, "notify::icon-name", G_CALLBACK (follow_view), self);
    g_signal_group_connect_swapped (self->slot_signals, "notify::location", G_CALLBACK (follow_view), self);
    g_signal_group_connect_swapped (self->slot_signals, "notify::selection", G_CALLBACK (emit_content_changed), self);

    self->view_signals = g_signal_group_new (NAUTILUS_TYPE_FILES_VIEW);
    g_signal_group_connect_swapped (self->view_signals, "notify::searching", G_CALLBACK (emit_content_changed), self);
    g_signal_group_connect_swapped (self->view_signals, "notify::loading", G_CALLBACK (emit_content_changed), self);

    self->model_signals = g_signal_group_new (NAUTILUS_TYPE_VIEW_MODEL);
    g_signal_group_connect_swapped (self->model_signals, "items-changed", G_CALLBACK (emit_content_changed), self);
    g_signal_group_connect_swapped (self->model_signals, "selection-changed", G_CALLBACK (emit_content_changed), self);
}

ApexSlotWatch *
apex_slot_watch_new (GtkWindow *window)
{
    ApexSlotWatch *self = g_object_new (APEX_TYPE_SLOT_WATCH, NULL);

    g_signal_connect_object (window, "notify::active-slot", G_CALLBACK (on_active_slot), self, G_CONNECT_DEFAULT);
    on_active_slot (window, NULL, self);
    return self;
}
