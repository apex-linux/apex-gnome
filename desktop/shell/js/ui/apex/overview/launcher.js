// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the launcher's grid has 7 columns of 88 px icons, 4 rows to a page, and takes the
// space of the workspace strip stock keeps above it (board 36 draws none).

import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';

const GRID_MODES = [{rows: 4, columns: 7}];
const ICON_SIZE = 88;
const STOCK_GRID_MODES = null;
const STOCK_ICON_SIZE = -1;
const STRIP_HEIGHT = 0;

let _enabled = false;

function _apply(modes, iconSize) {
    const controls = Main.overview._overview._controls;
    const grid = controls._appDisplay._grid;
    const layout = grid.layout_manager;
    grid.setGridModes(modes);
    layout.fixed_icon_size = iconSize;
    // The grid picks its mode, and its layout the icon size, only when the page size changes.
    grid._currentMode = -1;
    layout._pageWidth = 0;
    grid.queue_relayout();
    controls.queue_relayout();
}

export function configure(featureName) {
    Hooks.provide(featureName, 'app-grid-workspaces-height', stock => _enabled ? STRIP_HEIGHT : stock);
}

export function enable() {
    _enabled = true;
    _apply(GRID_MODES, ICON_SIZE);
}

export function disable() {
    _enabled = false;
    _apply(STOCK_GRID_MODES, STOCK_ICON_SIZE);
}
