// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh points the features' gi://GdkPixbuf imports here: the layer job installs no
// gdk-pixbuf, and a pixmap's size and first pixel tell the tests enough.

export default {
    Colorspace: {RGB: 0},
    Pixbuf: {
        new_from_bytes: (bytes, _colorspace, hasAlpha, _bits, width, height) => {
            const data = bytes.toArray();
            return {pixmap: `${width}x${height}`, hasAlpha, firstPixel: [...data.slice(0, 4)].join(',')};
        },
    },
};
