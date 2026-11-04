/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

/* Apex strings live in their own domain: upstream's catalogue stays upstream's. */
#include <glib/gi18n.h>

#define CC_APEX_GETTEXT_DOMAIN "apex-control-center"

/* Through functions, so every user links cc-apex-i18n.o, whose constructor binds the domain. */
#undef _
#undef C_
#define _(String) cc_apex_gettext (String)
#define C_(Context, String) cc_apex_pgettext (Context, String)

void cc_apex_i18n_init (void);
const char *cc_apex_gettext (const char *msgid);
const char *cc_apex_pgettext (const char *context, const char *msgid);
