// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/popupMenu.js: the menu parts the dock's Trash uses, and the
// switch the notifications feature puts in the date menu's footer.

import St from '../../../St.js';

export class PopupMenu {
    constructor() {
        this.actor = new St.Widget();
        this.items = [];
    }

    addAction(label, callback) {
        const item = {label, callback, sensitive: true, setSensitive(s) {
            this.sensitive = s;
        }};
        this.items.push(item);
        return item;
    }

    open() {
        this.opened = true;
    }

    destroy() {}
}

export class PopupMenuManager {
    addMenu() {}
}

export class Switch extends St.Widget {
    constructor(state) {
        super({style_class: 'toggle-switch', reactive: true});
        this.state = state;
    }
}
