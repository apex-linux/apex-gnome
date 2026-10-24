/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <config.h>

#include <adwaita.h>
#include <glib/gi18n.h>

#include "cc-apex-background.h"

/* Board 23: the active wallpaper's name beside the Background header, and a note under the chooser. */
typedef struct {
    char *name;
    gboolean has_dark;
    GtkWidget *label;
    GtkWidget *note;
} Shown;

static void
shown_free (gpointer data)
{
    Shown *shown = data;

    g_free (shown->name);
    g_free (shown);
}

static void
apply (GtkWidget *chooser)
{
    Shown *shown = g_object_get_data (G_OBJECT (chooser), "apex-background");
    GtkWidget *group = gtk_widget_get_ancestor (chooser, ADW_TYPE_PREFERENCES_GROUP);
    g_autofree char *note = NULL;

    if (shown == NULL || group == NULL)
        return;
    if (shown->label == NULL) {
        GtkWidget *suffix = adw_preferences_group_get_header_suffix (ADW_PREFERENCES_GROUP (group));
        GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);

        shown->label = gtk_label_new (NULL);
        gtk_label_set_ellipsize (GTK_LABEL (shown->label), PANGO_ELLIPSIZE_END);
        gtk_widget_add_css_class (shown->label, "dim-label");
        gtk_widget_add_css_class (shown->label, "caption");
        gtk_box_append (GTK_BOX (box), shown->label);
        if (suffix != NULL) {
            g_object_ref (suffix);
            adw_preferences_group_set_header_suffix (ADW_PREFERENCES_GROUP (group), NULL);
            gtk_box_append (GTK_BOX (box), suffix);
            g_object_unref (suffix);
        }
        adw_preferences_group_set_header_suffix (ADW_PREFERENCES_GROUP (group), box);

        shown->note = gtk_label_new (NULL);
        gtk_label_set_wrap (GTK_LABEL (shown->note), TRUE);
        gtk_label_set_xalign (GTK_LABEL (shown->note), 0);
        gtk_widget_add_css_class (shown->note, "dim-label");
        gtk_widget_add_css_class (shown->note, "caption");
        gtk_widget_add_css_class (shown->note, "apex-background-note");
        adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), shown->note);
    }

    gtk_label_set_text (GTK_LABEL (shown->label), shown->name ? shown->name : "");
    gtk_widget_set_visible (shown->label, shown->name != NULL);
    if (shown->name != NULL)
        note = g_strdup_printf (shown->has_dark ? _("%s has a light and a dark version and follows the style.")
                                                : _("%s is one picture for both styles."),
                                shown->name);
    gtk_label_set_text (GTK_LABEL (shown->note), note ? note : "");
    gtk_widget_set_visible (shown->note, note != NULL);
}

/* The chooser calls this as it marks its active item; NULL clears. Before it is in its group, apply waits for map. */
void
cc_apex_background_show (GtkWidget *chooser, const char *name, gboolean has_dark)
{
    GtkWidget *root = gtk_widget_get_ancestor (chooser, g_type_from_name ("CcBackgroundChooser"));
    Shown *shown;

    if (root != NULL)
        chooser = root;
    shown = g_object_get_data (G_OBJECT (chooser), "apex-background");
    if (shown == NULL) {
        shown = g_new0 (Shown, 1);
        g_object_set_data_full (G_OBJECT (chooser), "apex-background", shown, shown_free);
        g_signal_connect (chooser, "map", G_CALLBACK (apply), NULL);
    }
    g_free (shown->name);
    shown->name = g_strdup (name);
    shown->has_dark = has_dark;
    apply (chooser);
}
