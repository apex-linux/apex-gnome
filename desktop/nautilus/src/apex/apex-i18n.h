/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <glib/gi18n.h>

#define APEX_GETTEXT_DOMAIN "apex-nautilus"

#undef _
#define _(String) g_dgettext (APEX_GETTEXT_DOMAIN, String)
#undef ngettext
#define ngettext(String, Plural, N) g_dngettext (APEX_GETTEXT_DOMAIN, String, Plural, N)
