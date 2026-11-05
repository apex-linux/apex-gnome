/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <libide-editor.h>
#include <libide-gui.h>

G_BEGIN_DECLS

#define GBP_TYPE_APEX_WORKSPACE_ADDIN (gbp_apex_workspace_addin_get_type())
#define GBP_TYPE_APEX_EDITOR_PAGE_ADDIN (gbp_apex_editor_page_addin_get_type())

G_DECLARE_FINAL_TYPE (GbpApexWorkspaceAddin, gbp_apex_workspace_addin, GBP, APEX_WORKSPACE_ADDIN, GObject)
G_DECLARE_FINAL_TYPE (GbpApexEditorPageAddin, gbp_apex_editor_page_addin, GBP, APEX_EDITOR_PAGE_ADDIN, GObject)

G_END_DECLS
