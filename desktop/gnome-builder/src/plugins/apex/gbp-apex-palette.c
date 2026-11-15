/* SPDX-License-Identifier: GPL-3.0-or-later */

/* Board 41's palette (apex's docs/design/apex-code-boards-40-42.md, "Fuzzy file, symbol and command
 * palette"): Builder's own search engine, in the board's Files, Symbols and Commands groups. */

#define G_LOG_DOMAIN "gbp-apex-palette"

#include "config.h"

#include <string.h>

#include <adwaita.h>
#include <libide-editor.h>
#include <libide-gui.h>
#include <libide-search.h>

#include "apex-i18n.h"
#include "gbp-apex-palette.h"
#include "gbp-apex-sidebar.h"

#define MAX_PER_GROUP 4
#define SEARCH_DELAY_MSEC 80

struct _GbpApexPalette
{
  GtkPopover    parent_instance;
  IdeWorkspace *workspace;
  GtkText      *text;
  GtkLabel     *scope;
  GtkListBox   *list;
  GCancellable *cancellable;
  GPtrArray    *groups;
  guint         search_source;
  guint         pending;
};

G_DEFINE_FINAL_TYPE (GbpApexPalette, gbp_apex_palette, GTK_TYPE_POPOVER)

/* A group with no answer keeps a NULL slot. */
static void
unref0 (gpointer object)
{
  if (object != NULL)
    g_object_unref (object);
}

typedef struct
{
  IdeSearchCategory  category;
  const char        *title;
} Group;

/* The board's order, kept whatever the providers answer first. */
static const Group groups[] = {
  { IDE_SEARCH_CATEGORY_FILES, APEX_N_("Files") },
  { IDE_SEARCH_CATEGORY_SYMBOLS, APEX_N_("Symbols") },
  { IDE_SEARCH_CATEGORY_COMMANDS, APEX_N_("Commands") },
};

/* The board's match: each query letter at its first place after the last, any case; matched
 * letters in the accent at 800. */
static PangoAttrList *
highlight (const char *title,
           const char *query)
{
  PangoAttrList *attrs = pango_attr_list_new ();
  g_autoptr(GdkRGBA) accent = adw_style_manager_get_accent_color_rgba (adw_style_manager_get_default ());
  const char *q = query;

  for (const char *p = title; *p != '\0' && *q != '\0'; p = g_utf8_next_char (p))
    {
      PangoAttribute *attr;

      if (g_unichar_tolower (g_utf8_get_char (p)) != g_unichar_tolower (g_utf8_get_char (q)))
        continue;

      attr = pango_attr_foreground_new (accent->red * G_MAXUINT16, accent->green * G_MAXUINT16, accent->blue * G_MAXUINT16);
      attr->start_index = p - title;
      attr->end_index = g_utf8_next_char (p) - title;
      pango_attr_list_insert (attrs, attr);
      attr = pango_attr_weight_new (PANGO_WEIGHT_ULTRABOLD);
      attr->start_index = p - title;
      attr->end_index = g_utf8_next_char (p) - title;
      pango_attr_list_insert (attrs, attr);
      q = g_utf8_next_char (q);
    }

  return attrs;
}

static GtkWidget *
header_row (const char *title)
{
  GtkWidget *row = gtk_list_box_row_new ();
  GtkWidget *label = gtk_label_new (title);

  gtk_widget_add_css_class (row, "group");
  gtk_label_set_xalign (GTK_LABEL (label), 0);
  gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), label);
  gtk_list_box_row_set_selectable (GTK_LIST_BOX_ROW (row), FALSE);
  gtk_list_box_row_set_activatable (GTK_LIST_BOX_ROW (row), FALSE);
  gtk_accessible_update_property (GTK_ACCESSIBLE (row), GTK_ACCESSIBLE_PROPERTY_LABEL, title, -1);

  return row;
}

/* Builder's file results are titled by their path: the board names a file, its folder below. */
static void
split_path (const char  *path,
            char       **name,
            char       **folder)
{
  g_autofree char *trimmed = g_strdup (path);
  gsize len = strlen (trimmed);

  if (len > 1 && trimmed[len - 1] == '/')
    trimmed[len - 1] = '\0';
  *name = g_path_get_basename (trimmed);
  *folder = g_path_get_dirname (trimmed);
  if (g_strcmp0 (*folder, ".") == 0)
    g_clear_pointer (folder, g_free);
}

