/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "cc-apex-updates-state.h"

/* 2026-10-21 14:02 UTC, the captures' clock. */
#define NOW G_GINT64_CONSTANT (1792591320)
#define HOUR 3600

static void
assert_hero (const CcApexUpdatesFacts *facts, const char *title, const char *subtitle, CcApexUpdatesAction primary,
             CcApexUpdatesAction secondary)
{
    g_auto(CcApexUpdatesHero) hero = { 0 };

    cc_apex_updates_hero_init (&hero, facts);
    g_assert_cmpstr (hero.title, ==, title);
    if (subtitle)
        g_assert_cmpstr (hero.subtitle, ==, subtitle);
    g_assert_cmpint (hero.primary, ==, primary);
    g_assert_cmpint (hero.secondary, ==, secondary);
}

static void
test_up_to_date (void)
{
    CcApexUpdatesFacts f = { .state = "up-to-date", .booted_version = "45.20261008.131", .channel = "stable",
                             .last_check = NOW - 5 * HOUR, .now = NOW };

    assert_hero (&f, "Apex Is Up to Date",
                 "45.20261008.131 is the newest build on the stable channel. Checked today at 09:02.",
                 CC_APEX_UPDATES_ACTION_CHECK, CC_APEX_UPDATES_ACTION_NONE);
    f.last_check = 0;
    assert_hero (&f, "Apex Is Up to Date", "45.20261008.131 is the newest build on the stable channel.",
                 CC_APEX_UPDATES_ACTION_CHECK, CC_APEX_UPDATES_ACTION_NONE);
}

static void
test_available_and_waiting (void)
{
    CcApexUpdatesFacts f = { .state = "available", .target_version = "45.20261010.133", .now = NOW };

    assert_hero (&f, "Update Available", NULL, CC_APEX_UPDATES_ACTION_DOWNLOAD, CC_APEX_UPDATES_ACTION_NONE);
    f.deferred_reason = "It downloads when the laptop is plugged in.";
    assert_hero (&f, "Update Waiting", "45.20261010.133 It downloads when the laptop is plugged in.",
                 CC_APEX_UPDATES_ACTION_NONE, CC_APEX_UPDATES_ACTION_DOWNLOAD_ANYWAY);
}

static void
test_staged_and_ready (void)
{
    CcApexUpdatesFacts f = { .state = "staged", .target_version = "45.20261010.133", .now = NOW };

    assert_hero (&f, "Restart to Finish Updating", NULL, CC_APEX_UPDATES_ACTION_APPLY_AND_RESTART,
                 CC_APEX_UPDATES_ACTION_KEEP_CURRENT);
    f.kept_current = TRUE;
    assert_hero (&f, "Update Downloaded",
                 "45.20261010.133 waits until you restart into it. Your current version keeps running.",
                 CC_APEX_UPDATES_ACTION_NONE, CC_APEX_UPDATES_ACTION_APPLY_AND_RESTART);
    f.kept_current = FALSE;
    f.deferred_reason = "45.20261010.133 is older than the running version.";
    assert_hero (&f, "Update Not Offered", "45.20261010.133 is older than the running version.",
                 CC_APEX_UPDATES_ACTION_CHECK, CC_APEX_UPDATES_ACTION_NONE);
    f.state = "ready-for-reboot";
    f.deferred_reason = NULL;
    assert_hero (&f, "Restart to Finish Updating", "45.20261010.133 starts the next time you restart.",
                 CC_APEX_UPDATES_ACTION_RESTART, CC_APEX_UPDATES_ACTION_NONE);
}

static void
test_failures (void)
{
    CcApexUpdatesFacts f = { .state = "health-failure", .booted_version = "45.20261010.133", .now = NOW };
    g_auto(CcApexUpdatesHero) hero = { 0 };

    assert_hero (&f, "Update Failed Its Startup Check", NULL, CC_APEX_UPDATES_ACTION_ROLLBACK_BAD,
                 CC_APEX_UPDATES_ACTION_ACKNOWLEDGE);
    f.state = "error";
    f.last_error = "The registry could not be reached.";
    assert_hero (&f, "Updates Could Not Be Checked", "The registry could not be reached.",
                 CC_APEX_UPDATES_ACTION_CHECK, CC_APEX_UPDATES_ACTION_NONE);
    f.state = NULL;
    cc_apex_updates_hero_init (&hero, &f);
    g_assert_cmpstr (hero.title, ==, "Checking for Updates");
}

static void
test_every_state_has_a_hero (void)
{
    static const char *const states[] = { "up-to-date", "available", "downloading", "staged", "ready-for-reboot",
                                          "rollback-queued", "incompatible", "usr-overlay", "finalize-failed",
                                          "health-failure", "error", "unknown" };

    for (guint i = 0; i < G_N_ELEMENTS (states); i++) {
        CcApexUpdatesFacts f = { .state = states[i], .now = NOW };
        g_auto(CcApexUpdatesHero) hero = { 0 };

        cc_apex_updates_hero_init (&hero, &f);
        g_assert_nonnull (hero.title);
        g_assert_nonnull (hero.subtitle);
        g_assert_true (hero.primary == CC_APEX_UPDATES_ACTION_NONE ||
                       cc_apex_updates_action_label (hero.primary) != NULL);
    }
}

