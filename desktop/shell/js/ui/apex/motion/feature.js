// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's motion, one feature for disabled-features ('motion'): one curve,
// cubic-bezier(.2,.8,.2,1), and fixed durations for window geometry, the overview and
// popovers. enable-animations=false keeps stock's 0 ms through adjustAnimationTime.

import Clutter from 'gi://Clutter';
import Graphene from 'gi://Graphene';

import * as Hooks from '../hooks.js';

export const CURVE = [{x: 0.2, y: 0.8}, {x: 0.2, y: 1.0}];
// The roles patch 0020's motion-duration call sites name.
export const DURATIONS = {window: 300, overview: 200, popover: 180};

const {AnimationMode} = Clutter;
// Stepped and linear progress is meant to be even, so only the curved modes take Apex's.
const KEPT_MODES = new Set([AnimationMode.LINEAR, AnimationMode.STEPS, AnimationMode.STEP_START,
    AnimationMode.STEP_END]);

let _enabled = false;

function _duration(stock, role) {
    return _enabled ? DURATIONS[role] ?? stock : stock;
}

// An actor's ease without a mode takes the actor's default, Clutter's EASE_OUT_CUBIC.
function _easeParams(params, target) {
    if (!_enabled || !params)
        return params;
    const mode = params.mode ?? (target instanceof Clutter.Actor ? AnimationMode.EASE_OUT_CUBIC : undefined);
    if (mode === undefined || KEPT_MODES.has(mode))
        return params;
    return {...params, mode: AnimationMode.CUBIC_BEZIER};
}

function _curveTransitions(transitions) {
    if (!_enabled)
        return;
    const [c1, c2] = CURVE.map(p => new Graphene.Point(p));
    for (const t of transitions) {
        if (t.get_progress_mode() === AnimationMode.CUBIC_BEZIER)
            t.set_cubic_bezier_progress(c1, c2);
    }
}

export function configure(featureName) {
    Hooks.provide(featureName, 'ease', _easeParams);
    Hooks.provide(featureName, 'eased', _curveTransitions);
    Hooks.provide(featureName, 'motion-duration', _duration);
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
