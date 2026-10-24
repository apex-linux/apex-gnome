/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <adwaita.h>

#include "ptyxis-tab.h"

#include "apex-session-state.h"

G_BEGIN_DECLS

typedef enum
{
  APEX_SPLIT_NONE,
  APEX_SPLIT_RIGHT,
  APEX_SPLIT_DOWN,
} ApexSplit;

#define APEX_TYPE_SESSION (apex_session_get_type ())

G_DECLARE_FINAL_TYPE (ApexSession, apex_session, APEX, SESSION, GObject)

ApexSession *apex_session_for_tab     (PtyxisTab   *tab);
ApexSession *apex_session_for_page    (AdwTabPage  *page);
AdwTabPage  *apex_session_get_page    (ApexSession *self);
PtyxisTab   *apex_session_get_tab     (ApexSession *self);
ApexStatus   apex_session_get_status  (ApexSession *self);
ApexStatus   apex_session_get_pane_status (ApexSession *self);
const char  *apex_session_get_pane_title  (ApexSession *self);
ApexSession *apex_session_get_second  (ApexSession *self);
ApexSplit    apex_session_get_split   (ApexSession *self);
void         apex_session_set_second  (ApexSession *self,
                                       ApexSession *second,
                                       ApexSplit    split);
const char  *apex_session_get_title   (ApexSession *self);
const char  *apex_session_get_subtitle (ApexSession *self);
const char  *apex_session_get_path    (ApexSession *self);
const char  *apex_session_get_tag     (ApexSession *self);
const char  *apex_session_get_group_key   (ApexSession *self);
const char  *apex_session_get_group_label (ApexSession *self);
const char  *apex_session_get_group_pill  (ApexSession *self);
double       apex_session_get_progress    (ApexSession *self);
char        *apex_session_dup_when    (ApexSession *self);
void         apex_session_focused     (ApexSession *self);
void         apex_session_tick        (ApexSession *self);

G_END_DECLS
