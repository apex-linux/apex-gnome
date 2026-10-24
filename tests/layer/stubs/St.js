// SPDX-License-Identifier: GPL-3.0-or-later
//
// gjs outside the shell has no St: run.sh points the features' gi://St imports here.

import GLib from 'gi://GLib';

const scaleFactor = Number(GLib.getenv('PROBE_SCALE') ?? '1');

class Widget {
    constructor(params = {}) {
        this._children = [];
        this._handlers = [];
        this._actions = [];
        this._pseudoClasses = new Set();
        this._styleClasses = new Set((params.style_class ?? '').split(' ').filter(Boolean));
        Object.assign(this, {visible: true, width: 120, height: 0, x: 0, y: 0, hover: false}, params);
        if (params.child)
            this.add_child(params.child);
    }

    connect(signal, fn) {
        this._handlers.push([signal, fn]);
        return this._handlers.length;
    }

    disconnect(id) {
        this._handlers[id - 1] = null;
    }

    connectObject(...args) {
        for (let i = 0; i + 1 < args.length; i += 2)
            this.connect(args[i], args[i + 1]);
    }

    emit(signal, ...args) {
        for (const handler of [...this._handlers]) {
            if (handler?.[0] === signal)
                handler[1](this, ...args);
        }
    }

    add_child(child) {
        if (!child)
            return;
        this._children.push(child);
        child._parent = this;
    }

    insert_child_above(child, sibling) {
        this._children.splice(this._children.indexOf(sibling) + 1, 0, child);
        child._parent = this;
    }

    set_child_above_sibling(child, sibling) {
        this._children = this._children.filter(c => c !== child);
        const at = sibling === null ? this._children.length : this._children.indexOf(sibling) + 1;
        this._children.splice(at, 0, child);
    }

    set_child_below_sibling(child, sibling) {
        this._children = this._children.filter(c => c !== child);
        this._children.splice(this._children.indexOf(sibling), 0, child);
    }

    add_constraint(constraint) {
        (this.constraints ??= []).push(constraint);
    }

    get children() {
        return this.get_children();
    }

    get styleClasses() {
        return [...this._styleClasses];
    }

    remove_child(child) {
        this._children = this._children.filter(c => c !== child);
        child._parent = null;
    }

    destroy_all_children() {
        this.get_children().forEach(child => child.destroy());
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

    add_action(action) {
        this._actions.push(action);
    }

    add_action_full(_name, _phase, action) {
        this._actions.push(action);
    }

    get actions() {
        return [...this._actions];
    }

    get_stage() {
        return this._stage ?? this._parent?.get_stage() ?? null;
    }

    get_theme_node() {
        return this._themeNode ?? {get_shadow: () => null, get_border_radius: () => 0};
    }

    set_size(width, height) {
        Object.assign(this, {width, height});
    }

    // Translation only: the probe's actors are neither scaled nor rotated.
    apply_relative_transform_to_point(ancestor, point) {
        let {x, y} = point;
        for (let a = this; a && a !== ancestor; a = a._parent)
            [x, y] = [x + a.x, y + a.y];
        return {x, y};
    }

    get_effect() {
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

    add_style_pseudo_class(name) {
        this._pseudoClasses.add(name);
    }

    remove_style_pseudo_class(name) {
        this._pseudoClasses.delete(name);
    }

    has_style_pseudo_class(name) {
        return this._pseudoClasses.has(name);
    }

    show() {
        this.visible = true;
    }

    hide() {
        this.visible = false;
    }

    // No theme node here, so the glass feature only looks for an effect to remove.
    get_effect() {
        return null;
    }

    remove_effect() {}

    set_style(style) {
        this.style = style;
    }

    set_position(x, y) {
        Object.assign(this, {x, y});
    }

    ease(props) {
        Object.assign(this, props);
    }

    get_transformed_position() {
        return [this.x, this.y + (this.translation_y ?? 0)];
    }

    get_transformed_size() {
        return [this.width, this.height];
    }

    set(props) {
        Object.assign(this, props);
    }

    remove_all_transitions() {}

    destroy() {
        if (this.destroyed)
            return;
        this.destroyed = true;
        this._children.forEach(child => child.destroy?.());
        this._parent?.remove_child(this);
        this.emit('destroy');
    }
}

class Label extends Widget {}
class Bin extends Widget {}
class Icon extends Widget {}
class Button extends Widget {}
class BoxLayout extends Widget {}

class Entry extends Widget {
    constructor(params) {
        super(params);
        this._text = '';
        this.clutter_text = new Widget();
    }

    get_text() {
        return this._text;
    }

    set_text(text) {
        this._text = text;
        this.clutter_text.emit('text-changed');
    }

    grab_key_focus() {
        this.focused = true;
    }
}

const clipboard = {
    set_text(type, text) {
        printerr(`probe: clipboard=${type}:${text}`);
    },
};

// St.Settings' high-contrast, which the probe turns on and off.
const settingsHandlers = new Map();
let nextSettingsHandler = 1;
const settings = {
    high_contrast: false,
    connect(signal, fn) {
        settingsHandlers.set(nextSettingsHandler, [signal, fn]);
        return nextSettingsHandler++;
    },
    disconnect(id) {
        settingsHandlers.delete(id);
    },
    setHighContrast(on) {
        this.high_contrast = on;
        for (const [signal, fn] of [...settingsHandlers.values()]) {
            if (signal === 'notify::high-contrast')
                fn();
        }
    },
};

export default {
    Bin,
    BoxLayout,
    Button,
    ButtonMask: {ONE: 1, TWO: 2, THREE: 4},
    Corner: {TOPLEFT: 0, TOPRIGHT: 1, BOTTOMRIGHT: 2, BOTTOMLEFT: 3},
    Clipboard: {get_default: () => clipboard},
    ClipboardType: {PRIMARY: 0, CLIPBOARD: 1},
    Entry,
    Icon,
    Label,
    Corner: {TOPLEFT: 0, TOPRIGHT: 1, BOTTOMRIGHT: 2, BOTTOMLEFT: 3},
    Settings: {get: () => settings},
    Side: {TOP: 0, RIGHT: 1, BOTTOM: 2, LEFT: 3},
    ThemeContext: {get_for_stage: () => ({scale_factor: scaleFactor})},
    Widget,
};
