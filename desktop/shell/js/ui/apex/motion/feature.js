// SPDX-License-Identifier: GPL-2.0-or-later

import Clutter from 'gi://Clutter';
import Graphene from 'gi://Graphene';

import * as Hooks from '../hooks.js';

export const CURVE = [{x: 0.2, y: 0.8}, {x: 0.2, y: 1.0}];
export const DURATIONS = {window: 300, overview: 200, popover: 180};

const {AnimationMode} = Clutter;
// Stepped and linear progress is meant to be even, so only the curved modes take Apex's.
const KEPT_MODES = new Set([AnimationMode.LINEAR, AnimationMode.STEPS, AnimationMode.STEP_START,
    AnimationMode.STEP_END]);

let _enabled = false;

function _duration(stock, role) {
    return _enabled ? DURATIONS[role] ?? stock : stock;
}

function _easeParams(params, target) {
    if (!_enabled || !params)
        return params;
    const actorDefault = target instanceof Clutter.Actor ? AnimationMode.EASE_OUT_CUBIC : undefined;
    const mode = params.mode ?? actorDefault;
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
