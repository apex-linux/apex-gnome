/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "apex-glyph.h"

#define GRID 16.0
#define STROKE_WIDTH 1.75
#define TRACK_ALPHA 0.28
#define SPIN_PERIOD_USEC (1100 * 1000)

#define RING "M2.25 8a5.75 5.75 0 1 0 11.5 0a5.75 5.75 0 1 0-11.5 0z"

typedef struct
{
  const char *css_class;
  const char *stroke;
  const char *fill;
  const char *cut;
  const char *track;
} GlyphPaths;

static const GlyphPaths glyphs[] = {
  [APEX_GLYPH_NONE] = { "none" },
  [APEX_GLYPH_RUNNING] = { "running", "M8 2.25a5.75 5.75 0 0 1 5.75 5.75", NULL, NULL, RING },
  [APEX_GLYPH_DONE] = { "done", "M3.25 8.4l3 3 6.5-6.65" },
  [APEX_GLYPH_FAILED] = { "failed", NULL, "M1.75 8a6.25 6.25 0 1 0 12.5 0a6.25 6.25 0 1 0-12.5 0z",
                          "M5.9 5.9l4.2 4.2M10.1 5.9l-4.2 4.2" },
  [APEX_GLYPH_NEEDS_YOU] = { "needs-you", RING, "M5.6 8a2.4 2.4 0 1 0 4.8 0a2.4 2.4 0 1 0-4.8 0z" },
  [APEX_GLYPH_HOST] = { "host", "M3 3h10a1.5 1.5 0 0 1 1.5 1.5v6A1.5 1.5 0 0 1 13 12H3a1.5 1.5 0 0 1-1.5-1.5v-6A1.5 1.5 0 0 1 3 3zM5.5 14h5" },
  [APEX_GLYPH_CONTAINER] = { "container", "M8 1.75l5.4 3.12v6.26L8 14.25l-5.4-3.12V4.87z" },
  [APEX_GLYPH_REMOTE] = { "remote",
                          "M3 2.5h10a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1v-3a1 1 0 0 1 1-1zM3 8.5h10a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1v-3a1 1 0 0 1 1-1z",
                          "M4.1 5a.9.9 0 1 0 1.8 0a.9.9 0 1 0-1.8 0zM4.1 11a.9.9 0 1 0 1.8 0a.9.9 0 1 0-1.8 0z" },
};

struct _ApexGlyph
{
  GtkWidget      parent_instance;
  ApexGlyphKind  kind;
  int            size;
  guint          tick_id;
  double         angle;
};

G_DEFINE_FINAL_TYPE (ApexGlyph, apex_glyph, GTK_TYPE_WIDGET)

static GskStroke *
glyph_stroke (void)
{
  GskStroke *stroke = gsk_stroke_new (STROKE_WIDTH);

  gsk_stroke_set_line_cap (stroke, GSK_LINE_CAP_ROUND);
  gsk_stroke_set_line_join (stroke, GSK_LINE_JOIN_ROUND);
  return stroke;
}

static void
append_path (GtkSnapshot   *snapshot,
             const char    *svg,
             const GdkRGBA *color,
             gboolean       stroked)
{
  g_autoptr(GskPath) path = NULL;

  if (svg == NULL || !(path = gsk_path_parse (svg)))
    return;

  if (stroked)
    {
      g_autoptr(GskStroke) stroke = glyph_stroke ();
      gtk_snapshot_append_stroke (snapshot, path, stroke, color);
    }
  else
    gtk_snapshot_append_fill (snapshot, path, GSK_FILL_RULE_WINDING, color);
}

static void
apex_glyph_snapshot (GtkWidget   *widget,
                     GtkSnapshot *snapshot)
{
  ApexGlyph *self = APEX_GLYPH (widget);
  const GlyphPaths *g = &glyphs[self->kind];
  double scale = gtk_widget_get_width (widget) / GRID;
  GdkRGBA color;
  GdkRGBA track;

  if (self->kind == APEX_GLYPH_NONE)
    return;

  gtk_widget_get_color (widget, &color);
  track = color;
  track.alpha *= TRACK_ALPHA;

  gtk_snapshot_save (snapshot);
  gtk_snapshot_scale (snapshot, scale, scale);

  append_path (snapshot, g->track, &track, TRUE);

  if (self->angle != 0)
    {
      gtk_snapshot_translate (snapshot, &GRAPHENE_POINT_INIT (GRID / 2, GRID / 2));
      gtk_snapshot_rotate (snapshot, self->angle);
      gtk_snapshot_translate (snapshot, &GRAPHENE_POINT_INIT (-GRID / 2, -GRID / 2));
    }

  if (g->cut != NULL)
    {
      g_autoptr(GskPath) cut = gsk_path_parse (g->cut);
      g_autoptr(GskStroke) stroke = glyph_stroke ();
      GdkRGBA opaque = { 0, 0, 0, 1 };

      gtk_snapshot_push_mask (snapshot, GSK_MASK_MODE_INVERTED_ALPHA);
      gtk_snapshot_append_stroke (snapshot, cut, stroke, &opaque);
      gtk_snapshot_pop (snapshot);
      append_path (snapshot, g->fill, &color, FALSE);
      gtk_snapshot_pop (snapshot);
    }
  else
    {
      append_path (snapshot, g->stroke, &color, TRUE);
      append_path (snapshot, g->fill, &color, FALSE);
    }

  gtk_snapshot_restore (snapshot);
}

