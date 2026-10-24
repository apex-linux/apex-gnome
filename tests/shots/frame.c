// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's glass cases read the frames the shell drew, which Cogl's read_pixels gives gjs no way
// to take: G2Frame-1.gir declares this one function. The shell has libmutter-cogl loaded.

#include <glib-object.h>
#include <stdint.h>

// COGL_PIXEL_FORMAT_RGBA_8888 is (3 | COGL_A_BIT), without the cogl headers of mutter-devel.
#define RGBA_8888 (3 | (1 << 4))

extern gboolean cogl_framebuffer_read_pixels (GObject *framebuffer, int x, int y, int width,
                                              int height, int format, uint8_t *pixels);

GBytes *g2_frame_read (GObject *framebuffer, int x, int y, int width, int height);

GBytes *
g2_frame_read (GObject *framebuffer, int x, int y, int width, int height)
{
    gsize size = (gsize) width * height * 4;
    uint8_t *pixels = g_malloc0 (size);

    if (!cogl_framebuffer_read_pixels (framebuffer, x, y, width, height, RGBA_8888, pixels)) {
        g_free (pixels);
        return NULL;
    }
    return g_bytes_new_take (pixels, size);
}
