// SPDX-License-Identifier: GPL-2.0-or-later
//
// St draws one box-shadow per actor (DESIGN, Engineering notes). A registered actor gets one
// shadow-layer actor per further layer its sheet names, below it and following its box.

import Clutter from 'gi://Clutter';
import Graphene from 'gi://Graphene';
import St from 'gi://St';

import * as Main from '../../main.js';

export const LAYER_PROPERTIES = ['-apex-shadow-layer', '-apex-shadow-layer-2'];
export const LAYER_STYLE_CLASS = 'apex-shadow-layer';

const _entries = new Map();
let _drawing = false;

function _css(shadow, radius, scale) {
    const px = v => `${v / scale}px`;
    const {red, green, blue, alpha} = shadow.color;
    return `box-shadow: ${px(shadow.xoffset)} ${px(shadow.yoffset)} ${px(shadow.blur)} ${px(shadow.spread)} ` +
        `rgba(${red}, ${green}, ${blue}, ${alpha / 255}); border-radius: ${px(radius)};`;
}

// The layers go into the container (uiGroup unless named), just below the actor's ancestor there.
function _host(actor, opts) {
    if (opts.box)
        return {parent: opts.box.get_parent(), below: opts.box};
    const container = opts.container ?? Main.uiGroup;
    let top = actor;
    while (top && top.get_parent() !== container)
        top = top.get_parent();
    return {parent: top ? container : null, below: top};
}

function _sync(entry) {
    const {actor, layers, host} = entry;
    if (!actor.mapped || layers.length === 0) {
        layers.forEach(l => l.hide());
        return;
    }
    const box = entry.opts.box ?? actor;
    const corner = (x, y) => box.apply_relative_transform_to_point(host.parent, new Graphene.Point3D({x, y, z: 0}));
    const [from, to] = [corner(0, 0), corner(box.width, box.height)];
    for (const layer of layers) {
        layer.set_position(Math.round(from.x), Math.round(from.y));
        layer.set_size(Math.round(to.x - from.x), Math.round(to.y - from.y));
        layer.opacity = host.below.opacity;
        layer.show();
    }
}

function _build(entry) {
    _clear(entry);
    const {actor} = entry;
    if (!(actor instanceof St.Widget) || !actor.get_stage())
        return;
    const node = actor.get_theme_node();
    const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
    const radius = node.get_border_radius(St.Corner.TOPLEFT);
    entry.host = _host(actor, entry.opts);
    if (!entry.host.parent)
        return;
    for (const property of LAYER_PROPERTIES) {
        const shadow = node.get_shadow(property);
        if (!shadow)
            continue;
        const layer = new St.Widget({
            style_class: LAYER_STYLE_CLASS,
            style: _css(shadow, radius, scale),
            name: entry.opts.name ? `${entry.opts.name}${property}` : null,
            x_align: Clutter.ActorAlign.START,
            y_align: Clutter.ActorAlign.START,
        });
        entry.host.parent.insert_child_below(layer, entry.host.below);
        entry.layers.push(layer);
    }
    _sync(entry);
}

function _clear(entry) {
    entry.layers.forEach(l => l.destroy());
    entry.layers = [];
}

function _attach(entry) {
    const {actor} = entry;
    const watched = [[actor, 'style-changed', () => _build(entry)], [actor, 'notify::mapped', () => _sync(entry)]];
    for (let a = entry.opts.box ?? actor; a && !(a instanceof Clutter.Stage); a = a.get_parent()) {
        for (const signal of ['notify::allocation', 'notify::translation-x', 'notify::translation-y',
            'notify::scale-x', 'notify::scale-y', 'notify::opacity'])
            watched.push([a, signal, () => _sync(entry)]);
    }
    entry.ids = watched.map(([emitter, signal, fn]) => [emitter, emitter.connect(signal, fn)]);
    _build(entry);
}

function _detach(entry) {
    entry.ids.forEach(([emitter, id]) => emitter.disconnect(id));
    entry.ids = [];
    _clear(entry);
}

export function register(actor, opts = {}) {
    const known = _entries.get(actor);
    if (known) {
        known.opts = opts;
        if (_drawing)
            _build(known);
        return;
    }
    const entry = {actor, opts, layers: [], ids: [], host: null};
    entry.destroyId = actor.connect('destroy', () => unregister(actor));
    _entries.set(actor, entry);
    if (_drawing)
        _attach(entry);
}

export function unregister(actor) {
    const entry = _entries.get(actor);
    if (!entry)
        return;
    _detach(entry);
    actor.disconnect(entry.destroyId);
    _entries.delete(actor);
}

export function layersOf(actor) {
    return Array.from(_entries.get(actor)?.layers ?? []);
}

export function start() {
    _drawing = true;
    _entries.forEach(_attach);
}

export function stop() {
    _drawing = false;
    _entries.forEach(_detach);
}
