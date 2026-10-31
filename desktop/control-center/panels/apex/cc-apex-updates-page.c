/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <config.h>

#include <glib/gi18n.h>

#include "cc-apex-tile.h"
#include "cc-apex-update1.h"
#include "cc-apex-updates-page.h"
#include "cc-apex-updates-state.h"

#define UPDATE1_NAME "io.github.apex_linux.Apex.Update1"
#define UPDATE1_PATH "/io/github/apex_linux/Apex/Update1"
#define NOT_AUTHORIZED UPDATE1_NAME ".Error.NotAuthorized"

struct _CcApexUpdatesPage {
    AdwNavigationPage parent_instance;

    CcApexUpdate1 *update1;
    GDBusProxy *members;
    gboolean has_changes_for;
    gboolean members_known;
    GPtrArray *kept_rows;
    GCancellable *cancellable;
    char *changes_digest;
    char *kept_digest;
    char *alerted_digest;
    gint64 download_started;
    double download_start_progress;
    GPtrArray *change_rows;
    gboolean busy;
    CcApexUpdatesAction pending_action;
    CcApexUpdatesAction primary_action;
    CcApexUpdatesAction secondary_action;

    GtkStack *stack;
    CcApexTile *hero_tile;
    GtkLabel *hero_title;
    GtkLabel *hero_subtitle;
    GtkWidget *hero_progress_box;
    GtkProgressBar *hero_progress;
    GtkLabel *hero_progress_label;
    GtkButton *hero_primary;
    GtkButton *hero_secondary;
    GtkLabel *error_label;
    GtkBox *notes;
    AdwPreferencesGroup *changes_group;
    AdwExpanderRow *changes_row;
    AdwActionRow *running_row;
    GtkLabel *running_built;
    AdwActionRow *staged_row;
    AdwActionRow *rollback_row;
    AdwPreferencesGroup *versions_group;
    GtkButton *rollback_button;
    AdwSwitchRow *automatic_row;
    AdwActionRow *channel_row;
    AdwActionRow *last_check_row;
    GtkButton *check_button;
};

G_DEFINE_FINAL_TYPE (CcApexUpdatesPage, cc_apex_updates_page, ADW_TYPE_NAVIGATION_PAGE)

static void refresh (CcApexUpdatesPage *self);

static const char *
or_empty (const char *s)
{
    return s ? s : "";
}

static const char *
dict_string (GVariant *dict, const char *key)
{
    const char *value = NULL;

    if (dict)
        g_variant_lookup (dict, key, "&s", &value);
    return value;
}

static gint64
dict_timestamp (GVariant *dict, const char *key)
{
    guint64 value = 0;

    if (dict)
        g_variant_lookup (dict, key, "t", &value);
    return (gint64) value;
}

static gboolean
dict_is_empty (GVariant *dict)
{
    return dict == NULL || g_variant_n_children (dict) == 0;
}

/* Members newer than the compiled interface come through an info-less proxy, so an older daemon simply lacks them. */
static GVariant *
member (CcApexUpdatesPage *self, const char *name, const char *type)
{
    g_autoptr(GVariant) value = self->members ? g_dbus_proxy_get_cached_property (self->members, name) : NULL;

    return value && g_variant_is_of_type (value, G_VARIANT_TYPE (type)) ? g_steal_pointer (&value) : NULL;
}

static void
show_error (CcApexUpdatesPage *self, const GError *error)
{
    g_autofree char *remote = g_dbus_error_get_remote_error (error);
    g_autoptr(GError) copy = g_error_copy (error);

    if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED) || g_strcmp0 (remote, NOT_AUTHORIZED) == 0)
        return;
    g_dbus_error_strip_remote_error (copy);
    gtk_label_set_label (self->error_label, copy->message);
    gtk_widget_set_visible (GTK_WIDGET (self->error_label), TRUE);
}

static void
set_busy (CcApexUpdatesPage *self, gboolean busy)
{
    self->busy = busy;
    if (busy)
        gtk_widget_set_visible (GTK_WIDGET (self->error_label), FALSE);
    refresh (self);
}

