// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's glass under load (G2_GLASS_LOAD=1): ADR 0014's scenarios A, B and C as work, not time.
// Each runs with the glass and again with Reduce Transparency. tests/shots/README.md, "Glass under load".

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Mtk from 'gi://Mtk';

import * as BoxPointer from 'resource:///org/gnome/shell/ui/boxpointer.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

import {extentsOf} from './idle.js';

const APEX_SCHEMA = 'io.github.apex_linux.Apex.Desktop';
const REDUCE_TRANSPARENCY_KEY = 'reduce-transparency';
const DOCK_INTELLIHIDE_KEY = 'dock-intellihide';
const GLASS_REGISTRY = 'resource:///org/gnome/shell/ui/apex/glass/registry.js';
const SPOTLIGHT_FEATURE = 'resource:///org/gnome/shell/ui/apex/spotlight/feature.js';
const GLASS_EFFECT = 'apex-glass';
const LOAD_APP_ID = 'io.github.apex_linux.G2LoadWindow';
const CLIENT_WAIT_MS = 10000;
const SETTLE_MS = 1500;
const SCENARIO_MS = 5000;
const STEP_MS = 33;
const TOGGLES = 20;
const TRACED_FRAMES = 12;
// Where the window stands in A and C, in logical px of the 1440 x 900 monitor: over the dock and
// under Quick Settings. B's path crosses the dock, then each popover.
const OVER_DOCK_AND_POPOVERS = {x: 760, y: 300, width: 600, height: 590};
const DRAG_SIZE = {width: 360, height: 240};
const B_LEGS = [
    {popover: null, from: [300, 640], to: [1080, 640]},
    {popover: 'quickSettings', from: [700, 120], to: [1080, 120]},
    {popover: 'dateMenu', from: [300, 120], to: [900, 120]},
];
// 0014-blurcost.py's model: half the Vega 7's bandwidth and texture rate.
const BYTES_PER_S = 25e9;
const TAPS_PER_S = 25e9;
const MAX_DOWNSAMPLED_SIGMA = 4;

function taps(sigma) {
    return 1 + 2 * Math.ceil(1.5 * sigma);
}

// 0014-blurcost.py's apex_cost: ms per re-blur of a box of W x H device px at sigma device px.
export function modelledMs(W, H, sigma) {
    let ds = 1;
    while (sigma / ds > MAX_DOWNSAMPLED_SIGMA && Math.min(W, H) / (ds * 2) >= 4)
        ds *= 2;
    const t = taps(sigma / ds);
    const [w, h] = [Math.ceil(W / ds), Math.ceil(H / ds)];
    const mtaps = 2 * t * w * h / 1e6;
    let reads = 0;
    for (let k = 1; k <= Math.log2(ds); k++)
        reads += (W / 2 ** k) * (H / 2 ** k);
    const mbytes = (W * H * 4 * 2 + (W * H + reads) * 4 + w * h * 4 * 4 + W * H * 4 * 2) / 1e6;
    return (mbytes * 1e6 / BYTES_PER_S + (mtaps * 1e6 + reads + W * H) / TAPS_PER_S) * 1e3;
}

function rectOf(actor) {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    return {x: Math.floor(x), y: Math.floor(y), width: Math.ceil(width), height: Math.ceil(height)};
}

function intersects(a, b) {
    return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
}

function union(a, b) {
    const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
    return {x, y, width: Math.max(a.x + a.width, b.x + b.width) - x, height: Math.max(a.y + a.height, b.y + b.height) - y};
}

// The glass the manager drew this frame: registered, mapped, its effect on.
function liveGlass(Registry) {
    return Registry.surfaces()
        .filter(s => s.actor.mapped && s.actor.get_effect(GLASS_EFFECT)?.enabled)
        .map(s => ({name: s.name, actor: s.actor, effect: s.actor.get_effect(GLASS_EFFECT), rect: rectOf(s.actor)}));
}

