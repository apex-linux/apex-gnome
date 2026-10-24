// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's motion, one feature for disabled-features ('motion'): one curve,
// cubic-bezier(.2,.8,.2,1), and fixed durations for window geometry, the overview and
// popovers. enable-animations=false keeps stock's 0 ms through adjustAnimationTime.

import Clutter from 'gi://Clutter';
import Graphene from 'gi://Graphene';

import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';
import {BoxPointer, POPUP_ANIMATION_TIME} from '../../boxpointer.js';
import {ANIMATION_TIME as OVERVIEW_ANIMATION_TIME} from '../../overview.js';
import {SIDE_CONTROLS_ANIMATION_TIME} from '../../overviewControls.js';
import {WINDOW_ANIMATION_TIME} from '../../windowManager.js';

export const CURVE = [{x: 0.2, y: 0.8}, {x: 0.2, y: 1.0}];
export const WINDOW_GEOMETRY_MS = 300;
export const OVERVIEW_MS = 200;
export const POPOVER_MS = 180;

const {AnimationMode} = Clutter;
// Stepped and linear progress is meant to be even, so only the curved modes take Apex's.
const KEPT_MODES = new Set([AnimationMode.LINEAR, AnimationMode.STEPS, AnimationMode.STEP_START,
    AnimationMode.STEP_END]);

let _enabled = false;

function _ownerActor(target) {
    return target instanceof Clutter.Actor ? target : target.get_actor?.() ?? null;
}

// The size change eases the window actor and, in uiGroup, a clone of its old content.
function _isWindowGeometry(actor) {
    return actor.meta_window !== undefined ||
        global.get_window_actors().some(a => a.__animationInfo?.clone === actor);
}

export function duration(stock, actor) {
    if (!actor)
        return stock;
    if (stock === WINDOW_ANIMATION_TIME && _isWindowGeometry(actor))
        return WINDOW_GEOMETRY_MS;
    if ((stock === OVERVIEW_ANIMATION_TIME || stock === SIDE_CONTROLS_ANIMATION_TIME) &&
        Main.layoutManager.overviewGroup.contains(actor))
        return OVERVIEW_MS;
    if (stock === POPUP_ANIMATION_TIME && actor instanceof BoxPointer)
        return POPOVER_MS;
    return stock;
}

// An actor's ease without a mode takes the actor's default, Clutter's EASE_OUT_CUBIC.
export function easeParams(params, target) {
    if (!_enabled || !params)
        return params;
    const actor = _ownerActor(target);
    const mapped = {...params};
    const mode = params.mode ?? (target instanceof Clutter.Actor ? AnimationMode.EASE_OUT_CUBIC : undefined);
    if (mode !== undefined && !KEPT_MODES.has(mode))
        mapped.mode = AnimationMode.CUBIC_BEZIER;
    if (typeof params.duration === 'number')
        mapped.duration = duration(params.duration, actor);
    return mapped;
}

export function curveTransitions(transitions) {
    if (!_enabled)
        return;
    const [c1, c2] = CURVE.map(p => new Graphene.Point(p));
    for (const t of transitions) {
        if (t.get_progress_mode() === AnimationMode.CUBIC_BEZIER)
            t.set_cubic_bezier_progress(c1, c2);
    }
}

export function configure(featureName) {
    Hooks.provide(featureName, 'ease', easeParams);
    Hooks.provide(featureName, 'eased', curveTransitions);
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
