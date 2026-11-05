/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "config.h"

#include <libpeas.h>
#include <libide-editor.h>
#include <libide-gui.h>

#include "gbp-apex-a11y-addins.h"
#include "gbp-apex-workbench-addin.h"

_IDE_EXTERN void
_gbp_apex_register_types (PeasObjectModule *module)
{
  peas_object_module_register_extension_type (module,
                                              IDE_TYPE_WORKBENCH_ADDIN,
                                              GBP_TYPE_APEX_WORKBENCH_ADDIN);
  peas_object_module_register_extension_type (module,
                                              IDE_TYPE_WORKSPACE_ADDIN,
                                              GBP_TYPE_APEX_WORKSPACE_ADDIN);
  peas_object_module_register_extension_type (module,
                                              IDE_TYPE_EDITOR_PAGE_ADDIN,
                                              GBP_TYPE_APEX_EDITOR_PAGE_ADDIN);
}