static GtkWidget *
result_row (IdeSearchResult *result,
            const char      *query,
            gboolean         is_file)
{
  GtkWidget *row = gtk_list_box_row_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *icon = gtk_image_new ();
  GtkWidget *name = gtk_label_new (NULL);
  g_autofree char *file_name = NULL;
  g_autofree char *folder = NULL;
  const char *title = ide_search_result_get_title (result);
  const char *subtitle_text = ide_search_result_get_subtitle (result);
  GtkWidget *subtitle;
  const char *accel = ide_search_result_get_accelerator (result);
  g_autofree char *label = NULL;

  if (ide_search_result_get_gicon (result) != NULL)
    gtk_image_set_from_gicon (GTK_IMAGE (icon), ide_search_result_get_gicon (result));
  gtk_widget_add_css_class (icon, "kind");
  gtk_accessible_update_state (GTK_ACCESSIBLE (icon), GTK_ACCESSIBLE_STATE_HIDDEN, TRUE, -1);

  if (is_file && title != NULL && !ide_search_result_get_use_markup (result))
    {
      split_path (title, &file_name, &folder);
      title = file_name;
      subtitle_text = folder;
    }
  subtitle = gtk_label_new (subtitle_text);

  /* A provider's markup is its own: drawn as given, without the match. */
  if (ide_search_result_get_use_markup (result))
    gtk_label_set_markup (GTK_LABEL (name), title);
  else
    {
      PangoAttrList *attrs = highlight (title, query);

      gtk_label_set_text (GTK_LABEL (name), title);
      gtk_label_set_attributes (GTK_LABEL (name), attrs);
      pango_attr_list_unref (attrs);
    }
  gtk_widget_add_css_class (name, "name");

  gtk_widget_add_css_class (subtitle, "subtitle");
  gtk_label_set_xalign (GTK_LABEL (subtitle), 0);
  gtk_label_set_ellipsize (GTK_LABEL (subtitle), PANGO_ELLIPSIZE_END);
  gtk_widget_set_hexpand (subtitle, TRUE);
  gtk_widget_set_visible (subtitle, subtitle_text != NULL);

  gtk_box_append (GTK_BOX (box), icon);
  gtk_box_append (GTK_BOX (box), name);
  gtk_box_append (GTK_BOX (box), subtitle);
  if (accel != NULL && accel[0] != '\0')
    {
      GtkWidget *chip = gtk_label_new (accel);

      gtk_widget_add_css_class (chip, "chip");
      gtk_box_append (GTK_BOX (box), chip);
    }

  gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), box);
  label = subtitle_text != NULL
        ? g_strdup_printf ("%s, %s", gtk_label_get_text (GTK_LABEL (name)), subtitle_text)
        : g_strdup (gtk_label_get_text (GTK_LABEL (name)));
  gtk_accessible_update_property (GTK_ACCESSIBLE (row), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
  gtk_accessible_update_state (GTK_ACCESSIBLE (row), GTK_ACCESSIBLE_STATE_SELECTED, FALSE, -1);
  g_object_set_data_full (G_OBJECT (row), "apex-result", g_object_ref (result), g_object_unref);

  return row;
}

static void
mark_selected (GbpApexPalette *self)
{
  GtkListBoxRow *selected = gtk_list_box_get_selected_row (self->list);

  for (GtkWidget *row = gtk_widget_get_first_child (GTK_WIDGET (self->list)); row; row = gtk_widget_get_next_sibling (row))
    if (GTK_IS_LIST_BOX_ROW (row) && gtk_list_box_row_get_selectable (GTK_LIST_BOX_ROW (row)))
      gtk_accessible_update_state (GTK_ACCESSIBLE (row), GTK_ACCESSIBLE_STATE_SELECTED, row == (GtkWidget *) selected, -1);
}

static void
select_first (GbpApexPalette *self)
{
  for (GtkWidget *row = gtk_widget_get_first_child (GTK_WIDGET (self->list)); row; row = gtk_widget_get_next_sibling (row))
    if (GTK_IS_LIST_BOX_ROW (row) && gtk_list_box_row_get_selectable (GTK_LIST_BOX_ROW (row)))
      {
        gtk_list_box_select_row (self->list, GTK_LIST_BOX_ROW (row));
        break;
      }

  mark_selected (self);
}

static void
clear (GbpApexPalette *self)
{
  gtk_list_box_remove_all (self->list);
}

static void
show_empty (GbpApexPalette *self,
            const char     *query)
{
  g_autofree char *text = g_strdup_printf (APEX_("No results for “%s”"), query);
  GtkWidget *row = header_row (text);

  gtk_widget_remove_css_class (row, "group");
  gtk_widget_add_css_class (row, "empty");
  gtk_list_box_append (self->list, row);
}

