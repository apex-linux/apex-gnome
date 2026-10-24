// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/iconGrid.js: the BaseIcon the dock's Trash uses, and the
// IconGrid of the launcher's results.

import {BaseIconStub} from './dash.js';

export class BaseIcon extends BaseIconStub {
    constructor(label, params) {
        super(label);
        this.createIcon = params.createIcon;
    }

    _createIconTexture(size) {
        this.iconSize = size;
        this.icon = this.createIcon(size);
    }
}

export class IconGrid {
    constructor() {
        this.items = [];
        this.visible = true;
        this.layout_manager = {};
    }

    setGridModes(modes) {
        this.modes = modes;
    }

    addItem(item) {
        this.items.push(item);
    }

    removeItem(item) {
        this.items = this.items.filter(i => i !== item);
    }

    destroy() {}
}