static void
reboot_cb (GObject *source, GAsyncResult *result, gpointer user_data)
{
    g_autoptr(GVariant) reply = NULL;
    g_autoptr(GError) error = NULL;

    reply = g_dbus_connection_call_finish (G_DBUS_CONNECTION (source), result, &error);
    if (reply == NULL && !g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        show_error (CC_APEX_UPDATES_PAGE (user_data), error);
}

static void
reboot (CcApexUpdatesPage *self)
{
    g_autoptr(GDBusConnection) bus = g_bus_get_sync (G_BUS_TYPE_SESSION, NULL, NULL);

    if (bus == NULL)
        return;
    g_dbus_connection_call (bus, "org.gnome.SessionManager", "/org/gnome/SessionManager",
                            "org.gnome.SessionManager", "Reboot", NULL, NULL, G_DBUS_CALL_FLAGS_NONE, G_MAXINT,
                            self->cancellable, reboot_cb, self);
}

/* Every Update1 call ends here; polkit asks in the daemon, and only the reply comes back. */
static void
update1_call_cb (GObject *source, GAsyncResult *result, gpointer user_data)
{
    CcApexUpdatesPage *self = CC_APEX_UPDATES_PAGE (user_data);
    g_autoptr(GVariant) reply = NULL;
    g_autoptr(GError) error = NULL;

    reply = g_dbus_proxy_call_finish (G_DBUS_PROXY (source), result, &error);
    if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        return;
    set_busy (self, FALSE);
    if (reply == NULL)
        show_error (self, error);
    else if (self->pending_action == CC_APEX_UPDATES_ACTION_APPLY_AND_RESTART)
        reboot (self);
}

static void
call_update1 (CcApexUpdatesPage *self, CcApexUpdatesAction action, const char *method, GVariant *args)
{
    self->pending_action = action;
    set_busy (self, TRUE);
    g_dbus_proxy_call (G_DBUS_PROXY (self->update1), method, args, G_DBUS_CALL_FLAGS_NONE, G_MAXINT,
                       self->cancellable, update1_call_cb, self);
}

static void
run_action (CcApexUpdatesPage *self, CcApexUpdatesAction action)
{
    g_autoptr(GVariant) staged = NULL;

    switch (action) {
    case CC_APEX_UPDATES_ACTION_CHECK:
        call_update1 (self, action, "Check", NULL);
        break;
    case CC_APEX_UPDATES_ACTION_DOWNLOAD:
    case CC_APEX_UPDATES_ACTION_DOWNLOAD_ANYWAY:
        call_update1 (self, action, "Download",
                      g_variant_new ("(b)", action == CC_APEX_UPDATES_ACTION_DOWNLOAD_ANYWAY));
        break;
    case CC_APEX_UPDATES_ACTION_APPLY_AND_RESTART:
        staged = cc_apex_update1_dup_staged (self->update1);
        call_update1 (self, action, "Apply", g_variant_new ("(s)", or_empty (dict_string (staged, "digest"))));
        break;
    case CC_APEX_UPDATES_ACTION_RESTART:
        reboot (self);
        break;
    case CC_APEX_UPDATES_ACTION_ROLLBACK_BAD:
        call_update1 (self, action, "Rollback", g_variant_new ("(b)", TRUE));
        break;
    case CC_APEX_UPDATES_ACTION_ACKNOWLEDGE:
    case CC_APEX_UPDATES_ACTION_ACKNOWLEDGE_FALLBACK:
        call_update1 (self, action, "AcknowledgeHealthFailure", NULL);
        break;
    case CC_APEX_UPDATES_ACTION_KEEP_CURRENT:
        staged = cc_apex_update1_dup_staged (self->update1);
        g_free (self->kept_digest);
    g_free (self->alerted_digest);
        self->kept_digest = g_strdup (dict_string (staged, "digest"));
        refresh (self);
        break;
    case CC_APEX_UPDATES_ACTION_NONE:
    default:
        break;
    }
}

static void
hero_button_clicked_cb (CcApexUpdatesPage *self, GtkButton *button)
{
    run_action (self, button == self->hero_primary ? self->primary_action : self->secondary_action);
}

static void
rollback_clicked_cb (CcApexUpdatesPage *self)
{
    call_update1 (self, CC_APEX_UPDATES_ACTION_NONE, "Rollback", g_variant_new ("(b)", FALSE));
}

static void
check_clicked_cb (CcApexUpdatesPage *self)
{
    run_action (self, CC_APEX_UPDATES_ACTION_CHECK);
}

static void automatic_changed_cb (CcApexUpdatesPage *self);

static void
show_automatic (CcApexUpdatesPage *self)
{
    g_autoptr(GVariant) cached = g_dbus_proxy_get_cached_property (G_DBUS_PROXY (self->update1),
                                                                   "AutomaticDownloads");

    gtk_widget_set_visible (GTK_WIDGET (self->automatic_row), cached != NULL);
    g_signal_handlers_block_by_func (self->automatic_row, automatic_changed_cb, self);
    adw_switch_row_set_active (self->automatic_row, cached != NULL && g_variant_get_boolean (cached));
    g_signal_handlers_unblock_by_func (self->automatic_row, automatic_changed_cb, self);
}

static void
automatic_set_cb (GObject *source, GAsyncResult *result, gpointer user_data)
{
    g_autoptr(GError) error = NULL;
    CcApexUpdatesPage *self;

    if (cc_apex_update1_call_set_automatic_downloads_finish (CC_APEX_UPDATE1 (source), result, &error) ||
        g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        return;
    self = CC_APEX_UPDATES_PAGE (user_data);
    show_error (self, error);
    show_automatic (self);
}

/* update.configure is auth_admin: the daemon asks each time, and a refusal puts the switch back. */
static void
automatic_changed_cb (CcApexUpdatesPage *self)
{
    gtk_widget_set_visible (GTK_WIDGET (self->error_label), FALSE);
    cc_apex_update1_call_set_automatic_downloads (self->update1, adw_switch_row_get_active (self->automatic_row),
                                                  self->cancellable, automatic_set_cb, self);
}

static void
set_action (GtkButton *button, CcApexUpdatesAction action, CcApexUpdatesAction *slot, gboolean busy)
{
    const char *label = cc_apex_updates_action_label (action);

    *slot = action;
    gtk_widget_set_visible (GTK_WIDGET (button), label != NULL);
    gtk_widget_set_sensitive (GTK_WIDGET (button), !busy);
    if (label)
        gtk_button_set_label (button, label);
}

static const char *
badge_icon (const char *state, const CcApexUpdatesHero *hero)
{
    CcApexUpdatesTone tone = hero->tone;

    if (tone == CC_APEX_UPDATES_TONE_GOOD)
        return "object-select-symbolic";
    if (tone == CC_APEX_UPDATES_TONE_ERROR || g_strcmp0 (state, "health-failure") == 0 ||
        hero->primary == CC_APEX_UPDATES_ACTION_ACKNOWLEDGE_FALLBACK)
        return "dialog-warning-symbolic";
    if (tone == CC_APEX_UPDATES_TONE_WARNING)
        return "media-playback-pause-symbolic";
    if (g_strcmp0 (state, "available") == 0 || g_strcmp0 (state, "downloading") == 0)
        return "folder-download-symbolic";
    return "view-refresh-symbolic";
}

static GtkWidget *
change_label (const char *text, const char *style, float xalign)
{
    GtkWidget *label = gtk_label_new (text);

    gtk_label_set_xalign (GTK_LABEL (label), xalign);
    gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class (label, style);
    return label;
}

/* Board 18: the staged changes as one grid of kind, package and versions, not a row each. */
static GtkWidget *
changes_grid (GPtrArray *changes)
{
    GtkWidget *grid = gtk_grid_new ();

    gtk_widget_add_css_class (grid, "apex-changes");
    gtk_grid_set_column_spacing (GTK_GRID (grid), 14);
    gtk_grid_set_row_spacing (GTK_GRID (grid), 6);
    for (guint i = 0; i < changes->len; i++) {
        CcApexUpdatesChange *c = g_ptr_array_index (changes, i);
        GtkWidget *name = change_label (c->name, "apex-change-name", 0);

        gtk_widget_set_hexpand (name, TRUE);
        gtk_grid_attach (GTK_GRID (grid), change_label (c->kind, "apex-change-kind", 0), 0, i, 1, 1);
        gtk_grid_attach (GTK_GRID (grid), name, 1, i, 1, 1);
        gtk_grid_attach (GTK_GRID (grid), change_label (c->versions, "apex-change-versions", 1), 2, i, 1, 1);
    }
    return grid;
}

static void
changes_for_cb (GObject *source, GAsyncResult *result, gpointer user_data)
{
    g_autoptr(GVariant) reply = NULL;
    g_autoptr(GVariant) changes = NULL;
    g_autoptr(GPtrArray) parsed = NULL;
    g_autoptr(GError) error = NULL;
    CcApexUpdatesPage *self;
    GtkWidget *view, *page, *group;
    AdwDialog *dialog;

    reply = g_dbus_proxy_call_finish (G_DBUS_PROXY (source), result, &error);
    if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        return;
    self = CC_APEX_UPDATES_PAGE (user_data);
    if (reply == NULL) {
        show_error (self, error);
        return;
    }

    changes = g_variant_get_child_value (reply, 0);
    parsed = cc_apex_updates_changes (changes);
    group = adw_preferences_group_new ();
    if (parsed->len > 0) {
        GtkWidget *row = adw_preferences_row_new ();

        gtk_list_box_row_set_activatable (GTK_LIST_BOX_ROW (row), FALSE);
        gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), changes_grid (parsed));
        adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), row);
    } else {
        adw_preferences_group_set_description (ADW_PREFERENCES_GROUP (group), _("No package changes are known."));
    }
    page = adw_preferences_page_new ();
    adw_preferences_page_add (ADW_PREFERENCES_PAGE (page), ADW_PREFERENCES_GROUP (group));
    view = adw_toolbar_view_new ();
    adw_toolbar_view_add_top_bar (ADW_TOOLBAR_VIEW (view), adw_header_bar_new ());
    adw_toolbar_view_set_content (ADW_TOOLBAR_VIEW (view), page);
    dialog = adw_dialog_new ();
    adw_dialog_set_title (dialog, _("Changes in the Set-Aside Version"));
    adw_dialog_set_content_width (dialog, 480);
    adw_dialog_set_content_height (dialog, 560);
    adw_dialog_set_child (dialog, view);
    adw_dialog_present (dialog, GTK_WIDGET (self));
}

