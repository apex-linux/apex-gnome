/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

typedef enum {
    CC_APEX_UPDATES_ACTION_NONE,
    CC_APEX_UPDATES_ACTION_CHECK,
    CC_APEX_UPDATES_ACTION_DOWNLOAD,
    CC_APEX_UPDATES_ACTION_DOWNLOAD_ANYWAY,
    CC_APEX_UPDATES_ACTION_APPLY_AND_RESTART,
    CC_APEX_UPDATES_ACTION_RESTART,
    CC_APEX_UPDATES_ACTION_ROLLBACK_BAD,
    CC_APEX_UPDATES_ACTION_ACKNOWLEDGE,
    CC_APEX_UPDATES_ACTION_KEEP_CURRENT,
    CC_APEX_UPDATES_ACTION_ACKNOWLEDGE_FALLBACK,
} CcApexUpdatesAction;

typedef enum {
    CC_APEX_UPDATES_TONE_GOOD,
    CC_APEX_UPDATES_TONE_ACCENT,
    CC_APEX_UPDATES_TONE_WARNING,
    CC_APEX_UPDATES_TONE_ERROR,
} CcApexUpdatesTone;

typedef struct {
    const char *state;
    const char *booted_version;
    const char *target_version;
    const char *rollback_version;
    const char *channel;
    const char *deferred_reason;
    const char *last_error;
    const char *last_fallback;
    guint64 download_size;
    gint64 last_check;
    gint64 now;
    gboolean kept_current;
} CcApexUpdatesFacts;

typedef struct {
    char *title;
    char *subtitle;
    CcApexUpdatesTone tone;
    gboolean show_progress;
    CcApexUpdatesAction primary;
    CcApexUpdatesAction secondary;
} CcApexUpdatesHero;

typedef struct {
    char *kind;
    char *package;
    char *name;
    char *from;
    char *to;
    char *versions;
} CcApexUpdatesChange;

void cc_apex_updates_hero_init (CcApexUpdatesHero *hero, const CcApexUpdatesFacts *facts);
void cc_apex_updates_hero_clear (CcApexUpdatesHero *hero);
const char *cc_apex_updates_action_label (CcApexUpdatesAction action);

char *cc_apex_updates_when (gint64 unix_seconds, gint64 now);
char *cc_apex_updates_size (guint64 bytes);
char *cc_apex_updates_progress_line (double progress, guint64 total, gint64 seconds_left);
void cc_apex_updates_hold_note (const char *family, const char *newer, gint64 since, gboolean security, gint64 limit,
                                char **title, char **body);
char *cc_apex_updates_built (gint64 unix_seconds);
char *cc_apex_updates_short_digest (const char *digest);
char *cc_apex_updates_deployment_line (const char *version, const char *digest);

GPtrArray *cc_apex_updates_changes (GVariant *changes);
char *cc_apex_updates_changes_summary (GPtrArray *changes, guint *others);
void cc_apex_updates_change_free (CcApexUpdatesChange *change);

G_DEFINE_AUTOPTR_CLEANUP_FUNC (CcApexUpdatesChange, cc_apex_updates_change_free)
G_DEFINE_AUTO_CLEANUP_CLEAR_FUNC (CcApexUpdatesHero, cc_apex_updates_hero_clear)

G_END_DECLS
