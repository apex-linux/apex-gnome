// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's idle desktop (G2_IDLE=1): settled, with Quick Settings open too, glass or Reduce
// Transparency, the stage paints nothing for IDLE_WINDOW_MS. tests/shots/README.md.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Mtk from 'gi://Mtk';

import * as BoxPointer from 'resource:///org/gnome/shell/ui/boxpointer.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

const IDLE_WINDOW_MS = 10000;
const CONTROL_WINDOW_MS = 2000;
const SETTLE_REST_MS = 3000;
const DOCK_REST_TIMEOUT_MS = 5000;
const MAX_FRAMES_KEPT = 20;
const MAX_ANCESTORS = 6;
const GLASS_EFFECT = 'apex-glass';
const APEX_SCHEMA = 'io.github.apex_linux.Apex.Desktop';
const REDUCE_TRANSPARENCY_KEY = 'reduce-transparency';
const STAGE_LIMIT = 1 << 15;
const DAMAGE_SAMPLES = 4;
// The properties the shell and the layer ease; an actor easing one is not at rest.
const EASED = ['opacity', 'translation-x', 'translation-y', 'scale-x', 'scale-y', 'x', 'y', 'width', 'height',
    'background-color', 'rotation-angle-z'];

function actorName(actor) {
    const styleClass = actor.style_class ? `.${actor.style_class.trim().split(/\s+/).join('.')}` : '';
    const name = actor.get_name() ? `#${actor.get_name()}` : '';
    return `${actor.constructor.name}${name}${styleClass}`;
}

// The actor and its nearest ancestors, innermost first, so a stage repaint names its source.
function lineage(actor) {
    const chain = [];
    for (let a = actor; a && a !== global.stage && chain.length < MAX_ANCESTORS; a = a.get_parent())
        chain.push(actorName(a));
    return chain;
}

function walk(actor, visit) {
    visit(actor);
    for (const child of actor.get_children())
        walk(child, visit);
}

function easing(actor) {
    return EASED.filter(property => actor.get_transition(property));
}

function actorsEasing() {
    const found = [];
    walk(global.stage, actor => {
        const properties = easing(actor);
        if (properties.length > 0)
            found.push({actor: lineage(actor), properties});
    });
    return found;
}

// The least x (or y) at which the region has anything, between lo and hi: Mtk.Region's own
// rectangle getters return their structs by value, which gjs cannot take.
function edge(region, horizontal, lo, hi, fromStart) {
    const has = (a, b) => {
        const part = region.copy();
        part.intersect_rectangle(horizontal
            ? new Mtk.Rectangle({x: a, y: 0, width: b - a, height: STAGE_LIMIT})
            : new Mtk.Rectangle({x: 0, y: a, width: STAGE_LIMIT, height: b - a}));
        return !part.is_empty();
    };
    while (hi - lo > 1) {
        const mid = Math.floor((lo + hi) / 2);
        if (fromStart ? has(lo, mid) : !has(mid, hi))
            hi = mid;
        else
            lo = mid;
    }
    return fromStart ? lo : hi;
}

export function extentsOf(region) {
    const x1 = edge(region, true, 0, STAGE_LIMIT, true);
    const x2 = edge(region, true, 0, STAGE_LIMIT, false);
    const y1 = edge(region, false, 0, STAGE_LIMIT, true);
    const y2 = edge(region, false, 0, STAGE_LIMIT, false);
    return {x: x1, y: y1, width: x2 - x1, height: y2 - y1};
}

// The actors under the damage, sampled on a grid inside its extents.
function actorsUnder(region, {x, y, width, height}) {
    const found = new Map();
    for (let i = 0; i < DAMAGE_SAMPLES; i++) {
        for (let j = 0; j < DAMAGE_SAMPLES; j++) {
            const px = Math.floor(x + (i + 0.5) * width / DAMAGE_SAMPLES);
            const py = Math.floor(y + (j + 0.5) * height / DAMAGE_SAMPLES);
            if (!region.contains_point(px, py))
                continue;
            const actor = global.stage.get_actor_at_pos(Clutter.PickMode.ALL, px, py);
            if (actor && !found.has(actor))
                found.set(actor, lineage(actor));
        }
    }
    return [...found.values()];
}

function damageOf(region) {
    if (region.is_empty())
        return {rectangles: 0, extents: null, under: []};
    const extents = extentsOf(region);
    return {rectangles: region.num_rectangles(), extents, under: actorsUnder(region, extents)};
}

