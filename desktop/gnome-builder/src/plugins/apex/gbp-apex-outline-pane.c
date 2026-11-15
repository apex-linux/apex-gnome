/* SPDX-License-Identifier: GPL-3.0-or-later */

/* Boards 40 to 42's Outline view (apex's docs/design/apex-code-boards-40-42.md, section 7.2), from
 * Builder's own symbol resolvers: the focused editor's symbol tree, its current symbol marked. */

#define G_LOG_DOMAIN "gbp-apex-outline"

#include "config.h"

#include <string.h>

#include <libide-code.h>
#include <libide-editor.h>
#include <libide-gui.h>

#include "apex-i18n.h"
#include "gbp-apex-outline-pane.h"
#include "gbp-apex-sidebar.h"

#define REFRESH_DELAY_MSEC 750
#define RETRIES 6
#define INDENT_PX 14

struct _GbpApexOutlinePane
{
  IdePane       parent_instance;
  GtkLabel     *caption;
  GtkListBox   *list;
  GtkWidget    *empty;
  GSignalGroup *buffer_signals;
  GCancellable *cancellable;
  GtkWidget    *current;
  guint         refresh_source;
  guint         retries;
  guint         watching_saves : 1;
};

G_DEFINE_FINAL_TYPE (GbpApexOutlinePane, gbp_apex_outline_pane, IDE_TYPE_PANE)

typedef struct
{
  const char *text;
  const char *css_class;
} Glyph;

/* The board's glyphs: C for a class, impl for a Rust impl, fn for a Rust function, ƒ for others,
 * # for a heading and for every other kind. */
static Glyph
glyph_of (IdeSymbolKind  kind,
          const char    *name,
          const char    *language_id)
{
  gboolean rust = g_strcmp0 (language_id, "rust") == 0;

  if (rust && name != NULL && g_str_has_prefix (name, "impl "))
    return (Glyph) { "impl", "type" };

  if (kind == IDE_SYMBOL_KIND_CLASS)
    return (Glyph) { "C", "type" };
  if (kind == IDE_SYMBOL_KIND_FUNCTION || kind == IDE_SYMBOL_KIND_METHOD || kind == IDE_SYMBOL_KIND_CONSTRUCTOR)
    return (Glyph) { rust ? "fn" : "ƒ", "function" };
  if (kind == IDE_SYMBOL_KIND_HEADER)
    return (Glyph) { "#", "function" };

  return (Glyph) { "#", NULL };
}

static IdeBuffer *
buffer_of (GbpApexOutlinePane *self)
{
  return _g_signal_group_get_target (self->buffer_signals);
}

static void
set_current (GbpApexOutlinePane *self,
             GtkWidget          *row)
{
  if (self->current == row)
    return;

  if (self->current != NULL)
    {
      gtk_widget_remove_css_class (self->current, "current");
      gtk_accessible_update_state (GTK_ACCESSIBLE (self->current), GTK_ACCESSIBLE_STATE_SELECTED, FALSE, -1);
    }

  self->current = row;

  if (row != NULL)
    {
      gtk_widget_add_css_class (row, "current");
      gtk_accessible_update_state (GTK_ACCESSIBLE (row), GTK_ACCESSIBLE_STATE_SELECTED, TRUE, -1);
    }
}

/* The board's current symbol: the last row whose line is at or above the cursor's. */
static void
update_current (GbpApexOutlinePane *self)
{
  IdeBuffer *buffer = buffer_of (self);
  GtkWidget *current = NULL;
  GtkTextIter iter;
  int cursor;

  if (buffer == NULL)
    {
      set_current (self, NULL);
      return;
    }

  gtk_text_buffer_get_iter_at_mark (GTK_TEXT_BUFFER (buffer), &iter,
                                    gtk_text_buffer_get_insert (GTK_TEXT_BUFFER (buffer)));
  cursor = gtk_text_iter_get_line (&iter) + 1;

  for (GtkWidget *row = gtk_widget_get_first_child (GTK_WIDGET (self->list));
       row != NULL;
       row = gtk_widget_get_next_sibling (row))
    {
      int line = GPOINTER_TO_INT (g_object_get_data (G_OBJECT (row), "apex-line"));

      if (GTK_IS_LIST_BOX_ROW (row) && line > 0 && line <= cursor)
        current = row;
    }

  set_current (self, current);
}