static void
test_when_and_digest (void)
{
    g_autofree char *today = cc_apex_updates_when (NOW - 5 * HOUR, NOW);
    g_autofree char *yesterday = cc_apex_updates_when (NOW - 24 * HOUR, NOW);
    g_autofree char *older = cc_apex_updates_when (NOW - 5 * 24 * HOUR, NOW);
    g_autofree char *digest = cc_apex_updates_short_digest ("sha256:3f9c0e7a5d1b28c4e6f0a9b7a71e");
    g_autofree char *line = cc_apex_updates_deployment_line ("45.20261008.131", "sha256:3f9c0e7a5d1b28c4e6f0a9b7a71e");
    g_autofree char *built = cc_apex_updates_built (NOW - 13 * 24 * HOUR);

    g_assert_cmpstr (today, ==, "today at 09:02");
    g_assert_cmpstr (yesterday, ==, "yesterday at 14:02");
    g_assert_cmpstr (older, ==, "Oct 16 at 14:02");
    g_assert_cmpstr (digest, ==, "sha256:3f9c…a71e");
    g_assert_cmpstr (line, ==, "45.20261008.131 · sha256:3f9c…a71e");
    g_assert_cmpstr (built, ==, "built Oct 8");
    g_assert_null (cc_apex_updates_short_digest (""));
}

static void
test_changes (void)
{
    g_autoptr(GVariant) changes = g_variant_ref_sink (g_variant_new_parsed (
        "[('glibc', 'i686', 'upgraded', '2.42-3.fc45', '2.42-4.fc45'),"
        " ('glibc', 'x86_64', 'upgraded', '2.42-3.fc45', '2.42-4.fc45'),"
        " ('gnome-shell', 'x86_64', 'upgraded', '51.0-1.fc45', '51.1-1.fc45'),"
        " ('kernel', 'x86_64', 'upgraded', '7.2.7-300.fc45', '7.2.9-300.fc45'),"
        " ('mesa-dri-drivers', 'x86_64', 'upgraded', '26.1.0-1.fc45', '26.1.2-1.fc45'),"
        " ('python3-libdnf5', 'x86_64', 'added', '', '5.4.6-1.fc45'),"
        " ('xorg-x11-fonts-misc', 'noarch', 'removed', '7.5-42.fc45', '')]"));
    g_autoptr(GPtrArray) parsed = cc_apex_updates_changes (changes);
    g_autofree char *summary = NULL;
    CcApexUpdatesChange *c;
    guint others = 0;

    g_assert_cmpuint (parsed->len, ==, 7);
    c = g_ptr_array_index (parsed, 0);
    g_assert_cmpstr (c->name, ==, "glibc.i686");
    g_assert_cmpstr (c->versions, ==, "2.42-3 → 2.42-4");
    c = g_ptr_array_index (parsed, 5);
    g_assert_cmpstr (c->versions, ==, "5.4.6-1");

    summary = cc_apex_updates_changes_summary (parsed, &others);
    g_assert_cmpstr (summary, ==, "GNOME 51.0 → 51.1, Linux 7.2.7 → 7.2.9, Mesa 26.1.0 → 26.1.2");
    g_assert_cmpuint (others, ==, 4);
}

static void
test_changes_without_known_packages (void)
{
    g_autoptr(GVariant) changes = g_variant_ref_sink (
        g_variant_new_parsed ("[('glibc', 'x86_64', 'upgraded', '2.42-3.fc45', '2.42-4.fc45')]"));
    g_autoptr(GPtrArray) parsed = cc_apex_updates_changes (changes);
    g_autoptr(GPtrArray) none = cc_apex_updates_changes (NULL);
    g_autofree char *summary = NULL;
    guint others = 9;

    summary = cc_apex_updates_changes_summary (parsed, &others);
    g_assert_cmpstr (summary, ==, "glibc 2.42-3 → 2.42-4");
    g_assert_cmpuint (others, ==, 0);
    g_assert_null (cc_apex_updates_changes_summary (none, NULL));
}

int
main (int argc, char **argv)
{
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/updates/up-to-date", test_up_to_date);
    g_test_add_func ("/updates/available-and-waiting", test_available_and_waiting);
    g_test_add_func ("/updates/staged-and-ready", test_staged_and_ready);
    g_test_add_func ("/updates/failures", test_failures);
    g_test_add_func ("/updates/every-state", test_every_state_has_a_hero);
    g_test_add_func ("/updates/when-and-digest", test_when_and_digest);
    g_test_add_func ("/updates/changes", test_changes);
    g_test_add_func ("/updates/changes-without-known-packages", test_changes_without_known_packages);
    return g_test_run ();
}
