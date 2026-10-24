// SPDX-License-Identifier: GPL-3.0-or-later
//
// gjs outside the shell has no St: run.sh points the features' gi://St imports here.

import GLib from 'gi://GLib';

const scaleFactor = Number(GLib.getenv('PROBE_SCALE') ?? '1');

class Label {
    constructor(params) {
        Object.assign(this, {visible: true, width: 120}, params);
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

    destroy() {
        this.destroyed = true;
    }
}

class Widget extends Label {
    constructor(params) {
        super(params);
        this.children = [];
        this.constraints = [];
        this.styleClasses = (params?.style_class ?? '').split(' ').filter(c => c);
        this._handlers = [];
    }

    add_child(child) {
        this.children.push(child);
        child.parent = this;
        this.emit('child-added', child);
    }

    remove_child(child) {
        this.children = this.children.filter(c => c !== child);
        child.parent = null;
    }

    insert_child_above(child, sibling) {
        this.children.splice(this.children.indexOf(sibling) + 1, 0, child);
        child.parent = this;
    }

    set_child_above_sibling(child, sibling) {
        this.children = this.children.filter(c => c !== child);
        const at = sibling === null ? this.children.length : this.children.indexOf(sibling) + 1;
        this.children.splice(at, 0, child);
    }

    set_child_below_sibling(child, sibling) {
        this.children = this.children.filter(c => c !== child);
        this.children.splice(this.children.indexOf(sibling), 0, child);
    }

    destroy() {
        super.destroy();
        this.emit('destroy');
    }

    add_constraint(constraint) {
        this.constraints.push(constraint);
    }

    add_style_class_name(name) {
        this.styleClasses.push(name);
    }

    connect(signal, fn) {
        this._handlers.push([signal, fn]);
        return this._handlers.length;
    }

    emit(signal, ...args) {
        for (const [s, fn] of [...this._handlers]) {
            if (s === signal)
                fn(this, ...args);
        }
    }
}

class Bin extends Label {}
class Icon extends Label {}
class BoxLayout extends Widget {}

export default {
    Bin,
    BoxLayout,
    Icon,
    Label,
    Widget,
    ThemeContext: {get_for_stage: () => ({scale_factor: scaleFactor})},
};