// Per frame: the glass the clip covered (re-blurred, patch 0003's rule e) or only touched, and
// whether a change under a box re-blurred it at once. The first frames keep their clip.
function record(Registry, windowActor) {
    const stats = {frames: 0, contentFrames: 0, surfaces: {}, missed: [], modelledMs: 0, boxes: {}, trace: [], tail: null};
    const start = GLib.get_monotonic_time();
    let damaged = false;
    let lastRect = rectOf(windowActor);
    const damagedId = windowActor.connect('damaged', () => {
        damaged = true;
    });
    const surface = name => (stats.surfaces[name] ??= {reblurs: 0, partial: 0, contentUnder: 0});
    const overlapOf = (clip, glass) => clip ? clip.contains_rectangle(new Mtk.Rectangle(glass.rect)) : Mtk.RegionOverlap.IN;
    const overlapName = overlap => ['out', 'in', 'part'][overlap] ?? overlap;
    let tail = true;
    const paintId = global.stage.connect('paint-view', (_stage, _view, clip) => {
        const rect = rectOf(windowActor);
        if (tail) {
            // The first frame can repaint damage from before 'damaged' was connected: reported, not counted.
            stats.tail = Object.fromEntries(liveGlass(Registry).map(glass => [glass.name, overlapName(overlapOf(clip, glass))]));
            tail = false;
            damaged = false;
            lastRect = rect;
            return;
        }
        stats.frames++;
        const moved = rect.x !== lastRect.x || rect.y !== lastRect.y;
        const changed = moved || damaged ? union(lastRect, rect) : null;
        if (changed)
            stats.contentFrames++;
        const traced = stats.trace.length < TRACED_FRAMES
            ? {content: Boolean(changed), clip: clip && !clip.is_empty() ? extentsOf(clip) : null, overlap: {}} : null;
        if (traced)
            stats.trace.push(traced);
        for (const glass of liveGlass(Registry)) {
            stats.boxes[glass.name] = glass.rect;
            if (changed && intersects(changed, glass.rect))
                surface(glass.name).contentUnder++;
            const overlap = overlapOf(clip, glass);
            if (traced)
                traced.overlap[glass.name] = overlapName(overlap);
            if (overlap === Mtk.RegionOverlap.IN) {
                surface(glass.name).reblurs++;
                const scale = glass.actor.get_resource_scale();
                stats.modelledMs += modelledMs(glass.rect.width * scale, glass.rect.height * scale, glass.effect.radius / 2);
            } else if (overlap === Mtk.RegionOverlap.PART) {
                surface(glass.name).partial++;
            }
            if (changed && intersects(changed, glass.rect) && overlap !== Mtk.RegionOverlap.IN) {
                stats.missed.push({
                    atMs: Math.round((GLib.get_monotonic_time() - start) / 1000),
                    surface: glass.name, overlap: overlap === Mtk.RegionOverlap.PART ? 'part' : 'out',
                });
            }
        }
        damaged = false;
        lastRect = rect;
    });
    return () => {
        global.stage.disconnect(paintId);
        windowActor.disconnect(damagedId);
        stats.extraFrames = stats.frames - stats.contentFrames;
        stats.modelledMsPerFrame = stats.frames ? Math.round(stats.modelledMs / stats.frames * 1000) / 1000 : 0;
        delete stats.modelledMs;
        stats.missed = stats.missed.slice(0, 20);
        return stats;
    };
}

async function startClient(still, {display, clientArgs = []} = {}) {
    const client = Gio.File.new_for_uri(import.meta.url).get_parent().get_child('load-window.js').get_path();
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.STDERR_PIPE});
    launcher.setenv('WAYLAND_DISPLAY', display ?? GLib.getenv('G2_WAYLAND_DISPLAY') ?? 'apex-g2', true);
    launcher.setenv('GDK_BACKEND', 'wayland', true);
    const process = launcher.spawnv(['gjs', '-m', client, ...still ? ['still'] : [], ...clientArgs]);
    const find = () => global.get_window_actors().find(a => a.meta_window.get_gtk_application_id() === LOAD_APP_ID);
    let actor;
    for (let waited = 0; !(actor = find())?.mapped && waited < CLIENT_WAIT_MS; waited += 100)
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(100);
    if (!actor?.mapped) {
        process.force_exit();
        throw new Error(`the load window never mapped in ${CLIENT_WAIT_MS} ms`);
    }
    return {process, actor, window: actor.meta_window};
}

function place(window, {x, y, width, height}) {
    window.move_resize_frame(false, x, y, width, height);
}

async function measure(Registry, actor, run, onStart = () => {}) {
    const stop = record(Registry, actor);
    onStart();
    await run();
    return stop();
}

async function scenarioA(Registry, {ms = SCENARIO_MS, onStart, ...client} = {}) {
    const {process, actor, window} = await startClient(false, client);
    const menu = Main.panel.statusArea.quickSettings.menu;
    try {
        place(window, OVER_DOCK_AND_POPOVERS);
        menu.open(BoxPointer.PopupAnimation.NONE);
        await Scripting.sleep(SETTLE_MS);
        return await measure(Registry, actor, () => Scripting.sleep(ms), onStart);
    } finally {
        menu.close(BoxPointer.PopupAnimation.NONE);
        process.force_exit();
    }
}

async function drag(window, from, to, ms, onStep) {
    const steps = Math.round(ms / B_LEGS.length / STEP_MS);
    for (let i = 0; i <= steps; i++) {
        const t = i / steps;
        window.move_frame(false, Math.round(from[0] + (to[0] - from[0]) * t), Math.round(from[1] + (to[1] - from[1]) * t));
        if (i > 0)
            onStep(window);
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(STEP_MS);
    }
}

