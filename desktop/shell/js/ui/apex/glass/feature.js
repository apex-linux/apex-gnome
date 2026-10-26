// SPDX-License-Identifier: GPL-2.0-or-later
//
// ADR 0014's glass manager ('glass' in disabled-features): patch 0003's blur behind each
// registered surface, its pause rules, damage forwarding, and the solid fallbacks.

import Gio from 'gi://Gio';
import Mtk from 'gi://Mtk';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from '../../main.js';
import * as Registry from './registry.js';
import * as Surfaces from './surfaces.js';

const SCHEMA_ID = 'io.github.apex_linux.Apex.Desktop';
const REDUCE_TRANSPARENCY_KEY = 'reduce-transparency';
const SOLID_STYLE_CLASS = 'apex-solid';
const EFFECT_NAME = 'apex-glass';
const BLUR_PROPERTY = '-apex-glass-blur';
const SATURATION_PROPERTY = '-apex-glass-saturation';

let _settings = null;
let _watched = new Map();
let _windows = new Map();
let _backgrounds = [];
const _redirects = new Map();
let _connections = [];
let _stopListening = null;
let _unregisterBuiltins = null;

export function solid() {
    return _settings.get_boolean(REDUCE_TRANSPARENCY_KEY) || St.Settings.get().high_contrast;
}

// In stage pixels, as St scales lengths; null for an actor its sheet gives no glass.
function _glassOf(actor) {
    const node = actor.peek_theme_node?.();
    if (!node)
        return null;
    const [hasBlur, blur] = node.lookup_length(BLUR_PROPERTY, false);
    if (!hasBlur || blur <= 0)
        return null;
    const [hasSaturation, saturation] = node.lookup_double(SATURATION_PROPERTY, false);
    return {
        sigma: blur, saturation: hasSaturation ? saturation : 1,
        cornerRadius: node.get_border_radius(St.Corner.TOPLEFT),
    };
}

// A background blur inside an offscreen redirect (the panel's, BoxPointer's, the dash's)
// would blit that offscreen layer, not the stage: glass holds them off, and gives them back.
function _holdRedirects(surface) {
    if (surface.redirects)
        return;
    surface.redirects = [];
    for (let actor = surface.actor; actor; actor = actor.get_parent()) {
        const held = _redirects.get(actor);
        if (held) {
            held.users++;
        } else if (actor.get_offscreen_redirect() !== 0) {
            _redirects.set(actor, {original: actor.get_offscreen_redirect(), users: 1});
            actor.set_offscreen_redirect(0);
        } else {
            continue;
        }
        surface.redirects.push(actor);
    }
}

function _releaseRedirects(surface) {
    for (const actor of surface.redirects ?? []) {
        const held = _redirects.get(actor);
        if (--held.users > 0)
            continue;
        _redirects.delete(actor);
        actor.set_offscreen_redirect(held.original);
    }
    surface.redirects = null;
}

function _removeEffect(surface) {
    const effect = surface.actor.get_effect(EFFECT_NAME);
    if (effect)
        surface.actor.remove_effect(effect);
    _releaseRedirects(surface);
}

// ClutterBlur's sigma is half the radius, in the device pixels of the actor's views.
function _sync(surface) {
    const {actor} = surface;
    const glass = solid() ? null : _glassOf(actor);
    if (!glass) {
        _removeEffect(surface);
        return;
    }
    _holdRedirects(surface);
    let effect = actor.get_effect(EFFECT_NAME);
    if (!effect) {
        effect = new Shell.BlurEffect({
            name: EFFECT_NAME, fine: true, follow_opacity: true,
            mode: surface.mode === 'actor' ? Shell.BlurMode.ACTOR : Shell.BlurMode.BACKGROUND,
        });
        actor.add_effect(effect);
    }
    const scale = actor.get_resource_scale();
    effect.set({
        radius: Math.round(2 * glass.sigma * scale),
        saturation: glass.saturation,
        corner_radius: Math.round(glass.cornerRadius * scale),
    });
    effect.enabled = actor.mapped && !surface.paused();
}

function _syncAll() {
    if (solid())
        Main.uiGroup.add_style_class_name(SOLID_STYLE_CLASS);
    else
        Main.uiGroup.remove_style_class_name(SOLID_STYLE_CLASS);
    for (const surface of _watched.keys())
        _sync(surface);
}

