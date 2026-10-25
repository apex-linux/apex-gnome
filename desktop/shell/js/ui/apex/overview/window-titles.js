// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: every window in the overview shows its title; hovering brings only the close button.
// The overview builds its previews each time it opens, so a change shows from the next opening.

import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';

const DOCK_CLEARANCE_PROPERTY = '-apex-dock-clearance';

let _enabled = false;

// Board 35: the last row's captions end the dock's own gap above it. The dock feature hides
// the overview's dash and gives it the dock's live height; without it, stock's bottom stands.
function _bottom(stock, monitor) {
    const {dash} = Main.overview;
    if (!_enabled || monitor.index !== Main.layoutManager.primaryIndex || dash.visible)
        return stock;
    const [, clearance] = Main.layoutManager.overviewGroup.get_theme_node().lookup_length(DOCK_CLEARANCE_PROPERTY, false);
    return stock - dash.height - clearance;
}

export function configure(featureName) {
    Hooks.provide(featureName, 'window-title-visible', stock => _enabled || stock);
    Hooks.provide(featureName, 'window-overlay', (actors, preview) =>
        _enabled ? actors.filter(actor => actor !== preview._title) : actors);
    // Stock rows leave room for the icon only, as its titles show on hover.
    Hooks.provide(featureName, 'window-row-oversize', (stock, preview) =>
        _enabled ? stock + preview.overlapHeights()[1] : stock);
    Hooks.provide(featureName, 'workspace-bottom', _bottom);
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