typedef struct
{
  GbpApexOutlinePane *self;
  GtkWidget          *row;
  GtkLabel           *line_label;
} LocationRequest;

static void
location_cb (GObject      *object,
             GAsyncResult *result,
             gpointer      user_data)
{
  LocationRequest *request = user_data;
  g_autoptr(IdeLocation) location = NULL;
  g_autofree char *line_text = NULL;
  g_autofree char *description = NULL;
  int line;

  location = ide_symbol_node_get_location_finish (IDE_SYMBOL_NODE (object), result, NULL);

  if (location != NULL && gtk_widget_get_parent (request->row) != NULL)
    {
      line = ide_location_get_line (location) + 1;
      line_text = g_strdup_printf ("%d", line);
      description = g_strdup_printf (APEX_("Line %d"), line);
      gtk_label_set_text (request->line_label, line_text);
      gtk_accessible_update_property (GTK_ACCESSIBLE (request->row), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description, -1);
      g_object_set_data (G_OBJECT (request->row), "apex-line", GINT_TO_POINTER (line));
      g_object_set_data_full (G_OBJECT (request->row), "apex-location", g_steal_pointer (&location), g_object_unref);
      update_current (request->self);
    }

  g_object_unref (request->self);
  g_object_unref (request->row);
  g_free (request);
}

static void
add_row (GbpApexOutlinePane *self,
         IdeSymbolNode      *node,
         guint               depth,
         const char         *language_id)
{
  const char *name = ide_symbol_node_get_name (node);
  Glyph glyph = glyph_of (ide_symbol_node_get_kind (node), name, language_id);
  GtkWidget *row;
  GtkWidget *box;
  GtkWidget *kind;
  GtkWidget *label;
  GtkWidget *line;
  LocationRequest *request;

  if (g_strcmp0 (glyph.text, "impl") == 0)
    name += strlen ("impl ");

  row = g_object_new (GTK_TYPE_LIST_BOX_ROW, "accessible-role", GTK_ACCESSIBLE_ROLE_TREE_ITEM, NULL);
  box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_widget_set_margin_start (box, INDENT_PX * depth);

  kind = gtk_label_new (glyph.text);
  gtk_widget_add_css_class (kind, "glyph");
  if (glyph.css_class != NULL)
    gtk_widget_add_css_class (kind, glyph.css_class);
  gtk_label_set_xalign (GTK_LABEL (kind), 0);
  gtk_accessible_update_state (GTK_ACCESSIBLE (kind), GTK_ACCESSIBLE_STATE_HIDDEN, TRUE, -1);

  label = gtk_label_new (name);
  gtk_label_set_xalign (GTK_LABEL (label), 0);
  gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_END);
  gtk_widget_set_hexpand (label, TRUE);

  line = gtk_label_new (NULL);
  gtk_widget_add_css_class (line, "line");
  gtk_accessible_update_state (GTK_ACCESSIBLE (line), GTK_ACCESSIBLE_STATE_HIDDEN, TRUE, -1);

  gtk_box_append (GTK_BOX (box), kind);
  gtk_box_append (GTK_BOX (box), label);
  gtk_box_append (GTK_BOX (box), line);
  gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), box);
  gtk_accessible_update_property (GTK_ACCESSIBLE (row), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
  gtk_accessible_update_state (GTK_ACCESSIBLE (row), GTK_ACCESSIBLE_STATE_SELECTED, FALSE, -1);
  gtk_list_box_append (self->list, row);

  request = g_new0 (LocationRequest, 1);
  request->self = g_object_ref (self);
  request->row = g_object_ref (row);
  request->line_label = GTK_LABEL (line);
  ide_symbol_node_get_location_async (node, self->cancellable, location_cb, request);
}

