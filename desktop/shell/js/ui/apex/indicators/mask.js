// SPDX-License-Identifier: GPL-2.0-or-later
//
// Draws an actor as a one-colour mask: its alpha, in the colour setColor gives.

import Clutter from 'gi://Clutter';
import Cogl from 'gi://Cogl';
import GObject from 'gi://GObject';

const MASK_DECLARATIONS = 'uniform sampler2D tex;\nuniform vec4 color;\n';
const MASK_CODE = 'cogl_color_out = color * texture2D(tex, cogl_tex_coord_in[0].xy).a;\n';

export const MaskEffect = GObject.registerClass(
class MaskEffect extends Clutter.ShaderEffect {
    vfunc_get_static_snippet() {
        const snippet = Cogl.Snippet.new(Cogl.SnippetHook.FRAGMENT, MASK_DECLARATIONS, null);
        snippet.set_replace(MASK_CODE);
        return snippet;
    }

    // Premultiplied, as the offscreen texture is.
    setColor({red, green, blue, alpha}) {
        const a = alpha / 255;
        this.set_uniform_value('tex', 0);
        this.set_uniform_float('color', 4, [red / 255 * a, green / 255 * a, blue / 255 * a, a]);
        this.queue_repaint();
    }
});