/* The groups answer in any order; they are shown once all have, in the board's order. */
static void
show_groups (GbpApexPalette *self,
             const char     *query)
{
  gboolean any = FALSE;

  clear (self);
  for (guint i = 0; i < self->groups->len; i++)
    {
      GListModel *results = g_ptr_array_index (self->groups, i);
      guint n = results != NULL ? MIN (g_list_model_get_n_items (results), MAX_PER_GROUP) : 0;

      if (n == 0)
        continue;

      any = TRUE;
      gtk_list_box_append (self->list, header_row (APEX_(groups[i].title)));
      for (guint j = 0; j < n; j++)
        {
          g_autoptr(IdeSearchResult) result = g_list_model_get_item (results, j);

          gtk_list_box_append (self->list, result_row (result, query, groups[i].category == IDE_SEARCH_CATEGORY_FILES));
        }
    }

  if (!any)
    show_empty (self, query);

  select_first (self);
  g_debug ("palette: results for %s", query);
}

typedef struct
{
  GbpApexPalette *self;
  GCancellable   *cancellable;
  guint           index;
  char           *query;
} Search;

static void
search_cb (GObject      *object,
           GAsyncResult *result,
           gpointer      user_data)
{
  Search *search = user_data;
  g_autoptr(IdeSearchResults) results = ide_search_engine_search_finish (IDE_SEARCH_ENGINE (object), result, NULL);

  if (!g_cancellable_is_cancelled (search->cancellable))
    {
      g_ptr_array_index (search->self->groups, search->index) = results != NULL ? g_object_ref (results) : NULL;
      if (--search->self->pending == 0)
        show_groups (search->self, search->query);
    }

  g_object_unref (search->self);
  g_object_unref (search->cancellable);
  g_free (search->query);
  g_free (search);
}

/* ":N" goes to line N of the page in front. */
static void
show_line (GbpApexPalette *self,
           const char     *number)
{
  g_autofree char *text = NULL;
  GtkWidget *row = gtk_list_box_row_new ();
  GtkWidget *label;
  guint64 line;

  if (!g_ascii_string_to_unsigned (number, 10, 1, G_MAXINT, &line, NULL))
    {
      show_empty (self, number);
      return;
    }

  text = g_strdup_printf (APEX_("Go to line %u"), (guint) line);
  label = gtk_label_new (text);
  gtk_label_set_xalign (GTK_LABEL (label), 0);
  gtk_widget_add_css_class (label, "name");
  gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), label);
  gtk_accessible_update_property (GTK_ACCESSIBLE (row), GTK_ACCESSIBLE_PROPERTY_LABEL, text, -1);
  g_object_set_data (G_OBJECT (row), "apex-line", GUINT_TO_POINTER ((guint) line));
  gtk_list_box_append (self->list, row);
  select_first (self);
}

static gboolean
run_search (gpointer user_data)
{
  GbpApexPalette *self = user_data;
  const char *text = gtk_editable_get_text (GTK_EDITABLE (self->text));
  IdeSearchEngine *engine = ide_workbench_get_search_engine (ide_widget_get_workbench (GTK_WIDGET (self->workspace)));
  const char *query = text;
  int only = -1;

  self->search_source = 0;
  g_cancellable_cancel (self->cancellable);
  g_clear_object (&self->cancellable);
  g_ptr_array_set_size (self->groups, 0);
  g_ptr_array_set_size (self->groups, G_N_ELEMENTS (groups));
  clear (self);

  if (text[0] == '>' || text[0] == '@')
    {
      only = text[0] == '>' ? 2 : 1;
      query = text + 1;
    }
  else if (text[0] == ':')
    {
      show_line (self, text + 1);
      return G_SOURCE_REMOVE;
    }

  gtk_label_set_text (self->scope, only == 2 ? APEX_("Commands") : only == 1 ? APEX_("Symbols") : APEX_("Files, symbols and commands"));
  if (query[0] == '\0' || engine == NULL)
    return G_SOURCE_REMOVE;

  self->cancellable = g_cancellable_new ();
  self->pending = 0;
  for (guint i = 0; i < G_N_ELEMENTS (groups); i++)
    {
      Search *search;

      if (only >= 0 && (guint) only != i)
        continue;

      search = g_new0 (Search, 1);
      search->self = g_object_ref (self);
      search->cancellable = g_object_ref (self->cancellable);
      search->index = i;
      search->query = g_strdup (query);
      self->pending++;
      ide_search_engine_search_async (engine, groups[i].category, query, MAX_PER_GROUP, self->cancellable, search_cb, search);
    }

  return G_SOURCE_REMOVE;
}

