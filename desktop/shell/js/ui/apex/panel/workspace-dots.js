// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's workspace dots: the active one as wide as the sheet's -apex-active-width, the others full
// size at its -apex-inactive-opacity, read off the first dot since panel.js's hook passes none.

import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';

const ACTIVE_WIDTH_PROPERTY = '-apex-active-width';
const INACTIVE_OPACITY_PROPERTY = '-apex-inactive-opacity';
const INACTIVE_SCALE = 1;

let _enabled = false;

function _width(stock, natural, dot, expansion) {
    if (!_enabled)
        return stock;
    const active = dot.get_theme_node().get_length(ACTIVE_WIDTH_PROPERTY);
    if (active <= 0)
        return stock;
    return natural.map(v => Math.round(v + (active - v) * expansion));
}

function _inactive(stock) {
    if (!_enabled)
        return stock;
    const dot = Main.panel.statusArea.activities.get_first_child().get_first_child()?._dot;
    const [found, opacity] = dot?.peek_theme_node()?.lookup_double(INACTIVE_OPACITY_PROPERTY, false) ?? [false, 0];
    return found ? {opacity, scale: INACTIVE_SCALE} : stock;
}

// A dot restyles itself only when its expansion changes.
function _restyleDots() {
    for (const dot of Main.panel.statusArea.activities.get_first_child().get_children()) {
        dot._updateVisuals();
        dot.queue_relayout();
    }
}

export function configure(featureName) {
    Hooks.provide(featureName, 'workspace-dot-width', _width);
    Hooks.provide(featureName, 'workspace-dot-inactive', _inactive);
}

export function enable() {
    _enabled = true;
    _restyleDots();
}

export function disable() {
    _enabled = false;
    _restyleDots();
}
