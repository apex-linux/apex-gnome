// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/panelMenu.js: the parts of PanelMenu.Button the features use.

export class Button {
    constructor(_menuAlignment, nameText, dontCreateMenu) {
        this.accessible_name = nameText ?? '';
        this.hasMenu = !dontCreateMenu;
        this.reactive = true;
        this.children = [];
        this.styleClasses = [];
        this.container = {visible: true};
        this.destroyed = false;
        this._destroyHandlers = [];
    }

    setSensitive(sensitive) {
        this.reactive = sensitive;
    }

    add_style_class_name(name) {
        this.styleClasses.push(name);
    }

    add_child(child) {
        this.children.push(child);
    }

    connect(signal, fn) {
        if (signal === 'destroy')
            this._destroyHandlers.push(fn);
        return this._destroyHandlers.length;
    }

    destroy() {
        this.destroyed = true;
        this._destroyHandlers.forEach(fn => fn(this));
    }
}
