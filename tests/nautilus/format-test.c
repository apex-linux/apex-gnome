/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-format.h"

#define KB ((guint64) 1000)
#define MB (1000 * KB)
#define GB (1000 * MB)
#define TB (1000 * GB)

static void
assert_size (guint64     bytes,
             const char *expected)
{
    g_autofree char *text = apex_format_disk_size (bytes);

    g_assert_cmpstr (text, ==, expected);
}

static void
assert_count (guint       n_items,
              gboolean    searching,
              guint       n_selected,
              const char *selected_name,
              const char *expected)
{
    g_autofree char *text = apex_format_item_count (n_items, searching, n_selected, selected_name);

    g_assert_cmpstr (text, ==, expected);
}

static void
test_disk_size (void)
{
    assert_size (0, "0 B");
    assert_size (999, "999 B");
    assert_size (12 * KB, "12 kB");
    assert_size (2400 * MB, "2.4 GB");
    assert_size (588 * GB + 300 * MB, "588 GB");
    assert_size (999 * GB + 600 * MB, "1 TB");
    assert_size (TB, "1 TB");
    assert_size (1960 * GB, "2 TB");
    assert_size (9 * GB + 940 * MB, "9.9 GB");
}

static void
test_disk_free (void)
{
    g_autofree char *board = apex_format_disk_free (588 * GB + 120 * MB, TB);
    g_autofree char *over = apex_format_disk_free (2 * TB, TB);

    g_assert_cmpstr (board, ==, "588 GB free of 1 TB");
    g_assert_cmpstr (over, ==, "1 TB free of 1 TB");
}

static void
test_used_fraction (void)
{
    g_assert_cmpfloat_with_epsilon (apex_disk_used_fraction (588 * GB, TB), 0.412, 1e-9);
    g_assert_cmpfloat (apex_disk_used_fraction (0, 0), ==, 0.0);
    g_assert_cmpfloat (apex_disk_used_fraction (2 * TB, TB), ==, 0.0);
}

static void
test_item_count (void)
{
    assert_count (9, FALSE, 0, NULL, "9 items");
    assert_count (1, FALSE, 0, NULL, "1 item");
    assert_count (0, FALSE, 0, NULL, "0 items");
    assert_count (5, FALSE, 1, "Apex Fedora — Spec.odt", "5 items · “Apex Fedora — Spec.odt” selected");
    assert_count (5, FALSE, 3, NULL, "5 items · 3 selected");
    assert_count (7, TRUE, 0, NULL, "7 results");
    assert_count (1, TRUE, 1, "HIG Notes.md", "1 result · “HIG Notes.md” selected");
}

static void
test_kind (void)
{
    g_assert_cmpint (apex_kind_of ("inode/directory", TRUE), ==, APEX_KIND_FOLDER);
    g_assert_cmpint (apex_kind_of ("application/vnd.oasis.opendocument.text", FALSE), ==, APEX_KIND_DOCUMENT);
    g_assert_cmpint (apex_kind_of ("application/vnd.oasis.opendocument.spreadsheet", FALSE), ==, APEX_KIND_DOCUMENT);
    g_assert_cmpint (apex_kind_of ("text/markdown", FALSE), ==, APEX_KIND_DOCUMENT);
    g_assert_cmpint (apex_kind_of ("text/x-scss", FALSE), ==, APEX_KIND_DOCUMENT);
    g_assert_cmpint (apex_kind_of ("application/pdf", FALSE), ==, APEX_KIND_DOCUMENT);
    g_assert_cmpint (apex_kind_of ("application/json", FALSE), ==, APEX_KIND_DOCUMENT);
    g_assert_cmpint (apex_kind_of ("image/png", FALSE), ==, APEX_KIND_IMAGE);
    g_assert_cmpint (apex_kind_of ("audio/flac", FALSE), ==, APEX_KIND_MEDIA);
    g_assert_cmpint (apex_kind_of ("video/webm", FALSE), ==, APEX_KIND_MEDIA);
    g_assert_cmpint (apex_kind_of ("application/x-cd-image", FALSE), ==, APEX_KIND_OTHER);
    g_assert_cmpint (apex_kind_of ("application/zip", FALSE), ==, APEX_KIND_OTHER);
    g_assert_cmpint (apex_kind_of (NULL, FALSE), ==, APEX_KIND_OTHER);
}

static void
assert_day (const char *when,
            const char *expected)
{
    g_autoptr (GDateTime) now = g_date_time_new_utc (2026, 10, 21, 10, 24, 0);
    g_autoptr (GDateTime) moment = g_date_time_new_from_iso8601 (when, NULL);
    g_autofree char *text = apex_format_day (moment, now);

    g_assert_cmpstr (text, ==, expected);
}

static void
test_day (void)
{
    assert_day ("2026-10-21T00:05:00Z", "Today");
    assert_day ("2026-10-20T18:40:00Z", "Yesterday");
    assert_day ("2026-10-18T12:00:00Z", "Oct 18");
    assert_day ("2026-10-09T12:00:00Z", "Oct 9");
    assert_day ("2025-12-31T12:00:00Z", "Dec 31, 2025");
}

static void
test_home_path (void)
{
    g_autofree char *inside = apex_format_home_path ("/home/apex/Documents/Spec.odt", "/home/apex");
    g_autofree char *home = apex_format_home_path ("/home/apex", "/home/apex");
    g_autofree char *sibling = apex_format_home_path ("/home/apexe/notes", "/home/apex");

    g_assert_cmpstr (inside, ==, "~/Documents/Spec.odt");
    g_assert_cmpstr (home, ==, "~");
    g_assert_cmpstr (sibling, ==, "/home/apexe/notes");
}

int
main (int   argc,
      char *argv[])
{
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/apex/format/disk-size", test_disk_size);
    g_test_add_func ("/apex/format/disk-free", test_disk_free);
    g_test_add_func ("/apex/format/used-fraction", test_used_fraction);
    g_test_add_func ("/apex/format/item-count", test_item_count);
    g_test_add_func ("/apex/format/kind", test_kind);
    g_test_add_func ("/apex/format/day", test_day);
    g_test_add_func ("/apex/format/home-path", test_home_path);
    return g_test_run ();
}
