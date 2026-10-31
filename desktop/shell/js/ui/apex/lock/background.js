// SPDX-License-Identifier: GPL-2.0-or-later
//
// ADR 0014's lock blur, from the sheet's $apex_lock_blur and $apex_lock_saturation; stage.js draws the overlay.

import St from 'gi://St';

import * as Hooks from '../hooks.js';

const BACKGROUND_CLASS = 'apex-lock-background';
const BLUR_PROPERTY = '-apex-lock-blur';
const SATURATION_PROPERTY = '-apex-lock-saturation';
const BRIGHTNESS = 1.0;

let _enabled = false;

// The hook gives no actor, so a node of the loaded theme stands in for one. St scales its lengths: σ is logical here.
function _sheetBlur() {
    const context = St.ThemeContext.get_for_stage(global.stage);
    const node = St.ThemeNode.new(context, context.get_root_node(), context.get_theme(),
        St.Widget.$gtype, null, BACKGROUND_CLASS, null, '');
    const [hasBlur, blur] = node.lookup_length(BLUR_PROPERTY, false);
    const [hasSaturation, saturation] = node.lookup_double(SATURATION_PROPERTY, false);
    return hasBlur && hasSaturation ? {sigma: blur / context.scale_factor, saturation} : null;
}

// ClutterBlur's σ is half the radius ShellBlurEffect takes.
export function blurValues(stock) {
    if (!_enabled)
        return stock;
    const sheet = _sheetBlur();
    if (!sheet) {
        console.warn(`Apex: lock: the sheet sets no ${BLUR_PROPERTY} or ${SATURATION_PROPERTY}, so the lock keeps upstream's blur`);
        return stock;
    }
    return {brightness: BRIGHTNESS, radius: 2 * sheet.sigma, saturation: sheet.saturation};
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
