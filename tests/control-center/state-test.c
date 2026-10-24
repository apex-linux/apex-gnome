/* SPDX-License-Identifier: GPL-3.0-or-later */

#include <string.h>

#include "cc-apex-power-state.h"
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
test_sizes_and_progress (void)
{
    CcApexUpdatesFacts f = { .state = "available", .target_version = "45.20261010.133", .download_size = 412000000,
                             .now = NOW };
    g_autofree char *mb = cc_apex_updates_size (412000000);
    g_autofree char *gb = cc_apex_updates_size (1200000000);
    g_autofree char *small = cc_apex_updates_size (49500000);
    g_autofree char *bytes = cc_apex_updates_size (512);
    g_autofree char *line = cc_apex_updates_progress_line (0.64, 412000000, 70);
    g_autofree char *soon = cc_apex_updates_progress_line (0.98, 412000000, 20);
    g_autofree char *no_rate = cc_apex_updates_progress_line (0.64, 412000000, -1);
    g_autofree char *no_size = cc_apex_updates_progress_line (0.64, 0, 70);
    g_autofree char *unknown = cc_apex_updates_progress_line (-1, 412000000, 70);

    g_assert_cmpstr (mb, ==, "412 MB");
    g_assert_cmpstr (gb, ==, "1.2 GB");
    g_assert_cmpstr (small, ==, "49.5 MB");
    g_assert_cmpstr (bytes, ==, "512 B");
    g_assert_cmpstr (line, ==, "264 of 412 MB · about 2 minutes left");
    g_assert_cmpstr (soon, ==, "404 of 412 MB · less than a minute left");
    g_assert_cmpstr (no_rate, ==, "264 of 412 MB");
    g_assert_cmpstr (no_size, ==, "64 % downloaded");
    g_assert_cmpstr (unknown, ==, "");
    assert_hero (&f, "Update Available",
                 "45.20261010.133 · 412 MB. It downloads in the background and nothing changes until you restart.",
                 CC_APEX_UPDATES_ACTION_DOWNLOAD, CC_APEX_UPDATES_ACTION_NONE);
}

static void
test_fallback (void)
{
    CcApexUpdatesFacts f = { .state = "up-to-date", .last_fallback = "sha256:9e41", .now = NOW };

    assert_hero (&f, "Apex Went Back to the Previous Version", NULL, CC_APEX_UPDATES_ACTION_ACKNOWLEDGE_FALLBACK,
                 CC_APEX_UPDATES_ACTION_NONE);
    f.state = "health-failure";
    assert_hero (&f, "Update Failed Its Startup Check", NULL, CC_APEX_UPDATES_ACTION_ROLLBACK_BAD,
                 CC_APEX_UPDATES_ACTION_ACKNOWLEDGE);
    g_assert_cmpstr (cc_apex_updates_action_label (CC_APEX_UPDATES_ACTION_ACKNOWLEDGE_FALLBACK), ==, "OK");
}

