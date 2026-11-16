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
  guint         stale : 1;
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
  int best = 0;

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

      /* The nearest line wins, whatever order the rows are in. */
      if (GTK_IS_LIST_BOX_ROW (row) && line > 0 && line <= cursor && line >= best)
        {
          best = line;
          current = row;
        }
    }

  set_current (self, current);
}

/* A symbol and its children, with the line its location resolved to. */
typedef struct
{
  IdeSymbolNode *node;
  IdeLocation   *location;
  GPtrArray     *children;
  guint          depth;
  int            line;
} Item;

static void
item_free (Item *item)
{
  g_clear_object (&item->node);
  g_clear_object (&item->location);
  g_clear_pointer (&item->children, g_ptr_array_unref);
  g_free (item);
}

/* Builder's own nesting, not the board's quirk, which indents by position. */
static void
collect (IdeSymbolTree *tree,
         IdeSymbolNode *parent,
         guint          depth,
         GPtrArray     *into,
         GPtrArray     *flat)
{
  guint n = ide_symbol_tree_get_n_children (tree, parent);

  for (guint i = 0; i < n; i++)
    {
      IdeSymbolNode *node = ide_symbol_tree_get_nth_child (tree, parent, i);
      Item *item;

      if (node == NULL)
        continue;

      item = g_new0 (Item, 1);
      item->node = node;
      item->depth = depth;
      item->children = g_ptr_array_new_with_free_func ((GDestroyNotify) item_free);
      g_ptr_array_add (into, item);
      g_ptr_array_add (flat, item);
      collect (tree, node, depth + 1, item->children, flat);
    }
}

/* ctags answers in name order: siblings go in line order, unresolved ones last as they came. */
static int
compare_items (gconstpointer a,
               gconstpointer b,
               gpointer      user_data)
{
  const Item *x = a;
  const Item *y = b;
  guint lx = x->line > 0 ? (guint) x->line : G_MAXUINT;
  guint ly = y->line > 0 ? (guint) y->line : G_MAXUINT;

  return lx < ly ? -1 : lx > ly;
}

static void
sort_items (GPtrArray *items)
{
  g_ptr_array_sort_values_with_data (items, compare_items, NULL);
  for (guint i = 0; i < items->len; i++)
    sort_items (((Item *) g_ptr_array_index (items, i))->children);
}

static const char *
kind_name (IdeSymbolKind kind,
           gboolean      impl)
{
  static const struct { IdeSymbolKind kind; const char *name; } names[] = {
    { IDE_SYMBOL_KIND_CLASS, APEX_N_("Class") },
    { IDE_SYMBOL_KIND_STRUCT, APEX_N_("Struct") },
    { IDE_SYMBOL_KIND_ENUM, APEX_N_("Enum") },
    { IDE_SYMBOL_KIND_INTERFACE, APEX_N_("Interface") },
    { IDE_SYMBOL_KIND_FUNCTION, APEX_N_("Function") },
    { IDE_SYMBOL_KIND_METHOD, APEX_N_("Method") },
    { IDE_SYMBOL_KIND_CONSTRUCTOR, APEX_N_("Constructor") },
    { IDE_SYMBOL_KIND_HEADER, APEX_N_("Heading") },
    /* ctags's kind for a member, a Python or JavaScript method among them. */
    { IDE_SYMBOL_KIND_FIELD, APEX_N_("Field") },
    { IDE_SYMBOL_KIND_VARIABLE, APEX_N_("Variable") },
    { IDE_SYMBOL_KIND_CONSTANT, APEX_N_("Constant") },
  };

  if (impl)
    return APEX_("Implementation");
  for (guint i = 0; i < G_N_ELEMENTS (names); i++)
    if (names[i].kind == kind)
      return APEX_(names[i].name);

  return APEX_("Symbol");
}