async function scenarioB(Registry, {ms = SCENARIO_MS, onStart, onStep = () => {}, ...client} = {}) {
    const {process, actor, window} = await startClient(true, client);
    try {
        place(window, {x: B_LEGS[0].from[0], y: B_LEGS[0].from[1], ...DRAG_SIZE});
        await Scripting.sleep(SETTLE_MS);
        return await measure(Registry, actor, async () => {
            for (const leg of B_LEGS) {
                const menu = leg.popover ? Main.panel.statusArea[leg.popover].menu : null;
                menu?.open(BoxPointer.PopupAnimation.NONE);
                window.move_frame(false, ...leg.from);
                // eslint-disable-next-line no-await-in-loop
                await Scripting.sleep(SETTLE_MS);
                // eslint-disable-next-line no-await-in-loop
                await drag(window, leg.from, leg.to, ms, onStep);
                menu?.close(BoxPointer.PopupAnimation.NONE);
            }
        }, onStart);
    } finally {
        process.force_exit();
    }
}

// C as far as S3a's scrims allow: the overview and the launcher over the playing window, then
// Spotlight over it. The scrims join the registry with them.
async function scenarioC(Registry, {ms = SCENARIO_MS, onStart, onStep = () => {}, ...client} = {}) {
    const {process, actor, window} = await startClient(false, client);
    const spotlight = (await import(SPOTLIGHT_FEATURE).catch(() => null))?.popup();
    try {
        place(window, OVER_DOCK_AND_POPOVERS);
        await Scripting.sleep(SETTLE_MS);
        return await measure(Registry, actor, async () => {
            for (let i = 0; i < TOGGLES; i++) {
                if (i % 2)
                    Main.overview.showApps();
                else
                    Main.overview.show();
                onStep();
                // eslint-disable-next-line no-await-in-loop
                await Scripting.sleep(ms / TOGGLES / 2);
                Main.overview.hide();
                onStep();
                // eslint-disable-next-line no-await-in-loop
                await Scripting.sleep(ms / TOGGLES / 2);
            }
            spotlight?.open();
            onStep();
            await Scripting.sleep(ms / 2);
            spotlight?.close();
        }, onStart);
    } finally {
        Main.overview.hide();
        process.force_exit();
    }
}

// tests/laptop/scenarios.js runs these on the laptop: for MS each, on its display, with a callback per step.
export const SCENARIOS = {A: scenarioA, B: scenarioB, C: scenarioC};

async function withReduceTransparency(apex, on, run) {
    apex.set_boolean(REDUCE_TRANSPARENCY_KEY, on);
    await Scripting.sleep(SETTLE_MS);
    try {
        return await run();
    } finally {
        apex.reset(REDUCE_TRANSPARENCY_KEY);
    }
}

export async function glassLoadReport({dropStartupNotifications}) {
    dropStartupNotifications();
    const Registry = await import(GLASS_REGISTRY);
    const apex = new Gio.Settings({schema_id: APEX_SCHEMA});
    apex.set_boolean(DOCK_INTELLIHIDE_KEY, false);
    Main.overview.hide();
    await Scripting.sleep(SETTLE_MS);
    const scenarios = {};
    try {
        for (const [name, run] of [['A', scenarioA], ['B', scenarioB], ['C', scenarioC]]) {
            scenarios[name] = {
                // eslint-disable-next-line no-await-in-loop
                glass: await withReduceTransparency(apex, false, () => run(Registry)),
                // eslint-disable-next-line no-await-in-loop
                reduceTransparency: await withReduceTransparency(apex, true, () => run(Registry)),
            };
        }
    } finally {
        apex.reset(DOCK_INTELLIHIDE_KEY);
    }
    return {scenarioMs: SCENARIO_MS, toggles: TOGGLES, scenarios};
}

// The real-box stress: scenario A for as long as asked, every frame checked as above.
export async function realBoxStress(seconds, {dropStartupNotifications}) {
    dropStartupNotifications();
    const Registry = await import(GLASS_REGISTRY);
    const apex = new Gio.Settings({schema_id: APEX_SCHEMA});
    apex.set_boolean(DOCK_INTELLIHIDE_KEY, false);
    Main.overview.hide();
    const {process, actor, window} = await startClient(false);
    const menu = Main.panel.statusArea.quickSettings.menu;
    try {
        place(window, OVER_DOCK_AND_POPOVERS);
        menu.open(BoxPointer.PopupAnimation.NONE);
        await Scripting.sleep(SETTLE_MS);
        return {seconds, ...await measure(Registry, actor, () => Scripting.sleep(seconds * 1000))};
    } finally {
        menu.close(BoxPointer.PopupAnimation.NONE);
        process.force_exit();
        apex.reset(DOCK_INTELLIHIDE_KEY);
    }
}