static void
test_hold_notes (void)
{
    g_autofree char *title = NULL;
    g_autofree char *body = NULL;
    g_autofree char *title2 = NULL;
    g_autofree char *body2 = NULL;
    g_autofree char *title3 = NULL;
    g_autofree char *body3 = NULL;
    g_autofree char *title4 = NULL;
    g_autofree char *body4 = NULL;

    cc_apex_updates_hold_note ("gnome-control-center", "",
                               "gnome-control-center-51.1-1.fc45,gnome-control-center-51.1-2.fc45",
                               NOW - 2 * 86400, FALSE, NOW + 12 * 86400, &title, &body);
    g_assert_cmpstr (title, ==, "Settings 51.1 is held back");
    g_assert_cmpstr (body, ==, "Apex’s Settings changes do not apply to 51.1 yet, so this update keeps the last good "
                               "build. Not a security update. Held for up to 14 days, then Apex ships the stock "
                               "51.1.");

    cc_apex_updates_hold_note ("kernel", "kernel", "kernel-cachyos-7.2.9-1.fc45", NOW, TRUE, NOW + 3 * 86400,
                               &title2, &body2);
    g_assert_cmpstr (title2, ==, "Linux 7.2.9 is held back");
    g_assert_true (strstr (body2, "It holds back a security update. Held for up to 3 days") != NULL);

    cc_apex_updates_hold_note ("libfoo", NULL, "", 0, FALSE, 0, &title3, &body3);
    g_assert_cmpstr (title3, ==, "libfoo is held back");
    cc_apex_updates_hold_note ("kernel", "kmod", "kmod-nvidia-580.95-1.fc45", NOW, FALSE, 0, &title4, &body4);
    g_assert_cmpstr (title4, ==, "The NVIDIA driver 580.95 is held back");
    g_assert_null (strstr (body4, "Held for"));
    g_assert_cmpstr (body3, ==, "Apex’s libfoo changes do not apply to Fedora’s newest build yet, so this update "
                                "keeps the last good build.");
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

/* GetCurrentState as Mutter answers it: a built-in panel at 2880x1800, and an external monitor. */
#define PANEL_MODES                                                                                                    \
    "[('2880x1800@90.000', 2880, 1800, 90.0, 2.0, [1.0, 2.0], {'is-current': <true>, 'is-preferred': <true>}),"     \
    " ('2880x1800@60.001', 2880, 1800, 60.001, 2.0, [2.0], @a{sv} {}),"                                                \
    " ('2880x1800@48.000', 2880, 1800, 48.0, 2.0, [2.0], @a{sv} {}),"                                                  \
    " ('1920x1200@120.000', 1920, 1200, 120.0, 1.0, [1.0], @a{sv} {})]"
#define EXTERNAL                                                                                                       \
    "(('HDMI-1', 'DEL', 'U2723QE', '0x1'), [('2560x1440@144.000', 2560, 1440, 144.0, 1.0, [1.0],"                     \
    " {'is-current': <true>})], {'is-builtin': <false>})"

static GVariant *
display_state (const char *monitors)
{
    g_autofree char *text = g_strdup_printf ("(uint32 1, %s, @a(iiduba(ssss)a{sv}) [], @a{sv} {})", monitors);

    return g_variant_ref_sink (g_variant_new_parsed (text));
}

static void
test_refresh_line (void)
{
    g_autoptr(GVariant) laptop =
        display_state ("[(('eDP-1', 'SDC', '0x4161', '0x0'), " PANEL_MODES ", {'is-builtin': <true>}), " EXTERNAL "]");
    g_autoptr(GVariant) desktop = display_state ("[" EXTERNAL "]");
    g_autoptr(GVariant) one_rate = display_state (
        "[(('eDP-1', 'SDC', '0x4161', '0x0'), [('2880x1800@90.000', 2880, 1800, 90.0, 2.0, [2.0],"
        " {'is-current': <true>})], {'is-builtin': <true>})]");
    g_autoptr(GVariant) wrong = g_variant_ref_sink (g_variant_new_parsed ("(uint32 1, 'eDP-1')"));
    g_autofree char *line = cc_apex_power_refresh_line (laptop);
    g_autofree char *none = cc_apex_power_refresh_line (desktop);
    g_autofree char *single = cc_apex_power_refresh_line (one_rate);
    g_autofree char *missing = cc_apex_power_refresh_line (NULL);
    int low = 0, high = 0;

    g_assert_true (cc_apex_power_refresh_pair (laptop, &low, &high));
    g_assert_cmpint (low, ==, 60);
    g_assert_cmpint (high, ==, 90);
    g_assert_cmpstr (line, ==, "60 Hz on battery, 90 Hz when plugged in");
    g_assert_false (cc_apex_power_refresh_pair (desktop, &low, &high));
    g_assert_cmpstr (none, ==, "The built-in display's lowest rate on battery, its highest when plugged in");
    g_assert_cmpstr (single, ==, "The built-in display runs at 90 Hz either way");
    g_assert_cmpstr (missing, ==, none);
    g_assert_false (cc_apex_power_refresh_pair (wrong, &low, &high));
}

static void
test_gpu (void)
{
    g_autofree char *named = cc_apex_power_gpu_name ("GA107M [GeForce RTX 3050 Mobile]");
    g_autofree char *plain = cc_apex_power_gpu_name ("GA107M");
    g_autofree char *unknown = cc_apex_power_gpu_name (NULL);

    g_assert_cmpstr (named, ==, "NVIDIA GeForce RTX 3050 Mobile");
    g_assert_cmpstr (plain, ==, "NVIDIA GA107M");
    g_assert_cmpstr (unknown, ==, "NVIDIA Graphics");
    g_assert_cmpint (cc_apex_power_gpu_state ("suspended"), ==, CC_APEX_GPU_OFF);
    g_assert_cmpint (cc_apex_power_gpu_state ("active"), ==, CC_APEX_GPU_ON);
    g_assert_cmpint (cc_apex_power_gpu_state ("resuming"), ==, CC_APEX_GPU_WAKING);
    g_assert_cmpint (cc_apex_power_gpu_state ("suspending"), ==, CC_APEX_GPU_SLEEPING);
    g_assert_cmpint (cc_apex_power_gpu_state ("unsupported"), ==, CC_APEX_GPU_ALWAYS_ON);
    g_assert_cmpint (cc_apex_power_gpu_state (NULL), ==, CC_APEX_GPU_ALWAYS_ON);
    g_assert_cmpstr (cc_apex_power_gpu_status (CC_APEX_GPU_OFF), ==, "Off");
    g_assert_cmpstr (cc_apex_power_gpu_subtitle (CC_APEX_GPU_OFF), ==, "Powered down until an app asks for it");
    g_assert_cmpstr (cc_apex_power_gpu_status (CC_APEX_GPU_ON), ==, "On");
    g_assert_cmpstr (cc_apex_power_gpu_status (CC_APEX_GPU_ALWAYS_ON), ==, "On");
    g_assert_cmpstr (cc_apex_power_gpu_subtitle (CC_APEX_GPU_ALWAYS_ON), ==, "Its driver keeps it powered");
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
    g_test_add_func ("/updates/sizes-and-progress", test_sizes_and_progress);
    g_test_add_func ("/updates/fallback", test_fallback);
    g_test_add_func ("/updates/hold-notes", test_hold_notes);
    g_test_add_func ("/updates/when-and-digest", test_when_and_digest);
    g_test_add_func ("/updates/changes", test_changes);
    g_test_add_func ("/updates/changes-without-known-packages", test_changes_without_known_packages);
    g_test_add_func ("/power/refresh-line", test_refresh_line);
    g_test_add_func ("/power/gpu", test_gpu);
    return g_test_run ();
}
