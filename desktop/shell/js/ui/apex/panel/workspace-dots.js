// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's workspace dots: the active one as wide as the sheet's -apex-active-width, the
// others full size at .45, where panel.js widens one by a factor and shrinks the rest.

import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';

const ACTIVE_WIDTH_PROPERTY = '-apex-active-width';
const INACTIVE = {opacity: 0.45, scale: 1};

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
    return _enabled ? INACTIVE : stock;
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
