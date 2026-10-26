// SPDX-License-Identifier: GPL-2.0-or-later

import Clutter from 'gi://Clutter';
import Cogl from 'gi://Cogl';
import GObject from 'gi://GObject';

import * as Uniforms from './uniforms.js';

export const EFFECT_NAME = 'apex-shadow-cutout';

const DECLARATIONS = `
uniform vec4 apex_rect;
uniform vec2 apex_size;
uniform float apex_radius;
`;

// A rounded box's signed distance: nothing inside it, a one-device-pixel ramp outside.
const CODE = `
vec2 apex_p = cogl_tex_coord_in[0].xy * apex_size;
vec2 apex_lo = apex_rect.xy * apex_size;
vec2 apex_hi = apex_rect.zw * apex_size;
vec2 apex_q = abs(apex_p - (apex_lo + apex_hi) * 0.5) - ((apex_hi - apex_lo) * 0.5 - apex_radius);
float apex_d = length(max(apex_q, 0.0)) + min(max(apex_q.x, apex_q.y), 0.0) - apex_radius;
cogl_color_out *= clamp(apex_d, 0.0, 1.0);
`;

// Above its surface, the layer keeps nothing inside the surface's rounded box.
const CutoutEffect = GObject.registerClass(
class CutoutEffect extends Clutter.ShaderEffect {
    constructor(radius) {
        super();
        this._radius = radius;
        this._uniforms = '';
    }

    vfunc_get_static_snippet() {
        return Cogl.Snippet.new(Cogl.SnippetHook.FRAGMENT, DECLARATIONS, CODE);
    }

    vfunc_paint_target(node, paintContext) {
        const [hasBox, box] = this.actor.get_paint_box();
        const [hasSize, width, height] = this.get_target_size();
        if (hasBox && hasSize) {
            const uniforms = Uniforms.cutoutUniforms(box, this.actor.get_transformed_extents(), width, height, this._radius);
            // A layer with no area has nothing to draw, and NaN uniforms would last into its next frame.
            if (!uniforms)
                return;
            this._setUniforms(uniforms);
        }
        super.vfunc_paint_target(node, paintContext);
    }

    // Uniforms queue a repaint, so they change only with the geometry.
    _setUniforms({rect, size: [width, height], radius}) {
        const key = [...rect, width, height, radius].join();
        if (key === this._uniforms)
            return;
        this._uniforms = key;
        this.set_uniform_float('apex_rect', 4, rect);
        this.set_uniform_float('apex_size', 2, [width, height]);
        this.set_uniform_float('apex_radius', 1, [radius]);
    }
});

export function addCutout(layer, radius) {
    layer.add_effect_with_name(EFFECT_NAME, new CutoutEffect(radius));
}