static void
text_changed (GbpApexPalette *self)
{
  g_clear_handle_id (&self->search_source, g_source_remove);
  self->search_source = g_timeout_add (SEARCH_DELAY_MSEC, run_search, self);
}

static void
activate_row (GbpApexPalette *self,
              GtkListBoxRow  *row)
{
  IdeSearchResult *result = g_object_get_data (G_OBJECT (row), "apex-result");
  guint line = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (row), "apex-line"));
  IdeWorkspace *workspace = self->workspace;
  IdePage *page;

  gtk_popover_popdown (GTK_POPOVER (self));

  if (result != NULL)
    ide_search_result_activate (result, GTK_WIDGET (workspace));
  else if (line > 0 && (page = ide_workspace_get_most_recent_page (workspace)) && IDE_IS_EDITOR_PAGE (page))
    {
      g_autoptr(IdeLocation) location = ide_location_new (ide_editor_page_get_file (IDE_EDITOR_PAGE (page)), line - 1, 0);

      ide_editor_focus_location (workspace, NULL, location);
    }
}

/* Up and Down move over the results, the headers skipped; Enter opens. */
static gboolean
key_pressed (GbpApexPalette  *self,
             guint            keyval,
             guint            keycode,
             GdkModifierType  state)
{
  GtkListBoxRow *selected = gtk_list_box_get_selected_row (self->list);
  GtkWidget *row;

  if (keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter || keyval == GDK_KEY_ISO_Enter)
    {
      if (selected != NULL)
        activate_row (self, selected);
      return TRUE;
    }

  if (keyval != GDK_KEY_Down && keyval != GDK_KEY_Up)
    return FALSE;

  row = selected != NULL ? GTK_WIDGET (selected) : NULL;
  do
    row = row == NULL ? gtk_widget_get_first_child (GTK_WIDGET (self->list))
        : keyval == GDK_KEY_Down ? gtk_widget_get_next_sibling (row) : gtk_widget_get_prev_sibling (row);
  while (row != NULL && !(GTK_IS_LIST_BOX_ROW (row) && gtk_list_box_row_get_selectable (GTK_LIST_BOX_ROW (row))));

  if (row != NULL)
    {
      gtk_list_box_select_row (self->list, GTK_LIST_BOX_ROW (row));
      gtk_widget_grab_focus (GTK_WIDGET (self->text));
      mark_selected (self);
    }

  return TRUE;
}

static void
popup (GbpApexPalette *self)
{
  GtkWidget *bar = GTK_WIDGET (ide_workspace_get_header_bar (self->workspace));
  GdkRectangle rect = { gtk_widget_get_width (bar) / 2, gtk_widget_get_height (bar) - 1, 1, 1 };

  gtk_popover_set_pointing_to (GTK_POPOVER (self), &rect);
  gtk_editable_set_text (GTK_EDITABLE (self->text), "");
  clear (self);
  gtk_popover_popup (GTK_POPOVER (self));
  gtk_widget_grab_focus (GTK_WIDGET (self->text));
}

static gboolean
open_palette (GtkWidget *widget,
              GVariant  *args,
              gpointer   user_data)
{
  popup (GBP_APEX_PALETTE (user_data));
  return TRUE;
}

void
gbp_apex_palette_install (IdeWorkspace *workspace)
{
  GbpApexPalette *self;
  GtkEventController *controller;
  IdeHeaderBar *bar;

  g_return_if_fail (IDE_IS_WORKSPACE (workspace));

  if (!(bar = ide_workspace_get_header_bar (workspace)))
    return;

  self = g_object_new (GBP_TYPE_APEX_PALETTE, NULL);
  self->workspace = workspace;
  gtk_widget_set_parent (GTK_WIDGET (self), GTK_WIDGET (bar));

  /* Before the editor: its keybindings would take Ctrl+K first. */
  controller = gtk_shortcut_controller_new ();
  gtk_event_controller_set_propagation_phase (controller, GTK_PHASE_CAPTURE);
  gtk_shortcut_controller_add_shortcut (GTK_SHORTCUT_CONTROLLER (controller),
                                        gtk_shortcut_new (gtk_shortcut_trigger_parse_string ("<Control>k"),
                                                          gtk_callback_action_new (open_palette, self, NULL)));
  gtk_widget_add_controller (GTK_WIDGET (workspace), controller);
}