static void
alert_response_cb (CcApexUpdatesPage *self, const char *response)
{
    if (g_str_equal (response, "changes"))
        g_dbus_proxy_call (self->members, "GetChangesFor",
                           g_variant_new ("(s)", or_empty (cc_apex_update1_get_last_fallback (self->update1))),
                           G_DBUS_CALL_FLAGS_NONE, G_MAXINT, self->cancellable, changes_for_cb, self);
    else if (g_str_equal (response, "back"))
        run_action (self, CC_APEX_UPDATES_ACTION_ROLLBACK_BAD);
    else if (g_str_equal (response, "keep") || g_str_equal (response, "ok"))
        run_action (self, CC_APEX_UPDATES_ACTION_ACKNOWLEDGE);
}

static void
add_alert_row (GtkGrid *grid, int row, const char *label, const char *value)
{
    GtkWidget *key = gtk_label_new (label);
    GtkWidget *val = gtk_label_new (value);

    gtk_label_set_xalign (GTK_LABEL (key), 0);
    gtk_widget_add_css_class (key, "dim-label");
    gtk_label_set_xalign (GTK_LABEL (val), 0);
    gtk_label_set_selectable (GTK_LABEL (val), TRUE);
    gtk_widget_add_css_class (val, "monospace");
    gtk_grid_attach (grid, key, 0, row, 1, 1);
    gtk_grid_attach (grid, val, 1, row, 1, 1);
}