function _watch(surface) {
    const sync = () => _sync(surface);
    _watched.set(surface, [
        ...['style-changed', 'notify::mapped', 'resource-scale-changed'].map(signal => [surface.actor, signal]),
        ...surface.pausedChanged,
    ].map(([emitter, signal]) => [emitter, emitter.connect(signal, sync)]));
    sync();
}

function _unwatch(surface) {
    for (const [emitter, id] of _watched.get(surface) ?? [])
        emitter.disconnect(id);
    _watched.delete(surface);
    _removeEffect(surface);
}

function _boxOf(actor) {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    return {x, y, width, height};
}

function _overlaps(a, b) {
    return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
}

// The box alone: the paint volume's box-shadow would reach the glass beside it and re-blur that too.
function _queueBox(actor) {
    actor.queue_redraw_with_clip(new Mtk.Rectangle({x: 0, y: 0, width: Math.ceil(actor.width), height: Math.ceil(actor.height)}));
}

// For latency only: the redraw-clip rule of patch 0003 keeps a missed source one frame late.
export function forwardDamage(...boxes) {
    for (const surface of _watched.keys()) {
        const effect = surface.actor.get_effect(EFFECT_NAME);
        if (!effect?.enabled)
            continue;
        // Shown since the last layout, it has no box to test: the whole redraw resolves after layout.
        if (!surface.actor.has_allocation()) {
            surface.actor.queue_redraw();
            continue;
        }
        const glassBox = _boxOf(surface.actor);
        if (boxes.length === 0 || boxes.some(box => _overlaps(box, glassBox)))
            _queueBox(surface.actor);
    }
}

function _watchWindow(actor) {
    if (typeof actor.get_meta_window !== 'function' || _windows.has(actor))
        return;
    let box = _boxOf(actor);
    const damaged = () => forwardDamage(_boxOf(actor));
    const moved = () => {
        const old = box;
        box = _boxOf(actor);
        forwardDamage(old, box);
    };
    _windows.set(actor, [
        actor.connect('damaged', damaged),
        actor.connect('notify::allocation', moved),
        actor.connect('destroy', () => {
            forwardDamage(box);
            _windows.delete(actor);
        }),
    ]);
}

function _unwatchWindows() {
    for (const [actor, ids] of _windows)
        ids.forEach(id => actor.disconnect(id));
    _windows = new Map();
}

// layout.js rebuilds its background managers when the monitors change.
function _watchBackgrounds() {
    _unwatchBackgrounds();
    _backgrounds = (Main.layoutManager._bgManagers ?? []).map(manager =>
        [manager, manager.connect('changed', () => forwardDamage())]);
}

function _unwatchBackgrounds() {
    _backgrounds.forEach(([manager, id]) => manager.disconnect(id));
    _backgrounds = [];
}

export function configure() {
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(SCHEMA_ID, true);
    if (!schema?.has_key(REDUCE_TRANSPARENCY_KEY))
        throw new Error(`${SCHEMA_ID} has no key ${REDUCE_TRANSPARENCY_KEY}`);
    _settings = new Gio.Settings({settings_schema: schema});
}

export function enable() {
    _watched = new Map();
    _stopListening = Registry.listen({added: _watch, removed: _unwatch});
    Registry.surfaces().forEach(_watch);
    _unregisterBuiltins = Surfaces.register();
    global.get_window_actors().forEach(_watchWindow);
    _watchBackgrounds();
    _connections = [
        [_settings, `changed::${REDUCE_TRANSPARENCY_KEY}`, _syncAll],
        [St.Settings.get(), 'notify::high-contrast', _syncAll],
        [global.window_group, 'child-added', (_group, actor) => _watchWindow(actor)],
        [global.display, 'restacked', () => forwardDamage()],
        [Main.layoutManager, 'monitors-changed', _watchBackgrounds],
    ].map(([emitter, signal, fn]) => [emitter, emitter.connect(signal, fn)]);
    _syncAll();
}

export function disable() {
    for (const [emitter, id] of _connections)
        emitter.disconnect(id);
    _connections = [];
    _unwatchBackgrounds();
    _unwatchWindows();
    _unregisterBuiltins?.();
    _unregisterBuiltins = null;
    _stopListening?.();
    _stopListening = null;
    [..._watched.keys()].forEach(_unwatch);
    Main.uiGroup.remove_style_class_name(SOLID_STYLE_CLASS);
}