/* Builder's own nesting, not the board's quirk, which indents by position. */
static void
add_rows (GbpApexOutlinePane *self,
          IdeSymbolTree      *tree,
          IdeSymbolNode      *parent,
          guint               depth,
          const char         *language_id)
{
  guint n = ide_symbol_tree_get_n_children (tree, parent);

  for (guint i = 0; i < n; i++)
    {
      g_autoptr(IdeSymbolNode) node = ide_symbol_tree_get_nth_child (tree, parent, i);

      if (node == NULL)
        continue;

      add_row (self, node, depth, language_id);
      add_rows (self, tree, node, depth + 1, language_id);
    }
}

static void queue_retry (GbpApexOutlinePane *self);

static void
show_tree (GbpApexOutlinePane *self,
           IdeSymbolTree      *tree)
{
  IdeBuffer *buffer = buffer_of (self);
  guint n = tree != NULL ? ide_symbol_tree_get_n_children (tree, NULL) : 0;

  set_current (self, NULL);
  gtk_list_box_remove_all (self->list);

  if (n > 0 && buffer != NULL)
    add_rows (self, tree, NULL, 0, ide_buffer_get_language_id (buffer));
  gtk_widget_set_visible (self->empty, n == 0 && buffer != NULL);

  g_debug ("outline: %u top-level symbols", n);

  /* A resolver can answer before its index or its server is ready (ctags, a language server). */
  if (n == 0 && buffer != NULL && ide_buffer_has_symbol_resolvers (buffer))
    queue_retry (self);
}

/* As Builder's symbol tree plugin asks: the last resolver first, then each before it. */
typedef struct
{
  GbpApexOutlinePane *self;
  GCancellable       *cancellable;
  GPtrArray          *resolvers;
  GFile              *file;
  GBytes             *contents;
} Fetch;

static void
fetch_free (Fetch *fetch)
{
  g_object_unref (fetch->self);
  g_object_unref (fetch->cancellable);
  g_ptr_array_unref (fetch->resolvers);
  g_object_unref (fetch->file);
  g_bytes_unref (fetch->contents);
  g_free (fetch);
}

static void fetch_next (Fetch *fetch);

static void
fetch_cb (GObject      *object,
          GAsyncResult *result,
          gpointer      user_data)
{
  Fetch *fetch = user_data;
  g_autoptr(IdeSymbolTree) tree = NULL;

  tree = ide_symbol_resolver_get_symbol_tree_finish (IDE_SYMBOL_RESOLVER (object), result, NULL);

  if (g_cancellable_is_cancelled (fetch->cancellable))
    {
      fetch_free (fetch);
      return;
    }

  /* Unlike Builder's symbol menu, an empty tree also falls through: ctags answers so before its first index. */
  g_ptr_array_remove_index (fetch->resolvers, fetch->resolvers->len - 1);
  if ((tree == NULL || ide_symbol_tree_get_n_children (tree, NULL) == 0) && fetch->resolvers->len > 0)
    {
      fetch_next (fetch);
      return;
    }

  show_tree (fetch->self, tree);
  fetch_free (fetch);
}

static void
fetch_next (Fetch *fetch)
{
  ide_symbol_resolver_get_symbol_tree_async (g_ptr_array_index (fetch->resolvers, fetch->resolvers->len - 1),
                                             fetch->file, fetch->contents, fetch->cancellable,
                                             fetch_cb, fetch);
}

static void
refresh (GbpApexOutlinePane *self)
{
  IdeBuffer *buffer = buffer_of (self);
  g_autoptr(GPtrArray) resolvers = NULL;
  Fetch *fetch;

  g_clear_handle_id (&self->refresh_source, g_source_remove);
  g_cancellable_cancel (self->cancellable);
  g_clear_object (&self->cancellable);
  self->cancellable = g_cancellable_new ();

  if (buffer == NULL || ide_buffer_get_file (buffer) == NULL ||
      !(resolvers = ide_buffer_get_symbol_resolvers (buffer)) || resolvers->len == 0)
    {
      show_tree (self, NULL);
      return;
    }

  IDE_PTR_ARRAY_SET_FREE_FUNC (resolvers, g_object_unref);
  fetch = g_new0 (Fetch, 1);
  fetch->self = g_object_ref (self);
  fetch->cancellable = g_object_ref (self->cancellable);
  fetch->resolvers = g_steal_pointer (&resolvers);
  fetch->file = g_object_ref (ide_buffer_get_file (buffer));
  fetch->contents = ide_buffer_dup_content (buffer);
  fetch_next (fetch);
}