/* Board 26: once per failed digest while this page lives, when the page shows. */
static void
maybe_alert (CcApexUpdatesPage *self, const char *health_failure, const char *last_fallback, GVariant *booted,
             GVariant *rollback)
{
    gboolean failed = health_failure && *health_failure;
    const char *digest = failed ? health_failure : last_fallback;
    g_autofree char *short_digest = NULL;
    AdwDialog *dialog;
    GtkWidget *grid;
    int row = 0;

    if (digest == NULL || *digest == '\0' || g_strcmp0 (digest, self->alerted_digest) == 0 ||
        !self->members_known || !gtk_widget_get_mapped (GTK_WIDGET (self)))
        return;
    g_free (self->alerted_digest);
    self->alerted_digest = g_strdup (digest);

    grid = gtk_grid_new ();
    gtk_grid_set_column_spacing (GTK_GRID (grid), 14);
    gtk_grid_set_row_spacing (GTK_GRID (grid), 5);
    gtk_widget_set_halign (grid, GTK_ALIGN_CENTER);
    gtk_widget_add_css_class (grid, "apex-alert-facts");
    if (failed) {
        g_autoptr(GVariant) checks = member (self, "HealthFailureChecks", "as");
        g_autofree const char **names = checks ? g_variant_get_strv (checks, NULL) : NULL;
        g_autofree char *joined = names && names[0] ? g_strjoinv (", ", (char **) names) : NULL;

        if (joined)
            add_alert_row (GTK_GRID (grid), row++, _("Failed check"), joined);
    }
    add_alert_row (GTK_GRID (grid), row++, _("Running"), or_empty (dict_string (booted, "version")));
    if (failed) {
        dialog = adw_alert_dialog_new (_("Update Failed Its Startup Check"),
                                       _("This version is running, but a required check did not pass. Going back to "
                                         "the version you had before is the safe choice. Nothing restarts until you "
                                         "say so."));
        add_alert_row (GTK_GRID (grid), row++, _("Previous"), or_empty (dict_string (rollback, "version")));
        adw_alert_dialog_add_responses (ADW_ALERT_DIALOG (dialog), "keep", _("Keep This Version"), "back",
                                        _("Go Back…"), NULL);
        adw_alert_dialog_set_response_appearance (ADW_ALERT_DIALOG (dialog), "back", ADW_RESPONSE_SUGGESTED);
        adw_alert_dialog_set_default_response (ADW_ALERT_DIALOG (dialog), "back");
        adw_alert_dialog_set_close_response (ADW_ALERT_DIALOG (dialog), "close");
    } else {
        dialog = adw_alert_dialog_new (_("Apex Went Back to the Previous Version"),
                                       _("The update did not start properly three times in a row, so Apex started "
                                         "the version you had before. That build will not be offered again; a newer "
                                         "one will be."));
        short_digest = cc_apex_updates_short_digest (digest);
        add_alert_row (GTK_GRID (grid), row++, _("Set aside"), short_digest);
        add_alert_row (GTK_GRID (grid), row++, _("Your files"), _("unchanged"));
        if (self->has_changes_for)
            adw_alert_dialog_add_response (ADW_ALERT_DIALOG (dialog), "changes", _("Show Changes"));
        adw_alert_dialog_add_responses (ADW_ALERT_DIALOG (dialog), "ok", _("OK"), NULL);
        adw_alert_dialog_set_response_appearance (ADW_ALERT_DIALOG (dialog), "ok", ADW_RESPONSE_SUGGESTED);
        adw_alert_dialog_set_close_response (ADW_ALERT_DIALOG (dialog), "close");
    }
    adw_alert_dialog_set_extra_child (ADW_ALERT_DIALOG (dialog), grid);
    g_signal_connect_object (dialog, "response", G_CALLBACK (alert_response_cb), self, G_CONNECT_SWAPPED);
    adw_dialog_present (dialog, GTK_WIDGET (self));
}

