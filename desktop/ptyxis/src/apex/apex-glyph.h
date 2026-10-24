/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <gtk/gtk.h>

#include "apex-session-state.h"

G_BEGIN_DECLS

typedef enum
{
  APEX_GLYPH_NONE,
  APEX_GLYPH_RUNNING,
  APEX_GLYPH_DONE,
  APEX_GLYPH_FAILED,
  APEX_GLYPH_NEEDS_YOU,
  APEX_GLYPH_HOST,
  APEX_GLYPH_CONTAINER,
  APEX_GLYPH_REMOTE,
} ApexGlyphKind;

#define APEX_TYPE_GLYPH (apex_glyph_get_type ())

G_DECLARE_FINAL_TYPE (ApexGlyph, apex_glyph, APEX, GLYPH, GtkWidget)

GtkWidget     *apex_glyph_new            (ApexGlyphKind  kind,
                                          int            size);
void           apex_glyph_set_kind       (ApexGlyph     *self,
                                          ApexGlyphKind  kind);
ApexGlyphKind  apex_glyph_kind_for_status (ApexStatus    status);

G_END_DECLS