static gboolean
apex_glyph_tick (GtkWidget     *widget,
                 GdkFrameClock *clock,
                 gpointer       user_data)
{
  ApexGlyph *self = APEX_GLYPH (widget);
  gint64 t = gdk_frame_clock_get_frame_time (clock) % SPIN_PERIOD_USEC;

  self->angle = 360.0 * t / SPIN_PERIOD_USEC;
  gtk_widget_queue_draw (widget);
  return G_SOURCE_CONTINUE;
}

static gboolean
animations_enabled (GtkWidget *widget)
{
  gboolean enabled = TRUE;

  g_object_get (gtk_widget_get_settings (widget), "gtk-enable-animations", &enabled, NULL);
  return enabled;
}

static void
apex_glyph_update_spin (ApexGlyph *self)
{
  gboolean spin = self->kind == APEX_GLYPH_RUNNING &&
                  gtk_widget_get_mapped (GTK_WIDGET (self)) &&
                  animations_enabled (GTK_WIDGET (self));

  if (spin && self->tick_id == 0)
    self->tick_id = gtk_widget_add_tick_callback (GTK_WIDGET (self), apex_glyph_tick, NULL, NULL);
  else if (!spin && self->tick_id != 0)
    {
      gtk_widget_remove_tick_callback (GTK_WIDGET (self), self->tick_id);
      self->tick_id = 0;
      self->angle = 0;
    }
}

static void
apex_glyph_map (GtkWidget *widget)
{
  GTK_WIDGET_CLASS (apex_glyph_parent_class)->map (widget);
  apex_glyph_update_spin (APEX_GLYPH (widget));
}

static void
apex_glyph_unmap (GtkWidget *widget)
{
  GTK_WIDGET_CLASS (apex_glyph_parent_class)->unmap (widget);
  apex_glyph_update_spin (APEX_GLYPH (widget));
}

static void
apex_glyph_measure (GtkWidget      *widget,
                    GtkOrientation  orientation,
                    int             for_size,
                    int            *minimum,
                    int            *natural,
                    int            *minimum_baseline,
                    int            *natural_baseline)
{
  *minimum = *natural = APEX_GLYPH (widget)->size;
}

static void
apex_glyph_class_init (ApexGlyphClass *klass)
{
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

  widget_class->snapshot = apex_glyph_snapshot;
  widget_class->measure = apex_glyph_measure;
  widget_class->map = apex_glyph_map;
  widget_class->unmap = apex_glyph_unmap;

  gtk_widget_class_set_css_name (widget_class, "apex-glyph");
  gtk_widget_class_set_accessible_role (widget_class, GTK_ACCESSIBLE_ROLE_IMG);
}

static void
apex_glyph_init (ApexGlyph *self)
{
  self->size = GRID;
}

GtkWidget *
apex_glyph_new (ApexGlyphKind kind,
                int           size)
{
  ApexGlyph *self = g_object_new (APEX_TYPE_GLYPH, "valign", GTK_ALIGN_CENTER, NULL);

  self->size = size;
  apex_glyph_set_kind (self, kind);
  return GTK_WIDGET (self);
}

void
apex_glyph_set_kind (ApexGlyph     *self,
                     ApexGlyphKind  kind)
{
  if (self->kind == kind && gtk_widget_has_css_class (GTK_WIDGET (self), glyphs[kind].css_class))
    return;

  gtk_widget_remove_css_class (GTK_WIDGET (self), glyphs[self->kind].css_class);
  self->kind = kind;
  gtk_widget_add_css_class (GTK_WIDGET (self), glyphs[kind].css_class);
  apex_glyph_update_spin (self);
  gtk_widget_queue_draw (GTK_WIDGET (self));
}

ApexGlyphKind
apex_glyph_kind_for_status (ApexStatus status)
{
  switch (status)
    {
    case APEX_STATUS_RUNNING:
      return APEX_GLYPH_RUNNING;
    case APEX_STATUS_DONE:
      return APEX_GLYPH_DONE;
    case APEX_STATUS_FAILED:
      return APEX_GLYPH_FAILED;
    case APEX_STATUS_NEEDS_YOU:
      return APEX_GLYPH_NEEDS_YOU;
    case APEX_STATUS_IDLE:
    default:
      return APEX_GLYPH_NONE;
    }
}
