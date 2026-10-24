// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/panelMenu.js: the parts of PanelMenu.Button the features use.

export class Button {
    constructor(_menuAlignment, nameText, dontCreateMenu) {
        this.accessible_name = nameText ?? '';
        this.hasMenu = !dontCreateMenu;
        this.reactive = true;
        this.children = [];
        this.actions = [];
        this.styleClasses = [];
        this.container = {visible: true};
        this.destroyed = false;
        this.hover = false;
        this._handlers = [];
    }

    get_transformed_position() {
        return [1300, 0];
    }

    get_transformed_size() {
        return [32, 32];
    }

    setSensitive(sensitive) {
        this.reactive = sensitive;
    }

    add_style_class_name(name) {
        this.styleClasses.push(name);
    }

    add_action(action) {
        this.actions.push(action);
    }

    add_child(child) {
        this.children.push(child);
    }

    connect(signal, fn) {
        this._handlers.push([signal, fn]);
        return this._handlers.length;
    }

    emit(signal) {
        this._handlers.filter(([s]) => s === signal).forEach(([, fn]) => fn(this));
    }

    destroy() {
        this.destroyed = true;
        this.emit('destroy');
    }
}
