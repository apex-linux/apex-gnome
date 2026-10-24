/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <config.h>

#include <glib/gi18n.h>
#include <string.h>

#include "cc-apex-updates-state.h"

#define DIGEST_PREFIX "sha256:"

static const struct {
    const char *package;
    const char *label;
} known_packages[] = {
    { "gnome-shell", "GNOME" },
    { "kernel", "Linux" },
    { "kernel-cachyos", "Linux" },
    { "mesa-dri-drivers", "Mesa" },
    { "nvidia-driver", "NVIDIA" },
};

static gboolean
is_set (const char *s)
{
    return s != NULL && *s != '\0';
}

static const char *
or_unknown (const char *version)
{
    return is_set (version) ? version : _("The new version");
}

void
cc_apex_updates_hero_init (CcApexUpdatesHero *hero, const CcApexUpdatesFacts *f)
{
    g_autofree char *checked = NULL;
    const char *state = is_set (f->state) ? f->state : "unknown";

    memset (hero, 0, sizeof (*hero));
    hero->tone = CC_APEX_UPDATES_TONE_ACCENT;

    if (g_str_equal (state, "up-to-date")) {
        checked = f->last_check > 0 ? cc_apex_updates_when (f->last_check, f->now) : NULL;
        hero->title = g_strdup (_("Apex Is Up to Date"));
        if (checked)
            hero->subtitle = g_strdup_printf (_("%s is the newest build on the %s channel. Checked %s."),
                                              or_unknown (f->booted_version), f->channel ? f->channel : "stable",
                                              checked);
        else
            hero->subtitle = g_strdup_printf (_("%s is the newest build on the %s channel."),
                                              or_unknown (f->booted_version), f->channel ? f->channel : "stable");
        hero->tone = CC_APEX_UPDATES_TONE_GOOD;
        hero->primary = CC_APEX_UPDATES_ACTION_CHECK;
    } else if (g_str_equal (state, "available") && is_set (f->deferred_reason)) {
        hero->title = g_strdup (_("Update Waiting"));
        hero->subtitle = g_strdup_printf ("%s %s", or_unknown (f->target_version), f->deferred_reason);
        hero->tone = CC_APEX_UPDATES_TONE_WARNING;
        hero->secondary = CC_APEX_UPDATES_ACTION_DOWNLOAD_ANYWAY;
    } else if (g_str_equal (state, "available")) {
        hero->title = g_strdup (_("Update Available"));
        hero->subtitle = g_strdup_printf (_("%s downloads in the background, and nothing changes until you restart."),
                                          or_unknown (f->target_version));
        hero->primary = CC_APEX_UPDATES_ACTION_DOWNLOAD;
    } else if (g_str_equal (state, "downloading")) {
        hero->title = g_strdup (_("Downloading Update"));
        hero->subtitle = g_strdup_printf (_("%s. You can keep working; Apex checks the signature before keeping it."),
                                          or_unknown (f->target_version));
        hero->show_progress = TRUE;
    } else if (g_str_equal (state, "staged") && is_set (f->deferred_reason)) {
        hero->title = g_strdup (_("Update Not Offered"));
        hero->subtitle = g_strdup (f->deferred_reason);
        hero->tone = CC_APEX_UPDATES_TONE_WARNING;
        hero->primary = CC_APEX_UPDATES_ACTION_CHECK;
    } else if (g_str_equal (state, "staged") && f->kept_current) {
        hero->title = g_strdup (_("Update Downloaded"));
        hero->subtitle = g_strdup_printf (_("%s waits until you restart into it. Your current version keeps running."),
                                          or_unknown (f->target_version));
        hero->secondary = CC_APEX_UPDATES_ACTION_APPLY_AND_RESTART;
    } else if (g_str_equal (state, "staged")) {
        hero->title = g_strdup (_("Restart to Finish Updating"));
        hero->subtitle = g_strdup_printf (_("%s is downloaded and its signature checked. Your current version stays "
                                            "in place until you restart."),
                                          or_unknown (f->target_version));
        hero->primary = CC_APEX_UPDATES_ACTION_APPLY_AND_RESTART;
        hero->secondary = CC_APEX_UPDATES_ACTION_KEEP_CURRENT;
    } else if (g_str_equal (state, "ready-for-reboot")) {
        hero->title = g_strdup (_("Restart to Finish Updating"));
        hero->subtitle = g_strdup_printf (_("%s starts the next time you restart."), or_unknown (f->target_version));
        hero->primary = CC_APEX_UPDATES_ACTION_RESTART;
    } else if (g_str_equal (state, "rollback-queued")) {
        hero->title = g_strdup (_("The Previous Version Starts Next"));
        hero->subtitle = g_strdup_printf (_("%s starts the next time you restart."),
                                          is_set (f->rollback_version) ? f->rollback_version
                                                                       : _("The previous version"));
        hero->primary = CC_APEX_UPDATES_ACTION_RESTART;
    } else if (g_str_equal (state, "health-failure")) {
        hero->title = g_strdup (_("Update Failed Its Startup Check"));
        hero->subtitle = g_strdup_printf (_("%s is running, but a required check did not pass. Going back to the "
                                            "version you had before is the safe choice. Nothing restarts until you "
                                            "say so."),
                                          or_unknown (f->booted_version));
        hero->tone = CC_APEX_UPDATES_TONE_WARNING;
        hero->primary = CC_APEX_UPDATES_ACTION_ROLLBACK_BAD;
        hero->secondary = CC_APEX_UPDATES_ACTION_ACKNOWLEDGE;
    } else if (g_str_equal (state, "usr-overlay")) {
        hero->title = g_strdup (_("Updates Paused"));
        hero->subtitle = g_strdup (_("System files are writable for development. Updates resume after the next "
                                     "restart."));
        hero->tone = CC_APEX_UPDATES_TONE_WARNING;
    } else if (g_str_equal (state, "incompatible")) {
        hero->title = g_strdup (_("Updates Paused"));
        hero->subtitle = g_strdup (is_set (f->last_error) ? f->last_error
                                                          : _("This system is not set up to follow Apex updates."));
        hero->tone = CC_APEX_UPDATES_TONE_WARNING;
    } else if (g_str_equal (state, "finalize-failed")) {
        hero->title = g_strdup (_("The Update Did Not Finish"));
        hero->subtitle = g_strdup (is_set (f->last_error) ? f->last_error
                                                          : _("The update could not be applied at restart. Your "
                                                              "current version is still in place."));
        hero->tone = CC_APEX_UPDATES_TONE_ERROR;
        hero->primary = CC_APEX_UPDATES_ACTION_CHECK;
    } else if (g_str_equal (state, "error")) {
        hero->title = g_strdup (_("Updates Could Not Be Checked"));
        hero->subtitle = g_strdup (is_set (f->last_error) ? f->last_error : _("Apex could not reach its updates."));
        hero->tone = CC_APEX_UPDATES_TONE_ERROR;
        hero->primary = CC_APEX_UPDATES_ACTION_CHECK;
    } else {
        hero->title = g_strdup (_("Checking for Updates"));
        hero->subtitle = g_strdup (_("Apex is reading the state of this system."));
    }
}