// Every stage frame in the window: its damage, the actors under it, and the actors that queued
// a relayout (queue-relayout runs up the tree, so the innermost is the one that asked).
async function paintsOver(ms) {
    const result = {afterPaints: 0, frames: [], relayouts: {}};
    const start = GLib.get_monotonic_time();
    const relayoutIds = [];
    walk(global.stage, actor => {
        relayoutIds.push([actor, actor.connect('queue-relayout', () => {
            const key = lineage(actor).join(' < ');
            result.relayouts[key] = (result.relayouts[key] ?? 0) + 1;
        })]);
    });
    const stageIds = [
        global.stage.connect('paint-view', (_stage, _view, region) => {
            if (result.frames.length < MAX_FRAMES_KEPT)
                result.frames.push({atMs: Math.round((GLib.get_monotonic_time() - start) / 1000), damage: damageOf(region)});
        }),
        global.stage.connect('after-paint', () => result.afterPaints++),
    ];
    await Scripting.sleep(ms);
    stageIds.forEach(id => global.stage.disconnect(id));
    for (const [actor, id] of relayoutIds) {
        if (!actor.is_destroyed?.())
            actor.disconnect(id);
    }
    return result;
}

async function until(condition, timeoutMs) {
    for (let waited = 0; waited < timeoutMs; waited += 100) {
        if (condition())
            return true;
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(100);
    }
    return condition();
}

// The desktop at rest: startup over, no overview, no banner, the dock and the bar's glass and
// shadows in place, nothing easing, and the pointer left where it started.
async function settleDesktop({settle, dropStartupNotifications, apexDock}) {
    dropStartupNotifications();
    Main.overview.hide();
    await settle();
    const dock = apexDock();
    const restedDock = dock ? await until(() => easing(dock.get_parent()).length === 0, DOCK_REST_TIMEOUT_MS) : null;
    await Scripting.sleep(SETTLE_REST_MS);
    return {
        startingUp: Main.layoutManager._startingUp,
        overview: Main.overview.visible,
        dock: dock ? {visible: dock.visible && dock.get_parent().visible, rested: restedDock} : null,
        barGlass: Boolean(Main.panel.get_effect(GLASS_EFFECT)),
        dockGlass: Boolean(dock?._background?.get_effect(GLASS_EFFECT)),
        easing: actorsEasing(),
    };
}

// The counter's own check: a menu that opens in the window must count frames.
async function control() {
    const menu = Main.panel.statusArea.quickSettings.menu;
    const counted = paintsOver(CONTROL_WINDOW_MS);
    await Scripting.sleep(CONTROL_WINDOW_MS / 4);
    menu.open(BoxPointer.PopupAnimation.NONE);
    const result = await counted;
    menu.close(BoxPointer.PopupAnimation.NONE);
    return {afterPaints: result.afterPaints, frames: result.frames};
}

// Quick Settings open and at rest: its glass and the bar's must not keep each other drawing.
async function withQuickSettingsOpen() {
    const menu = Main.panel.statusArea.quickSettings.menu;
    menu.open(BoxPointer.PopupAnimation.NONE);
    await Scripting.sleep(SETTLE_REST_MS);
    try {
        return await paintsOver(IDLE_WINDOW_MS);
    } finally {
        menu.close(BoxPointer.PopupAnimation.NONE);
        await Scripting.sleep(SETTLE_REST_MS);
    }
}

async function withReduceTransparency(read) {
    const apex = new Gio.Settings({schema_id: APEX_SCHEMA});
    apex.set_boolean(REDUCE_TRANSPARENCY_KEY, true);
    await Scripting.sleep(SETTLE_REST_MS);
    try {
        return await read();
    } finally {
        apex.reset(REDUCE_TRANSPARENCY_KEY);
        await Scripting.sleep(SETTLE_REST_MS);
    }
}

export async function idleReport(helpers) {
    const settled = await settleDesktop(helpers);
    const idle = await paintsOver(IDLE_WINDOW_MS);
    const quickSettings = await withQuickSettingsOpen();
    const reduceTransparency = await withReduceTransparency(async () => ({
        idle: await paintsOver(IDLE_WINDOW_MS),
        quickSettings: await withQuickSettingsOpen(),
    }));
    return {windowMs: IDLE_WINDOW_MS, settled, idle, quickSettings, reduceTransparency, control: await control()};
}
