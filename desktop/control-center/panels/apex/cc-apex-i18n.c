/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <config.h>

#include "cc-apex-i18n.h"

/* Bound at load, before GtkBuilder reads an Apex template's translation-domain; the panel calls it too. */
__attribute__((constructor)) void
cc_apex_i18n_init (void)
{
  bindtextdomain (CC_APEX_GETTEXT_DOMAIN, GNOMELOCALEDIR);
  bind_textdomain_codeset (CC_APEX_GETTEXT_DOMAIN, "UTF-8");
}

const char *
cc_apex_gettext (const char *msgid)
{
  return g_dgettext (CC_APEX_GETTEXT_DOMAIN, msgid);
}

const char *
cc_apex_pgettext (const char *context, const char *msgid)
{
  return g_dpgettext2 (CC_APEX_GETTEXT_DOMAIN, context, msgid);
}