void
cc_apex_updates_hero_clear (CcApexUpdatesHero *hero)
{
    g_clear_pointer (&hero->title, g_free);
    g_clear_pointer (&hero->subtitle, g_free);
}

const char *
cc_apex_updates_action_label (CcApexUpdatesAction action)
{
    switch (action) {
    case CC_APEX_UPDATES_ACTION_CHECK:
        return _("Check Now");
    case CC_APEX_UPDATES_ACTION_DOWNLOAD:
        return _("Download");
    case CC_APEX_UPDATES_ACTION_DOWNLOAD_ANYWAY:
        return _("Download Anyway");
    case CC_APEX_UPDATES_ACTION_APPLY_AND_RESTART:
    case CC_APEX_UPDATES_ACTION_RESTART:
        return _("Restart Now");
    case CC_APEX_UPDATES_ACTION_ROLLBACK_BAD:
        return _("Go Back…");
    case CC_APEX_UPDATES_ACTION_ACKNOWLEDGE:
        return _("Keep This Version");
    case CC_APEX_UPDATES_ACTION_KEEP_CURRENT:
        return _("Keep Current Version");
    case CC_APEX_UPDATES_ACTION_NONE:
    default:
        return NULL;
    }
}

char *
cc_apex_updates_when (gint64 unix_seconds, gint64 now)
{
    g_autoptr(GDateTime) when = g_date_time_new_from_unix_local (unix_seconds);
    g_autoptr(GDateTime) today = g_date_time_new_from_unix_local (now);
    g_autofree char *time = NULL;
    int days;

    if (when == NULL || today == NULL)
        return NULL;

    time = g_date_time_format (when, "%H:%M");
    days = g_date_time_get_day_of_year (today) - g_date_time_get_day_of_year (when);
    if (g_date_time_get_year (today) == g_date_time_get_year (when) && days == 0)
        return g_strdup_printf (_("today at %s"), time);
    if (g_date_time_get_year (today) == g_date_time_get_year (when) && days == 1)
        return g_strdup_printf (_("yesterday at %s"), time);
    return g_date_time_format (when, _("%b %-d at %H:%M"));
}

char *
cc_apex_updates_built (gint64 unix_seconds)
{
    g_autoptr(GDateTime) when = unix_seconds > 0 ? g_date_time_new_from_unix_local (unix_seconds) : NULL;
    g_autofree char *day = NULL;

    if (when == NULL)
        return NULL;
    day = g_date_time_format (when, _("%b %-d"));
    return g_strdup_printf (_("built %s"), day);
}