static void
add_note (CcApexUpdatesPage *self, const char *title, const char *body)
{
    GtkWidget *note, *icon, *text, *label;

    note = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class (note, "apex-note");
    gtk_accessible_update_property (GTK_ACCESSIBLE (note), GTK_ACCESSIBLE_PROPERTY_LABEL, title, -1);
    icon = gtk_image_new_from_icon_name ("dialog-warning-symbolic");
    gtk_widget_set_valign (icon, GTK_ALIGN_START);
    gtk_widget_add_css_class (icon, "apex-note-icon");
    gtk_box_append (GTK_BOX (note), icon);
    text = gtk_box_new (GTK_ORIENTATION_VERTICAL, 3);
    label = gtk_label_new (title);
    gtk_label_set_xalign (GTK_LABEL (label), 0);
    gtk_label_set_wrap (GTK_LABEL (label), TRUE);
    gtk_widget_add_css_class (label, "apex-note-title");
    gtk_box_append (GTK_BOX (text), label);
    label = gtk_label_new (body);
    gtk_label_set_xalign (GTK_LABEL (label), 0);
    gtk_label_set_wrap (GTK_LABEL (label), TRUE);
    gtk_widget_add_css_class (label, "dim-label");
    gtk_widget_add_css_class (label, "caption");
    gtk_box_append (GTK_BOX (text), label);
    gtk_box_append (GTK_BOX (note), text);
    gtk_box_append (self->notes, note);
}

static void
refresh_notes (CcApexUpdatesPage *self, GVariant *newest)
{
    g_autofree const char **held = NULL;
    g_autofree const char **degraded = NULL;
    g_autoptr(GVariant) holds = NULL;
    g_autoptr(GVariant) stock = NULL;
    GtkWidget *child;

    while ((child = gtk_widget_get_first_child (GTK_WIDGET (self->notes))))
        gtk_box_remove (self->notes, child);

    if (newest) {
        g_variant_lookup (newest, "held", "^a&s", &held);
        g_variant_lookup (newest, "degraded", "^a&s", &degraded);
    }
    if (newest) {
        holds = g_variant_lookup_value (newest, "holds", G_VARIANT_TYPE ("a(sstbts)"));
        if (holds == NULL)
            holds = g_variant_lookup_value (newest, "holds", G_VARIANT_TYPE ("a(sstbt)"));
        stock = g_variant_lookup_value (newest, "stock", G_VARIANT_TYPE ("a(ss)"));
    }
    for (guint i = 0; held && held[i]; i++) {
        gboolean found = FALSE;

        for (gsize r = 0; holds && r < g_variant_n_children (holds); r++) {
            g_autoptr(GVariant) record = g_variant_get_child_value (holds, r);
            g_autofree char *title = NULL;
            g_autofree char *body = NULL;
            const char *family, *newer, *side = NULL;
            guint64 since, limit;
            gboolean security;

            if (g_variant_n_children (record) == 6)
                g_variant_get (record, "(&s&stbt&s)", &family, &newer, &since, &security, &limit, &side);
            else
                g_variant_get (record, "(&s&stbt)", &family, &newer, &since, &security, &limit);
            if (!g_str_equal (family, held[i]))
                continue;
            found = TRUE;
            cc_apex_updates_hold_note (family, side, newer, (gint64) since, security, (gint64) limit, &title, &body);
            add_note (self, title, body);
        }
        if (!found) {
            g_autofree char *title = NULL;
            g_autofree char *body = NULL;

            cc_apex_updates_hold_note (held[i], NULL, NULL, 0, FALSE, 0, &title, &body);
            add_note (self, title, body);
        }
    }
    for (gsize r = 0; stock && r < g_variant_n_children (stock); r++) {
        const char *family, *reason;
        g_autofree char *title = NULL;

        g_variant_get_child (stock, r, "(&s&s)", &family, &reason);
        title = g_strdup_printf (_("%s runs Fedora’s own build"), family);
        add_note (self, title, *reason ? reason : _("This version ships it without Apex’s changes."));
    }
    for (guint i = 0; degraded && degraded[i]; i++) {
        g_autofree char *title = g_strdup_printf (_("%s runs without Apex’s changes"), degraded[i]);
        g_autofree char *body = g_strdup_printf (_("This version ships Fedora’s own %s."), degraded[i]);
        add_note (self, title, body);
    }
    gtk_widget_set_visible (GTK_WIDGET (self->notes), gtk_widget_get_first_child (GTK_WIDGET (self->notes)) != NULL);
}

static void
changes_cb (GObject *source, GAsyncResult *result, gpointer user_data)
{
    CcApexUpdatesPage *self;
    g_autoptr(GVariant) changes = NULL;
    g_autoptr(GPtrArray) parsed = NULL;
    g_autoptr(GVariant) staged = NULL;
    g_autoptr(GError) error = NULL;
    g_autofree char *summary = NULL;
    g_autofree char *built = NULL;
    g_autofree char *subtitle = NULL;
    GtkWidget *grid;
    guint others = 0;

    if (!cc_apex_update1_call_get_changes_finish (CC_APEX_UPDATE1 (source), &changes, result, &error)) {
        if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
            g_warning ("Cannot read the staged changes: %s", error->message);
        return;
    }
    self = CC_APEX_UPDATES_PAGE (user_data);

    for (guint i = 0; i < self->change_rows->len; i++)
        adw_expander_row_remove (self->changes_row, g_ptr_array_index (self->change_rows, i));
    g_ptr_array_set_size (self->change_rows, 0);

    parsed = cc_apex_updates_changes (changes);
    gtk_widget_set_visible (GTK_WIDGET (self->changes_group), parsed->len > 0);
    if (parsed->len == 0)
        return;

    summary = cc_apex_updates_changes_summary (parsed, &others);
    staged = cc_apex_update1_dup_staged (self->update1);
    built = cc_apex_updates_built (dict_timestamp (staged, "timestamp"));
    adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->changes_row),
                                   summary ? summary : _("Package changes"));
    if (others > 0)
        subtitle = g_strdup_printf (g_dngettext (GETTEXT_PACKAGE, "and %u other package · %s%s%s",
                                                 "and %u other packages · %s%s%s", others),
                                    others, or_empty (dict_string (staged, "version")), built ? ", " : "",
                                    built ? built : "");
    else
        subtitle = g_strdup_printf ("%s%s%s", or_empty (dict_string (staged, "version")), built ? ", " : "",
                                    built ? built : "");
    adw_expander_row_set_subtitle (self->changes_row, subtitle);

    grid = changes_grid (parsed);
    adw_expander_row_add_row (self->changes_row, grid);
    g_ptr_array_add (self->change_rows, grid);
}