static gboolean
refresh_timeout (gpointer user_data)
{
  GbpApexOutlinePane *self = user_data;

  self->refresh_source = 0;
  refresh (self);

  return G_SOURCE_REMOVE;
}

static void
queue_refresh (GbpApexOutlinePane *self)
{
  self->retries = 0;
  g_clear_handle_id (&self->refresh_source, g_source_remove);
  self->refresh_source = g_timeout_add (REFRESH_DELAY_MSEC, refresh_timeout, self);
}

/* 1, 2, 4 ... 32 s apart; an edit, or another buffer, starts over. */
static void
queue_retry (GbpApexOutlinePane *self)
{
  if (self->retries >= RETRIES || self->refresh_source != 0)
    return;

  self->refresh_source = g_timeout_add (1000u << self->retries++, refresh_timeout, self);
}

static void
update_caption (GbpApexOutlinePane *self)
{
  IdeBuffer *buffer = buffer_of (self);
  GFile *file = buffer != NULL ? ide_buffer_get_file (buffer) : NULL;
  g_autofree char *name = file != NULL ? g_file_get_basename (file) : NULL;
  g_autofree char *label = NULL;

  gtk_label_set_text (self->caption, name != NULL ? name : "");
  gtk_widget_set_visible (GTK_WIDGET (self->caption), name != NULL);
  label = name != NULL ? g_strdup_printf (APEX_("Outline of %s"), name) : g_strdup (APEX_("Outline"));
  gtk_accessible_update_property (GTK_ACCESSIBLE (self->list), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
}

static void
buffer_bind (GbpApexOutlinePane *self,
             IdeBuffer          *buffer)
{
  self->retries = 0;
  update_caption (self);
  refresh (self);
}

static void
buffer_unbind (GbpApexOutlinePane *self)
{
  update_caption (self);
  refresh (self);
}

static void
file_changed (GbpApexOutlinePane *self)
{
  update_caption (self);
  queue_refresh (self);
}

static void
row_activated (GbpApexOutlinePane *self,
               GtkListBoxRow      *row)
{
  IdeLocation *location = g_object_get_data (G_OBJECT (row), "apex-location");
  IdeWorkspace *workspace = ide_widget_get_workspace (GTK_WIDGET (self));

  if (location != NULL && workspace != NULL)
    ide_editor_focus_location (workspace, NULL, location);
}

/* ctags indexes a project after its first save, and a directory after each. */
static void
buffer_saved (GbpApexOutlinePane *self,
              IdeBuffer          *buffer)
{
  if (buffer != buffer_of (self))
    return;

  self->retries = 0;
  queue_retry (self);
}

static void
watch_saves (GbpApexOutlinePane *self)
{
  IdeContext *context = ide_widget_get_context (GTK_WIDGET (self));

  if (self->watching_saves || context == NULL)
    return;

  self->watching_saves = TRUE;
  g_signal_connect_object (ide_buffer_manager_from_context (context), "buffer-saved",
                           G_CALLBACK (buffer_saved), self, G_CONNECT_SWAPPED);
}

void
gbp_apex_outline_pane_set_page (GbpApexOutlinePane *self,
                                IdePage            *page)
{
  IdeBuffer *buffer = IDE_IS_EDITOR_PAGE (page) ? ide_editor_page_get_buffer (IDE_EDITOR_PAGE (page)) : NULL;

  g_return_if_fail (GBP_IS_APEX_OUTLINE_PANE (self));

  watch_saves (self);
  if (buffer != buffer_of (self))
    g_signal_group_set_target (self->buffer_signals, buffer);
}

GbpApexOutlinePane *
gbp_apex_outline_pane_new (void)
{
  return g_object_new (GBP_TYPE_APEX_OUTLINE_PANE,
                       "id", "apex-outline",
                       "title", APEX_("Outline"),
                       "icon-name", "view-list-symbolic",
                       NULL);
}

static void
gbp_apex_outline_pane_dispose (GObject *object)
{
  GbpApexOutlinePane *self = GBP_APEX_OUTLINE_PANE (object);

  g_clear_handle_id (&self->refresh_source, g_source_remove);
  g_cancellable_cancel (self->cancellable);
  g_clear_object (&self->cancellable);
  if (self->buffer_signals != NULL)
    g_signal_group_set_target (self->buffer_signals, NULL);
  g_clear_object (&self->buffer_signals);
  self->current = NULL;

  G_OBJECT_CLASS (gbp_apex_outline_pane_parent_class)->dispose (object);
}

static void
gbp_apex_outline_pane_class_init (GbpApexOutlinePaneClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = gbp_apex_outline_pane_dispose;
}

static void
gbp_apex_outline_pane_init (GbpApexOutlinePane *self)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *scroller = gtk_scrolled_window_new ();
  GtkWidget *placeholder = gtk_label_new (APEX_("No outline for this file"));

  gtk_widget_add_css_class (GTK_WIDGET (self), "apexoutline");
  gbp_apex_track_dark (GTK_WIDGET (self));

  self->caption = GTK_LABEL (gtk_label_new (NULL));
  gtk_widget_add_css_class (GTK_WIDGET (self->caption), "caption");
  gtk_label_set_xalign (self->caption, 0);
  gtk_label_set_ellipsize (self->caption, PANGO_ELLIPSIZE_MIDDLE);

  self->list = g_object_new (GTK_TYPE_LIST_BOX, "accessible-role", GTK_ACCESSIBLE_ROLE_TREE, NULL);
  gtk_list_box_set_selection_mode (self->list, GTK_SELECTION_NONE);
  self->empty = placeholder;
  gtk_widget_add_css_class (placeholder, "placeholder");
  gtk_label_set_xalign (GTK_LABEL (placeholder), 0);
  gtk_label_set_wrap (GTK_LABEL (placeholder), TRUE);
  gtk_widget_set_visible (placeholder, FALSE);
  g_signal_connect_object (self->list, "row-activated", G_CALLBACK (row_activated), self, G_CONNECT_SWAPPED);

  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), GTK_WIDGET (self->list));
  gtk_widget_set_vexpand (scroller, TRUE);
  gtk_widget_set_vexpand (box, TRUE);
  gtk_box_append (GTK_BOX (box), GTK_WIDGET (self->caption));
  gtk_box_append (GTK_BOX (box), placeholder);
  gtk_box_append (GTK_BOX (box), scroller);
  panel_widget_set_child (PANEL_WIDGET (self), box);

  self->buffer_signals = g_signal_group_new (IDE_TYPE_BUFFER);
  g_signal_connect_object (self->buffer_signals, "bind", G_CALLBACK (buffer_bind), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (self->buffer_signals, "unbind", G_CALLBACK (buffer_unbind), self, G_CONNECT_SWAPPED);
  g_signal_group_connect_object (self->buffer_signals, "changed", G_CALLBACK (queue_refresh), self, G_CONNECT_SWAPPED);
  g_signal_group_connect_object (self->buffer_signals, "cursor-moved", G_CALLBACK (update_current), self, G_CONNECT_SWAPPED);
  g_signal_group_connect_object (self->buffer_signals, "notify::file", G_CALLBACK (file_changed), self, G_CONNECT_SWAPPED);
  g_signal_group_connect_object (self->buffer_signals, "notify::has-symbol-resolvers", G_CALLBACK (queue_refresh), self, G_CONNECT_SWAPPED);
  update_caption (self);
}
