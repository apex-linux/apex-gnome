/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex.h"
#include "apex-i18n.h"

#include "apex/apex-resources.h"

void
apex_files_init (void)
{
    bind_textdomain_codeset (APEX_GETTEXT_DOMAIN, "UTF-8");
    apex_register_resource ();
}
