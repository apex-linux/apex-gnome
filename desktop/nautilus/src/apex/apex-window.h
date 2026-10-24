/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <adwaita.h>

G_BEGIN_DECLS

void apex_window_attach (AdwApplicationWindow *window,
                         GtkWidget            *places_sidebar,
                         GtkWidget            *tab_view);

G_END_DECLS
