// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/iconGrid.js: the BaseIcon the dock's Trash uses.

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
