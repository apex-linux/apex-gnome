// SPDX-License-Identifier: GPL-3.0-or-later
//
// gjs outside the shell has no St: run.sh points the features' gi://St imports here.

import GLib from 'gi://GLib';

const scaleFactor = Number(GLib.getenv('PROBE_SCALE') ?? '1');

// The glass _glass.scss gives the layer's own St widgets, by style class.
const GLASS = [
    ['apex-launcher', {blur: 40, saturation: 1.6}],
    ['apex-glass-scrim', {blur: 36, saturation: 1.5}],
];

class Widget {
    constructor(params = {}) {
        this._effects = [];
        this.redirect = 0;
        this.redraws = 0;
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
        return null;
    }

    add_style_class_name(name) {
        this._styleClasses.add(name);
        this.emit('style-changed');
    }

    remove_style_class_name(name) {
        this._styleClasses.delete(name);
        this.emit('style-changed');
    }

    get_style_class_name() {
        return [...this._styleClasses].join(' ');
    }

    get mapped() {
        return this.visible && !this.destroyed;
    }

    get_effect(name) {
        return this._effects.find(e => e.name === name) ?? null;
    }

    add_effect(effect) {
        this._effects.push(effect);
    }

    remove_effect(effect) {
        this._effects.splice(this._effects.indexOf(effect), 1);
    }

    peek_theme_node() {
        const glass = GLASS.find(([name]) => this._styleClasses.has(name))?.[1];
        return {
            lookup_length: p => glass && p === '-apex-glass-blur' ? [true, glass.blur] : [false, 0],
            lookup_double: p => glass && p === '-apex-glass-saturation' ? [true, glass.saturation] : [false, 0],
            get_border_radius: () => 0,
        };
    }

    get_resource_scale() {
        return 2;
    }

    get_offscreen_redirect() {
        return this.redirect;
    }

    set_offscreen_redirect(redirect) {
        this.redirect = redirect;
    }

    get_transformed_position() {
        return [this.x, this.y];
    }

    get_transformed_size() {
        return [this.width, this.height];
    }

    queue_redraw() {
        this.redraws++;
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
