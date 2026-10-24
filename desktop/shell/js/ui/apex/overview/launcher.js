// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the launcher's grid has 7 columns of 88 px icons, 4 rows to a page.

import * as Main from '../../main.js';

const GRID_MODES = [{rows: 4, columns: 7}];
const ICON_SIZE = 88;
const STOCK_GRID_MODES = null;
const STOCK_ICON_SIZE = -1;

function _apply(modes, iconSize) {
    const grid = Main.overview._overview._controls._appDisplay._grid;
    const layout = grid.layout_manager;
    grid.setGridModes(modes);
    layout.fixed_icon_size = iconSize;
    // The grid picks its mode, and its layout the icon size, only when the page size changes.
    grid._currentMode = -1;
    layout._pageWidth = 0;
    grid.queue_relayout();
}

export function configure() {}

export function enable() {
    _apply(GRID_MODES, ICON_SIZE);
}

export function disable() {
    _apply(STOCK_GRID_MODES, STOCK_ICON_SIZE);
}
