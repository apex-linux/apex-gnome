// SPDX-License-Identifier: GPL-3.0-or-later
//
// gjs outside the shell has no St: run.sh points the features' gi://St imports here.

import GLib from 'gi://GLib';

const scaleFactor = Number(GLib.getenv('PROBE_SCALE') ?? '1');

class Widget {
    constructor(params = {}) {
        this._children = [];
        this._handlers = [];
        this._styleClasses = new Set((params.style_class ?? '').split(' ').filter(Boolean));
        Object.assign(this, {visible: true, width: 120, height: 0, x: 0, y: 0}, params);
        if (params.child)
            params.child._parent = this;
    }

    connect(signal, fn) {
        this._handlers.push([signal, fn]);
        return this._handlers.length;
    }

    disconnect(id) {
        this._handlers[id - 1] = null;
    }

    emit(signal, ...args) {
        for (const handler of [...this._handlers]) {
            if (handler?.[0] === signal)
                handler[1](this, ...args);
        }
    }

    add_child(child) {
        this._children.push(child);
        child._parent = this;
    }

    insert_child_below(child, sibling) {
        const index = this._children.indexOf(sibling);
        this._children.splice(index < 0 ? 0 : index, 0, child);
        child._parent = this;
    }

    get_children() {
        return [...this._children];
    }

    get_parent() {
        return this._parent ?? null;
    }

    get_stage() {
        return null;
    }

    add_style_class_name(name) {
        this._styleClasses.add(name);
    }

    remove_style_class_name(name) {
        this._styleClasses.delete(name);
    }

    has_style_class_name(name) {
        return this._styleClasses.has(name);
    }

    show() {
        this.visible = true;
    }

    hide() {
        this.visible = false;
    }

    set_position(x, y) {
        Object.assign(this, {x, y});
    }

    ease(props) {
        Object.assign(this, props);
    }

    destroy() {
        if (this.destroyed)
            return;
        this.destroyed = true;
        this._children.forEach(child => child.destroy?.());
        this.emit('destroy');
    }
}

class Label extends Widget {}
class Bin extends Widget {}
class Icon extends Widget {}
class Button extends Widget {}

export default {
    Bin,
    Button,
    ButtonMask: {ONE: 1, TWO: 2, THREE: 4},
    Icon,
    Label,
    Side: {TOP: 0, RIGHT: 1, BOTTOM: 2, LEFT: 3},
    ThemeContext: {get_for_stage: () => ({scale_factor: scaleFactor})},
    Widget,
};
