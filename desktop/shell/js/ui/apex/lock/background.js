// SPDX-License-Identifier: GPL-2.0-or-later
//
// The lock background of ADR 0014's glass table: σ 30 with saturation 1.3, then the drawn
// overlay (stage.js) instead of upstream's darkening. _apex-tokens.scss holds the same values.

import * as Hooks from '../hooks.js';

export const BLUR_SIGMA = 30;
// 0003-blur's ShellBlurEffect property; stock values leave it at 1.0.
export const BLUR_SATURATION = 1.3;
const BRIGHTNESS = 1.0;

let _enabled = false;

// ClutterBlur's σ is half the radius ShellBlurEffect takes.
export function blurValues(stock) {
    return _enabled ? {brightness: BRIGHTNESS, radius: 2 * BLUR_SIGMA, saturation: BLUR_SATURATION} : stock;
}

export function configure(featureName) {
    Hooks.provide(featureName, 'unlock-blur', blurValues);
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