static void
add_row (GbpApexOutlinePane *self,
         Item               *item,
         const char         *language_id)
{
  const char *full = ide_symbol_node_get_name (item->node);
  const char *name = full;
  IdeSymbolKind kind_id = ide_symbol_node_get_kind (item->node);
  Glyph glyph = glyph_of (kind_id, name, language_id);
  gboolean impl = g_strcmp0 (glyph.text, "impl") == 0;
  g_autofree char *line_text = NULL;
  g_autofree char *description = NULL;
  GtkWidget *row;
  GtkWidget *box;
  GtkWidget *kind;
  GtkWidget *label;
  GtkWidget *line;

  if (impl)
    name += strlen ("impl ");

  row = g_object_new (GTK_TYPE_LIST_BOX_ROW, "accessible-role", GTK_ACCESSIBLE_ROLE_TREE_ITEM, NULL);
  box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_widget_set_margin_start (box, INDENT_PX * item->depth);

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

  line_text = item->line > 0 ? g_strdup_printf ("%d", item->line) : NULL;
  line = gtk_label_new (line_text);
  gtk_widget_add_css_class (line, "line");
  gtk_accessible_update_state (GTK_ACCESSIBLE (line), GTK_ACCESSIBLE_STATE_HIDDEN, TRUE, -1);

  /* TRANSLATORS: an Outline item's description: the symbol's kind (Class, Function...) and its line. */
  description = item->line > 0 ? g_strdup_printf (APEX_("%s, line %d"), kind_name (kind_id, impl), item->line)
                               : g_strdup (kind_name (kind_id, impl));

  gtk_box_append (GTK_BOX (box), kind);
  gtk_box_append (GTK_BOX (box), label);
  gtk_box_append (GTK_BOX (box), line);
  gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), box);
  /* The glyph is hidden from AT: the full name ("impl Engine") and the kind say it. */
  gtk_accessible_update_property (GTK_ACCESSIBLE (row),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL, full,
                                  GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description,
                                  GTK_ACCESSIBLE_PROPERTY_LEVEL, (int) item->depth + 1,
                                  -1);
  gtk_accessible_update_state (GTK_ACCESSIBLE (row), GTK_ACCESSIBLE_STATE_SELECTED, FALSE, -1);
  g_object_set_data (G_OBJECT (row), "apex-line", GINT_TO_POINTER (item->line));
  if (item->location != NULL)
    g_object_set_data_full (G_OBJECT (row), "apex-location", g_object_ref (item->location), g_object_unref);
  gtk_list_box_append (self->list, row);
}

static void
add_rows (GbpApexOutlinePane *self,
          GPtrArray          *items,
          const char         *language_id)
{
  for (guint i = 0; i < items->len; i++)
    {
      Item *item = g_ptr_array_index (items, i);

      add_row (self, item, language_id);
      add_rows (self, item->children, language_id);
    }
}

static void queue_retry (GbpApexOutlinePane *self);

/* The rows go all at once, once every line is known; keyboard focus stays on the same row. */
static void
show_items (GbpApexOutlinePane *self,
            GPtrArray          *items,
            const char         *language_id)
{
  GtkWidget *focus = gtk_widget_get_focus_child (GTK_WIDGET (self->list));
  int focused = GTK_IS_LIST_BOX_ROW (focus) ? gtk_list_box_row_get_index (GTK_LIST_BOX_ROW (focus)) : -1;
  IdeBuffer *buffer = buffer_of (self);
  GtkListBoxRow *row = NULL;

  set_current (self, NULL);
  gtk_list_box_remove_all (self->list);
  if (items != NULL)
    add_rows (self, items, language_id);
  gtk_widget_set_visible (self->empty, (items == NULL || items->len == 0) && buffer != NULL);

  for (int i = focused; i >= 0 && !(row = gtk_list_box_get_row_at_index (self->list, i)); i--)
    ;
  if (focused >= 0 && row != NULL)
    gtk_widget_grab_focus (GTK_WIDGET (row));

  update_current (self);
}

/* One location at a time: ctags slices the whole buffer on the main thread for each. */
typedef struct
{
  GbpApexOutlinePane *self;
  GCancellable       *cancellable;
  GPtrArray          *items;
  GPtrArray          *flat;
  char               *language_id;
  guint               next;
} Resolve;

static void
resolve_free (Resolve *resolve)
{
  g_object_unref (resolve->self);
  g_object_unref (resolve->cancellable);
  g_ptr_array_unref (resolve->items);
  g_ptr_array_unref (resolve->flat);
  g_free (resolve->language_id);
  g_free (resolve);
}

static void resolve_next (Resolve *resolve);