static void
refresh_changes (CcApexUpdatesPage *self, GVariant *staged)
{
    const char *digest = dict_string (staged, "digest");

    if (g_strcmp0 (digest, self->changes_digest) == 0)
        return;
    g_free (self->changes_digest);
    self->changes_digest = g_strdup (digest);
    if (digest == NULL) {
        gtk_widget_set_visible (GTK_WIDGET (self->changes_group), FALSE);
        return;
    }
    cc_apex_update1_call_get_changes (self->update1, self->cancellable, changes_cb, self);
}

static void
set_deployment (AdwActionRow *row, GtkLabel *built_label, GVariant *dict)
{
    g_autofree char *line = cc_apex_updates_deployment_line (dict_string (dict, "version"), dict_string (dict, "digest"));
    g_autofree char *built = cc_apex_updates_built (dict_timestamp (dict, "timestamp"));

    const char *pin_reason = dict_string (dict, "pin-reason");
    g_autofree char *mono = g_markup_printf_escaped ("<span font_family=\"monospace\">%s</span>", line ? line : "");
    g_autofree char *subtitle = NULL;

    if (pin_reason && *pin_reason) {
        g_autofree char *escaped = g_markup_escape_text (pin_reason, -1);

        subtitle = g_strdup_printf (_("%s\nKept by Apex: %s"), mono, escaped);
    }
    gtk_widget_set_visible (GTK_WIDGET (row), !dict_is_empty (dict));
    adw_action_row_set_subtitle (row, subtitle ? subtitle : mono);
    if (built_label)
        gtk_label_set_label (built_label, built ? built : "");
}

static void
refresh_kept (CcApexUpdatesPage *self)
{
    g_autoptr(GVariant) kept = member (self, "Kept", "aa{sv}");

    for (guint i = 0; i < self->kept_rows->len; i++)
        adw_preferences_group_remove (self->versions_group, g_ptr_array_index (self->kept_rows, i));
    g_ptr_array_set_size (self->kept_rows, 0);

    for (gsize i = 0; kept && i < g_variant_n_children (kept); i++) {
        g_autoptr(GVariant) dict = g_variant_get_child_value (kept, i);
        GtkWidget *row = adw_action_row_new ();
        GtkWidget *built = gtk_label_new (NULL);

        adw_preferences_row_set_title (ADW_PREFERENCES_ROW (row), _("Kept"));
        gtk_widget_add_css_class (built, "dim-label");
        adw_action_row_add_suffix (ADW_ACTION_ROW (row), built);
        set_deployment (ADW_ACTION_ROW (row), GTK_LABEL (built), dict);
        adw_preferences_group_add (self->versions_group, row);
        g_ptr_array_add (self->kept_rows, row);
    }
}

