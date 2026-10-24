// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/popupMenu.js: the menu parts the dock's Trash, the app
// indicators and the notifications footer use.

import St from '../../../St.js';

export const Ornament = {NONE: 0, DOT: 1, CHECK: 2, HIDDEN: 3, NO_DOT: 4};

export class PopupBaseMenuItem extends St.Widget {
    constructor(params = {}) {
        super({sensitive: true, ornament: Ornament.NONE, ...params});
    }

    setSensitive(sensitive) {
        this.sensitive = sensitive;
    }

    setOrnament(ornament) {
        this.ornament = ornament;
    }

    activate() {
        this.emit('activate');
    }
}

export class PopupMenuItem extends PopupBaseMenuItem {
    constructor(text, params) {
        super(params);
        this.label = new St.Label({text});
        this.add_child(this.label);
    }
}

export class PopupSwitchMenuItem extends PopupMenuItem {
    constructor(text, active, params) {
        super(text, params);
        this.state = active;
    }

    setToggleState(state) {
        this.state = state;
    }
}

export class PopupSeparatorMenuItem extends PopupBaseMenuItem {
    constructor(text = '') {
        super();
        this.label = new St.Label({text});
    }
}

export class PopupMenu {
    constructor(sourceActor) {
        this.sourceActor = sourceActor;
        this.actor = new St.Widget();
        this.actor._delegate = this;
        this.items = [];
        this.isOpen = false;
        this._handlers = [];
    }

    connect(signal, fn) {
        this._handlers.push([signal, fn]);
        return this._handlers.length;
    }

    _emit(signal, ...args) {
        this._handlers.filter(([s]) => s === signal).forEach(([, fn]) => fn(this, ...args));
    }

    addAction(label, callback) {
        const item = new PopupMenuItem(label);
        item.callback = callback;
        this.addMenuItem(item);
        return item;
    }

    addMenuItem(item) {
        this.items.push(item);
    }

    removeAll() {
        this.items = [];
    }

    open() {
        this.opened = true;
        this.isOpen = true;
        this._emit('open-state-changed', true);
    }

    toggle() {
        if (this.isOpen)
            this.close();
        else
            this.open();
    }

    close() {
        if (!this.isOpen)
            return;
        this.isOpen = false;
        this._emit('open-state-changed', false);
    }

    destroy() {
        this.destroyed = true;
    }
}

export class PopupSubMenuMenuItem extends PopupBaseMenuItem {
    constructor(text) {
        super();
        this.label = new St.Label({text});
        this.menu = new PopupMenu(this);
    }
}

export class PopupMenuManager {
    addMenu() {}
}

export class Switch extends St.Widget {
    constructor(state) {
        super({style_class: 'toggle-switch'});
        this.state = state;
    }
}