static void
location_cb (GObject      *object,
             GAsyncResult *result,
             gpointer      user_data)
{
  Resolve *resolve = user_data;
  Item *item = g_ptr_array_index (resolve->flat, resolve->next);

  item->location = ide_symbol_node_get_location_finish (IDE_SYMBOL_NODE (object), result, NULL);
  if (g_cancellable_is_cancelled (resolve->cancellable))
    {
      resolve_free (resolve);
      return;
    }

  item->line = item->location != NULL ? (int) ide_location_get_line (item->location) + 1 : 0;
  resolve->next++;
  resolve_next (resolve);
}

static void
resolve_next (Resolve *resolve)
{
  if (resolve->next < resolve->flat->len)
    {
      Item *item = g_ptr_array_index (resolve->flat, resolve->next);

      ide_symbol_node_get_location_async (item->node, resolve->cancellable, location_cb, resolve);
      return;
    }

  sort_items (resolve->items);
  show_items (resolve->self, resolve->items, resolve->language_id);
  resolve_free (resolve);
}

static void
show_tree (GbpApexOutlinePane *self,
           IdeSymbolTree      *tree,
           GObject            *resolver)
{
  IdeBuffer *buffer = buffer_of (self);
  guint n = tree != NULL ? ide_symbol_tree_get_n_children (tree, NULL) : 0;
  Resolve *resolve;

  g_debug ("outline: %u top-level symbols from %s", n, resolver != NULL ? G_OBJECT_TYPE_NAME (resolver) : "none");

  if (n == 0 || buffer == NULL)
    {
      show_items (self, NULL, NULL);
      /* A resolver can answer before its index or its server is ready (ctags, a language server). */
      if (buffer != NULL && ide_buffer_has_symbol_resolvers (buffer))
        queue_retry (self);
      return;
    }

  resolve = g_new0 (Resolve, 1);
  resolve->self = g_object_ref (self);
  resolve->cancellable = g_object_ref (self->cancellable);
  resolve->items = g_ptr_array_new_with_free_func ((GDestroyNotify) item_free);
  resolve->flat = g_ptr_array_new ();
  resolve->language_id = g_strdup (ide_buffer_get_language_id (buffer));
  collect (tree, NULL, 0, resolve->items, resolve->flat);
  resolve_next (resolve);
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

  show_tree (fetch->self, tree, object);
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

  /* Hidden, as it is behind Project by default: refreshed when it is next shown. */
  self->stale = !gtk_widget_get_mapped (GTK_WIDGET (self));
  if (self->stale)
    return;

  if (buffer == NULL || ide_buffer_get_file (buffer) == NULL ||
      !(resolvers = ide_buffer_get_symbol_resolvers (buffer)) || resolvers->len == 0)
    {
      show_tree (self, NULL, NULL);
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
mapped (GbpApexOutlinePane *self)
{
  if (self->stale)
    refresh (self);
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
  /* Only an empty outline: a rebuild would take keyboard focus off its row, at every autosave too. */
  if (buffer != buffer_of (self) || gtk_widget_get_first_child (GTK_WIDGET (self->list)) != NULL)
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
  g_signal_connect (self, "map", G_CALLBACK (mapped), NULL);

  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), GTK_WIDGET (self->list));
  gtk_widget_set_vexpand (scroller, TRUE);
  gtk_widget_set_vexpand (box, TRUE);
  gtk_box_append (GTK_BOX (box), GTK_WIDGET (self->caption));
  gtk_box_append (GTK_BOX (box), placeholder);
  gtk_box_append (GTK_BOX (box), scroller);
  panel_widget_set_child (PANEL_WIDGET (self), box);

  self->stale = TRUE;
  self->buffer_signals = g_signal_group_new (IDE_TYPE_BUFFER);
  g_signal_connect_object (self->buffer_signals, "bind", G_CALLBACK (buffer_bind), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (self->buffer_signals, "unbind", G_CALLBACK (buffer_unbind), self, G_CONNECT_SWAPPED);
  g_signal_group_connect_object (self->buffer_signals, "changed", G_CALLBACK (queue_refresh), self, G_CONNECT_SWAPPED);
  g_signal_group_connect_object (self->buffer_signals, "cursor-moved", G_CALLBACK (update_current), self, G_CONNECT_SWAPPED);
  g_signal_group_connect_object (self->buffer_signals, "notify::file", G_CALLBACK (file_changed), self, G_CONNECT_SWAPPED);
  g_signal_group_connect_object (self->buffer_signals, "notify::has-symbol-resolvers", G_CALLBACK (queue_refresh), self, G_CONNECT_SWAPPED);
  update_caption (self);
}