static void
refresh (CcApexUpdatesPage *self)
{
    g_autoptr(GVariant) booted = NULL;
    g_autoptr(GVariant) staged = NULL;
    g_autoptr(GVariant) rollback = NULL;
    g_autoptr(GVariant) available = NULL;
    g_autofree char *owner = NULL;
    g_autofree char *checked = NULL;
    g_auto(CcApexUpdatesHero) hero = { 0 };
    CcApexUpdatesFacts facts = { 0 };
    const char *channel;
    double progress;

    if (self->update1 == NULL)
        return;
    owner = g_dbus_proxy_get_name_owner (G_DBUS_PROXY (self->update1));
    gtk_stack_set_visible_child_name (self->stack, owner ? "page" : "unavailable");
    if (owner == NULL)
        return;

    booted = cc_apex_update1_dup_booted (self->update1);
    staged = cc_apex_update1_dup_staged (self->update1);
    rollback = cc_apex_update1_dup_rollback (self->update1);
    available = cc_apex_update1_dup_available (self->update1);
    channel = cc_apex_update1_get_channel (self->update1);

    facts.state = cc_apex_update1_get_state (self->update1);
    facts.booted_version = dict_string (booted, "version");
    facts.target_version = dict_string (dict_is_empty (staged) ? available : staged, "version");
    facts.rollback_version = dict_string (rollback, "version");
    facts.channel = channel;
    facts.deferred_reason = cc_apex_update1_get_deferred_reason (self->update1);
    facts.last_error = cc_apex_update1_get_last_error (self->update1);
    facts.last_fallback = cc_apex_update1_get_last_fallback (self->update1);
    g_variant_lookup (dict_is_empty (staged) ? available : staged, "download-size", "t", &facts.download_size);
    facts.last_check = (gint64) cc_apex_update1_get_last_check (self->update1);
    facts.now = g_get_real_time () / G_USEC_PER_SEC;
    facts.kept_current = self->kept_digest != NULL && g_strcmp0 (self->kept_digest, dict_string (staged, "digest")) == 0;
    cc_apex_updates_hero_init (&hero, &facts);

    cc_apex_tile_set_badge (self->hero_tile, badge_icon (facts.state, &hero),
                            (const char *[]) { "good", "accent", "warning", "error" }[hero.tone]);
    gtk_label_set_label (self->hero_title, hero.title);
    gtk_label_set_label (self->hero_subtitle, hero.subtitle);
    gtk_widget_set_visible (self->hero_progress_box, hero.show_progress);
    progress = cc_apex_update1_get_progress (self->update1);
    if (!hero.show_progress || progress < 0)
        self->download_started = 0;
    if (hero.show_progress && progress >= 0) {
        g_autofree char *line = NULL;
        gint64 now = g_get_monotonic_time (), left = -1;

        if (self->download_started == 0) {
            self->download_started = now;
            self->download_start_progress = progress;
        } else if (progress - self->download_start_progress > 0.02 && now - self->download_started > 5 * G_USEC_PER_SEC) {
            left = (gint64) ((now - self->download_started) / G_USEC_PER_SEC * (1 - progress) /
                             (progress - self->download_start_progress));
        }
        line = cc_apex_updates_progress_line (progress, facts.download_size, left);
        gtk_progress_bar_set_fraction (self->hero_progress, progress);
        gtk_label_set_label (self->hero_progress_label, line);
    } else if (hero.show_progress) {
        gtk_progress_bar_pulse (self->hero_progress);
        gtk_label_set_label (self->hero_progress_label, "");
    }
    set_action (self->hero_primary, hero.primary, &self->primary_action, self->busy);
    set_action (self->hero_secondary, hero.secondary, &self->secondary_action, self->busy);

    refresh_notes (self, dict_is_empty (staged) ? booted : staged);
    refresh_changes (self, staged);

    set_deployment (self->running_row, self->running_built, booted);
    set_deployment (self->staged_row, NULL, staged);
    set_deployment (self->rollback_row, NULL, rollback);
    refresh_kept (self);
    gtk_widget_set_sensitive (GTK_WIDGET (self->rollback_button),
                              !self->busy && g_strcmp0 (facts.state, "rollback-queued") != 0);

    adw_action_row_set_subtitle (self->channel_row,
                                 g_str_has_prefix (channel ? channel : "", "testing")
                                     ? _("Testing: candidate builds signed with the CI key")
                                     : _("Stable: qualified builds signed with the release key"));
    checked = facts.last_check > 0 ? cc_apex_updates_when (facts.last_check, facts.now) : NULL;
    adw_action_row_set_subtitle (self->last_check_row, checked ? checked : _("Never"));
    gtk_widget_set_sensitive (GTK_WIDGET (self->check_button), !self->busy);
    show_automatic (self);
    maybe_alert (self, cc_apex_update1_get_health_failure (self->update1), facts.last_fallback, booted, rollback);
}

static void
introspect_cb (GObject *source, GAsyncResult *result, gpointer user_data)
{
    g_autoptr(GVariant) reply = NULL;
    g_autoptr(GDBusNodeInfo) node = NULL;
    const char *xml;
    GDBusInterfaceInfo *iface;

    g_autoptr(GError) error = NULL;
    CcApexUpdatesPage *self;

    reply = g_dbus_connection_call_finish (G_DBUS_CONNECTION (source), result, &error);
    if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        return;
    self = CC_APEX_UPDATES_PAGE (user_data);
    if (reply) {
        g_variant_get (reply, "(&s)", &xml);
        node = g_dbus_node_info_new_for_xml (xml, NULL);
        iface = node ? g_dbus_node_info_lookup_interface (node, UPDATE1_NAME) : NULL;
        self->has_changes_for = iface != NULL && g_dbus_interface_info_lookup_method (iface, "GetChangesFor") != NULL;
    }
    self->members_known = TRUE;
    refresh (self);
}

