/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <glib.h>
#include <libintl.h>

#define APEX_GETTEXT_DOMAIN "apex-builder"

/* Header-only, so libide's hook hunks need no link dependency on the plugin.
 * libc's dgettext: g_dgettext leaves every domain untranslated while Builder's own has no catalogue for the locale, as for vi. */
G_GNUC_FORMAT (1) static inline const char *
apex_gettext (const char *msgid)
{
  static gsize bound = 0;

  if (g_once_init_enter (&bound))
    {
      bindtextdomain (APEX_GETTEXT_DOMAIN, LOCALEDIR);
      bind_textdomain_codeset (APEX_GETTEXT_DOMAIN, "UTF-8");
      g_once_init_leave (&bound, 1);
    }

  return dgettext (APEX_GETTEXT_DOMAIN, msgid);
}

#define APEX_(String) apex_gettext (String)
#define APEX_N_(String) (String)
