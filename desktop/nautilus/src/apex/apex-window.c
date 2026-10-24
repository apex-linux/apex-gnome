/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-window.h"

#include "apex-count-bar.h"
#include "apex-disk-footer.h"

#define STOCK_ENV "APEX_NAUTILUS_STOCK"

static void
load_css_once (void)
{
    static gboolean loaded;
    g_autoptr (GtkCssProvider) provider = NULL;

    if (loaded)
    {
        return;
    }

    loaded = TRUE;
    provider = gtk_css_provider_new ();
    gtk_css_provider_load_from_resource (provider, "/org/gnome/nautilus/apex/apex.css");
    gtk_style_context_add_provider_for_display (gdk_display_get_default (),
                                                GTK_STYLE_PROVIDER (provider),
                                                GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
}

static void
attach_disk_footer (GtkWidget *places_sidebar)
{
    AdwToolbarView *pane = ADW_TOOLBAR_VIEW (gtk_widget_get_ancestor (places_sidebar, ADW_TYPE_TOOLBAR_VIEW));
    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

    g_object_ref (places_sidebar);
    adw_toolbar_view_set_content (pane, box);
    gtk_box_append (GTK_BOX (box), places_sidebar);
    gtk_box_append (GTK_BOX (box), apex_disk_footer_new ());
    g_object_unref (places_sidebar);
}

static void
attach_count_bar (AdwApplicationWindow *window,
                  GtkWidget            *tab_view)
{
    AdwToolbarView *content = ADW_TOOLBAR_VIEW (gtk_widget_get_ancestor (tab_view, ADW_TYPE_TOOLBAR_VIEW));

    adw_toolbar_view_add_bottom_bar (content, apex_count_bar_new (GTK_WINDOW (window)));
}

void
apex_window_attach (AdwApplicationWindow *window,
                    GtkWidget            *places_sidebar,
                    GtkWidget            *tab_view)
{
    if (g_strcmp0 (g_getenv (STOCK_ENV), "1") == 0)
    {
        return;
    }

    load_css_once ();
    gtk_widget_add_css_class (GTK_WIDGET (window), "apex");
    attach_disk_footer (places_sidebar);
    attach_count_bar (window, tab_view);
}
