/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <gio/gio.h>

G_BEGIN_DECLS

#define APEX_KEY_DETAILS_PANE "files-details-pane"
#define APEX_KEY_RECENT_STRIP "files-recent-strip"

GSimpleAction *apex_settings_toggle_action (const char *action_name,
                                            const char *key,
                                            gboolean    fallback);

G_END_DECLS
