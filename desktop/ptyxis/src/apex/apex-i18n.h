/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <glib/gi18n.h>
#include <libintl.h>

#define APEX_GETTEXT_DOMAIN "apex-ptyxis"

#undef _
#define _(String) dgettext (APEX_GETTEXT_DOMAIN, String)
#undef ngettext
#define ngettext(String, Plural, N) dngettext (APEX_GETTEXT_DOMAIN, String, Plural, N)
