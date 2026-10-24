/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

#define CC_TYPE_APEX_HEADER (cc_apex_header_get_type ())
G_DECLARE_FINAL_TYPE (CcApexHeader, cc_apex_header, CC, APEX_HEADER, GtkWidget)

char *cc_apex_header_format_versions (const char *image_version, const char *shell_version,
                                      const char *session_type, const char *os_name, const char *os_version);

G_END_DECLS