static void
gbp_apex_palette_dispose (GObject *object)
{
  GbpApexPalette *self = GBP_APEX_PALETTE (object);

  g_clear_handle_id (&self->search_source, g_source_remove);
  g_cancellable_cancel (self->cancellable);
  g_clear_object (&self->cancellable);
  g_clear_pointer (&self->groups, g_ptr_array_unref);
  self->workspace = NULL;

  G_OBJECT_CLASS (gbp_apex_palette_parent_class)->dispose (object);
}

static void
gbp_apex_palette_class_init (GbpApexPaletteClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = gbp_apex_palette_dispose;
}

static GtkWidget *
footer_label (const char *text)
{
  GtkWidget *label = gtk_label_new (text);

  gtk_widget_add_css_class (label, "hint");
  return label;
}

static void
gbp_apex_palette_init (GbpApexPalette *self)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *input = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *footer = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 16);
  GtkWidget *modes = footer_label (APEX_("> commands only · @ symbols · : line"));
  GtkEventController *keys = gtk_event_controller_key_new ();

  self->groups = g_ptr_array_new_with_free_func (unref0);

  gtk_widget_add_css_class (GTK_WIDGET (self), "apexpalette");
  gtk_popover_set_has_arrow (GTK_POPOVER (self), FALSE);
  gtk_popover_set_position (GTK_POPOVER (self), GTK_POS_BOTTOM);
  gtk_popover_set_offset (GTK_POPOVER (self), 0, 10);
  gtk_accessible_update_property (GTK_ACCESSIBLE (self), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  APEX_("Search files, symbols and commands"), -1);
  gbp_apex_track_dark (GTK_WIDGET (self));

  gtk_widget_add_css_class (input, "input");
  gtk_box_append (GTK_BOX (input), gtk_image_new_from_icon_name ("system-search-symbolic"));
  /* A bare GtkText has no role of its own: the entry's, so a reader finds the field. */
  self->text = g_object_new (GTK_TYPE_TEXT, "accessible-role", GTK_ACCESSIBLE_ROLE_TEXT_BOX, NULL);
  gtk_widget_set_hexpand (GTK_WIDGET (self->text), TRUE);
  gtk_accessible_update_property (GTK_ACCESSIBLE (self->text), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  APEX_("Search files, symbols and commands"), -1);
  g_signal_connect_object (self->text, "changed", G_CALLBACK (text_changed), self, G_CONNECT_SWAPPED);
  gtk_event_controller_set_propagation_phase (keys, GTK_PHASE_CAPTURE);
  g_signal_connect_object (keys, "key-pressed", G_CALLBACK (key_pressed), self, G_CONNECT_SWAPPED);
  gtk_widget_add_controller (GTK_WIDGET (self->text), keys);
  gtk_box_append (GTK_BOX (input), GTK_WIDGET (self->text));
  self->scope = GTK_LABEL (gtk_label_new (APEX_("Files, symbols and commands")));
  gtk_widget_add_css_class (GTK_WIDGET (self->scope), "scope");
  gtk_box_append (GTK_BOX (input), GTK_WIDGET (self->scope));

  self->list = GTK_LIST_BOX (gtk_list_box_new ());
  gtk_list_box_set_selection_mode (self->list, GTK_SELECTION_SINGLE);
  gtk_accessible_update_property (GTK_ACCESSIBLE (self->list), GTK_ACCESSIBLE_PROPERTY_LABEL, APEX_("Results"), -1);
  g_signal_connect_object (self->list, "row-activated", G_CALLBACK (activate_row), self, G_CONNECT_SWAPPED);

  gtk_widget_add_css_class (footer, "footer");
  gtk_box_append (GTK_BOX (footer), footer_label (APEX_("↑↓ to move")));
  gtk_box_append (GTK_BOX (footer), footer_label (APEX_("Enter to open")));
  gtk_box_append (GTK_BOX (footer), footer_label (APEX_("Esc to close")));
  gtk_widget_set_hexpand (modes, TRUE);
  gtk_label_set_xalign (GTK_LABEL (modes), 1);
  gtk_box_append (GTK_BOX (footer), modes);

  gtk_box_append (GTK_BOX (box), input);
  gtk_box_append (GTK_BOX (box), GTK_WIDGET (self->list));
  gtk_box_append (GTK_BOX (box), footer);
  gtk_widget_set_size_request (box, 600, -1);
  gtk_popover_set_child (GTK_POPOVER (self), box);
}
