/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include "apex-i18n.h"

static inline const char *
apex_code_name (void)
{
  /* TRANSLATORS: the product name; keep it as is unless your language writes it in another script */
  return APEX_("Apex Code");
}

static inline char *
apex_code_title (const char *title)
{
  /* TRANSLATORS: a window title; %s is the project or page */
  return g_strdup_printf (APEX_("Apex Code — %s"), title);
}

static inline char *
apex_code_preferences_title (const char *project_title)
{
  if (project_title != NULL)
    /* TRANSLATORS: the Preferences window's title; %s is the project */
    return g_strdup_printf (APEX_("Apex Code — %s — Preferences"), project_title);

  return g_strdup (APEX_("Apex Code — Preferences"));
}