char *
cc_apex_updates_short_digest (const char *digest)
{
    const char *hex;
    gsize len;

    if (!is_set (digest))
        return NULL;
    hex = g_str_has_prefix (digest, DIGEST_PREFIX) ? digest + strlen (DIGEST_PREFIX) : digest;
    len = strlen (hex);
    if (len <= 8)
        return g_strdup (digest);
    return g_strdup_printf (DIGEST_PREFIX "%.4s…%s", hex, hex + len - 4);
}

char *
cc_apex_updates_deployment_line (const char *version, const char *digest)
{
    g_autofree char *short_digest = cc_apex_updates_short_digest (digest);

    if (is_set (version) && short_digest)
        return g_strdup_printf ("%s · %s", version, short_digest);
    if (is_set (version))
        return g_strdup (version);
    return g_steal_pointer (&short_digest);
}

/* An EVR's version part: "51.1-1.fc45" gives "51.1", "1:2.42-4.fc45" gives "2.42". */
static char *
upstream_version (const char *evr)
{
    const char *colon = strchr (evr, ':');
    const char *start = colon ? colon + 1 : evr;
    const char *dash = strrchr (start, '-');

    return dash ? g_strndup (start, dash - start) : g_strdup (start);
}

static char *
release_trimmed (const char *evr)
{
    const char *colon = strchr (evr, ':');
    const char *start = colon ? colon + 1 : evr;
    const char *dot = strstr (start, ".fc");

    return dot ? g_strndup (start, dot - start) : g_strdup (start);
}

GPtrArray *
cc_apex_updates_changes (GVariant *changes)
{
    GPtrArray *out = g_ptr_array_new_with_free_func ((GDestroyNotify) cc_apex_updates_change_free);
    const char *name, *arch, *kind, *from, *to;
    GVariantIter iter;

    if (changes == NULL)
        return out;

    g_variant_iter_init (&iter, changes);
    while (g_variant_iter_next (&iter, "(&s&s&s&s&s)", &name, &arch, &kind, &from, &to)) {
        CcApexUpdatesChange *change = g_new0 (CcApexUpdatesChange, 1);
        g_autofree char *from_short = release_trimmed (from);
        g_autofree char *to_short = release_trimmed (to);

        change->kind = g_strdup (kind);
        change->package = g_strdup (name);
        change->from = g_strdup (from);
        change->to = g_strdup (to);
        change->name = g_str_equal (arch, "x86_64") || g_str_equal (arch, "noarch") || !is_set (arch)
                           ? g_strdup (name)
                           : g_strdup_printf ("%s.%s", name, arch);
        if (is_set (from) && is_set (to))
            change->versions = g_strdup_printf ("%s → %s", from_short, to_short);
        else
            change->versions = g_strdup (is_set (to) ? to_short : from_short);
        g_ptr_array_add (out, change);
    }
    return out;
}

char *
cc_apex_updates_changes_summary (GPtrArray *changes, guint *others)
{
    g_autoptr(GPtrArray) parts = g_ptr_array_new_with_free_func (g_free);
    guint i, k;

    for (k = 0; k < G_N_ELEMENTS (known_packages) && parts->len < 3; k++) {
        for (i = 0; i < changes->len; i++) {
            CcApexUpdatesChange *c = g_ptr_array_index (changes, i);
            g_autofree char *from = NULL;
            g_autofree char *to = NULL;

            if (!g_str_equal (c->package, known_packages[k].package) || !is_set (c->from) || !is_set (c->to))
                continue;
            from = upstream_version (c->from);
            to = upstream_version (c->to);
            if (!g_str_equal (from, to))
                g_ptr_array_add (parts, g_strdup_printf ("%s %s → %s", known_packages[k].label, from, to));
            break;
        }
    }

    for (i = 0; i < changes->len && parts->len < 3; i++) {
        CcApexUpdatesChange *c = g_ptr_array_index (changes, i);
        gboolean known = FALSE;

        for (k = 0; k < G_N_ELEMENTS (known_packages); k++)
            known = known || g_str_equal (c->package, known_packages[k].package);
        if (!known && !strchr (c->name, '.'))
            g_ptr_array_add (parts, g_strdup_printf ("%s %s", c->name, c->versions));
    }

    if (others)
        *others = changes->len > parts->len ? changes->len - parts->len : 0;
    if (parts->len == 0)
        return NULL;
    g_ptr_array_add (parts, NULL);
    return g_strjoinv (", ", (char **) parts->pdata);
}

void
cc_apex_updates_change_free (CcApexUpdatesChange *change)
{
    g_free (change->kind);
    g_free (change->package);
    g_free (change->name);
    g_free (change->from);
    g_free (change->to);
    g_free (change->versions);
    g_free (change);
}