static void
members_ready_cb (GObject *source, GAsyncResult *result, gpointer user_data)
{
    g_autoptr(GError) error = NULL;
    CcApexUpdatesPage *self;
    GDBusProxy *proxy;

    proxy = g_dbus_proxy_new_finish (result, &error);
    if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        return;
    self = CC_APEX_UPDATES_PAGE (user_data);
    if (proxy == NULL) {
        g_warning ("Cannot read %s's newer members: %s", UPDATE1_NAME, error->message);
        self->members_known = TRUE;
        refresh (self);
        return;
    }
    self->members = proxy;
    g_dbus_proxy_set_default_timeout (proxy, G_MAXINT);
    g_signal_connect_object (proxy, "g-properties-changed", G_CALLBACK (refresh), self, G_CONNECT_SWAPPED);
    g_dbus_connection_call (g_dbus_proxy_get_connection (proxy), UPDATE1_NAME, UPDATE1_PATH,
                            "org.freedesktop.DBus.Introspectable", "Introspect", NULL, G_VARIANT_TYPE ("(s)"),
                            G_DBUS_CALL_FLAGS_NONE, -1, self->cancellable, introspect_cb, self);
    refresh (self);
}

static void
proxy_ready_cb (GObject *source, GAsyncResult *result, gpointer user_data)
{
    g_autoptr(GError) error = NULL;
    CcApexUpdate1 *proxy;
    CcApexUpdatesPage *self;

    proxy = cc_apex_update1_proxy_new_for_bus_finish (result, &error);
    if (proxy == NULL) {
        if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
            g_warning ("Cannot reach %s: %s", UPDATE1_NAME, error->message);
        if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
            gtk_stack_set_visible_child_name (CC_APEX_UPDATES_PAGE (user_data)->stack, "unavailable");
        return;
    }

    self = CC_APEX_UPDATES_PAGE (user_data);
    self->update1 = proxy;
    g_dbus_proxy_set_default_timeout (G_DBUS_PROXY (proxy), G_MAXINT);
    g_signal_connect_object (proxy, "g-properties-changed", G_CALLBACK (refresh), self, G_CONNECT_SWAPPED);
    g_signal_connect_object (proxy, "notify::g-name-owner", G_CALLBACK (refresh), self, G_CONNECT_SWAPPED);
    refresh (self);
    g_dbus_proxy_new (g_dbus_proxy_get_connection (G_DBUS_PROXY (proxy)), G_DBUS_PROXY_FLAGS_DO_NOT_AUTO_START, NULL,
                      UPDATE1_NAME, UPDATE1_PATH, UPDATE1_NAME, self->cancellable, members_ready_cb, self);
}

static void
cc_apex_updates_page_dispose (GObject *object)
{
    CcApexUpdatesPage *self = CC_APEX_UPDATES_PAGE (object);

    g_cancellable_cancel (self->cancellable);
    g_clear_object (&self->update1);
    g_clear_object (&self->members);

    G_OBJECT_CLASS (cc_apex_updates_page_parent_class)->dispose (object);
}

static void
cc_apex_updates_page_finalize (GObject *object)
{
    CcApexUpdatesPage *self = CC_APEX_UPDATES_PAGE (object);

    g_clear_object (&self->cancellable);
    g_clear_pointer (&self->change_rows, g_ptr_array_unref);
    g_clear_pointer (&self->kept_rows, g_ptr_array_unref);
    g_free (self->changes_digest);
    g_free (self->kept_digest);
    g_free (self->alerted_digest);

    G_OBJECT_CLASS (cc_apex_updates_page_parent_class)->finalize (object);
}

static void
cc_apex_updates_page_class_init (CcApexUpdatesPageClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

    object_class->dispose = cc_apex_updates_page_dispose;
    object_class->finalize = cc_apex_updates_page_finalize;

    g_type_ensure (CC_TYPE_APEX_TILE);

    gtk_widget_class_set_template_from_resource (widget_class, "/org/gnome/Settings/apex/cc-apex-updates-page.ui");

    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, stack);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, hero_tile);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, hero_title);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, hero_subtitle);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, hero_progress_box);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, hero_progress);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, hero_progress_label);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, hero_primary);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, hero_secondary);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, error_label);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, notes);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, changes_group);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, changes_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, running_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, running_built);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, staged_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, rollback_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, versions_group);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, rollback_button);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, automatic_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, channel_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, last_check_row);
    gtk_widget_class_bind_template_child (widget_class, CcApexUpdatesPage, check_button);

    gtk_widget_class_bind_template_callback (widget_class, hero_button_clicked_cb);
    gtk_widget_class_bind_template_callback (widget_class, rollback_clicked_cb);
    gtk_widget_class_bind_template_callback (widget_class, check_clicked_cb);
}

static void
cc_apex_updates_page_init (CcApexUpdatesPage *self)
{
    gtk_widget_init_template (GTK_WIDGET (self));

    self->cancellable = g_cancellable_new ();
    self->change_rows = g_ptr_array_new ();
    self->kept_rows = g_ptr_array_new ();
    gtk_widget_set_visible (GTK_WIDGET (self->changes_group), FALSE);
    gtk_widget_set_visible (GTK_WIDGET (self->notes), FALSE);
    g_signal_connect_swapped (self->automatic_row, "notify::active", G_CALLBACK (automatic_changed_cb), self);
    g_signal_connect_swapped (self, "map", G_CALLBACK (refresh), self);

    cc_apex_update1_proxy_new_for_bus (G_BUS_TYPE_SYSTEM, G_DBUS_PROXY_FLAGS_NONE, UPDATE1_NAME, UPDATE1_PATH,
                                       self->cancellable, proxy_ready_cb, self);
}
