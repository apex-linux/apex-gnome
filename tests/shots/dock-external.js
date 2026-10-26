// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's dock-external case (G2_DOCK_EXTERNAL=1): two virtual monitors. The dock and the bar stay on the
// primary, only its windows hide the dock or turn the bar solid, and both follow a new primary.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

import {modelledMs} from './glass-load.js';
import {settleDesktop, until} from './idle.js';

const WINDOW_TITLE = 'G2 maximised window';
const WINDOW_TIMEOUT_MS = 15000;
const SLIDE_MS = 3000;
const SOLID_BAR_STYLE_CLASS = 'apex-solid-bar';
const SCRIM_NAME = 'apexGlassScrim';
const LAUNCHER_STYLE_CLASS = 'apex-launcher';
const GLASS_EFFECT = 'apex-glass';
const DISPLAY_CONFIG = ['org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig', 'org.gnome.Mutter.DisplayConfig'];
// ApplyMonitorsConfig's method: temporary, as Settings applies before the user keeps it.
const TEMPORARY = 1;

const rect = ({x, y, width, height}) => ({x, y, width, height});

function transformedRect(actor) {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    return {x: Math.round(x), y: Math.round(y), width: Math.round(width), height: Math.round(height)};
}

function testWindow() {
    return global.display.list_all_windows().find(w => w.title === WINDOW_TITLE) ?? null;
}

function layout(apexDock) {
    const box = apexDock().get_parent();
    const monitors = Main.layoutManager.monitors.map(m => ({...rect(m), index: m.index}));
    return {
        primary: Main.layoutManager.primaryIndex,
        monitors,
        dockBox: transformedRect(box),
        dockHidden: box.translation_y > 0,
        panelBox: transformedRect(Main.layoutManager.panelBox),
        barSolid: Main.panel.has_style_class_name(SOLID_BAR_STYLE_CLASS),
        window: testWindow() ? {monitor: testWindow().get_monitor(), maximised: testWindow().is_maximized()} : null,
    };
}

async function placeWindow(monitor, apexDock) {
    const window = testWindow();
    window.move_to_monitor(monitor);
    window.maximize();
    await until(() => window.get_monitor() === monitor && window.is_maximized(), WINDOW_TIMEOUT_MS);
    await Scripting.sleep(SLIDE_MS);
    return layout(apexDock);
}

function scrimActors() {
    return Main.uiGroup.get_children().filter(actor => actor.name === SCRIM_NAME);
}

// The scrims, one per monitor, and the overview's view of each monitor: stock shows one per monitor.
function overviewState() {
    const views = Main.overview._overview.controls._workspacesDisplay._workspacesViews ?? [];
    return {
        shown: Main.overview.visible,
        controlsState: Main.overview._overview.controls._stateAdjustment.value,
        scrims: scrimActors().map(scrim => ({visible: scrim.visible, box: transformedRect(scrim), launcher: scrim.has_style_class_name(LAUNCHER_STYLE_CLASS)})),
        monitors: Main.layoutManager.monitors.map(rect),
        views: views.map(view => transformedRect(view)),
        stage: {x: 0, y: 0, width: global.stage.width, height: global.stage.height},
    };
}

function call(method, parameters) {
    return new Promise((resolve, reject) => Gio.DBus.session.call(...DISPLAY_CONFIG, method, parameters, null,
        Gio.DBusCallFlags.NONE, -1, null, (bus, result) => {
            try {
                resolve(bus.call_finish(result).deepUnpack());
            } catch (e) {
                reject(e);
            }
        }));
}

// Logical monitors as ApplyMonitorsConfig takes them, from GetCurrentState: each with its
// connector's current mode and physical size.
async function currentLayout() {
    const [serial, monitors, logical] = await call('GetCurrentState', null);
    const current = new Map(monitors.map(([[connector], modes]) => {
        const mode = modes.find(([, , , , , , props]) => props['is-current']?.deepUnpack());
        return [connector, {id: mode?.[0], width: mode?.[1], height: mode?.[2]}];
    }));
    return {
        serial, logical: logical.map(([x, y, scale, transform, primary, specs]) =>
            ({x, y, scale, transform, primary, connector: specs[0][0], mode: current.get(specs[0][0])})),
    };
}

async function applyLayout(serial, logical) {
    const config = logical.map(({x, y, scale, transform, primary, connector, mode}) =>
        [x, y, scale, transform, primary, [[connector, mode.id, {}]]]);
    await call('ApplyMonitorsConfig', new GLib.Variant('(uua(iiduba(ssa{sv}))a{sv})', [serial, TEMPORARY, config, {}]));
}

// Applies a layout and waits for the shell's monitors-changed, then for the dock to slide.
async function relayout(change, helpers) {
    const changed = new Promise(resolve => {
        const id = Main.layoutManager.connect('monitors-changed', () => {
            Main.layoutManager.disconnect(id);
            resolve(true);
        });
    });
    const {serial, logical} = await currentLayout();
    await applyLayout(serial, change(logical));
    const seen = await Promise.race([changed, Scripting.sleep(WINDOW_TIMEOUT_MS).then(() => false)]);
    await Scripting.sleep(SLIDE_MS);
    await helpers.settle();
    return seen;
}

// The panel at scale 2 on the left, the external display beside it at scale 1, as a laptop
// docked to a 1080p screen runs; the primary is the one named.
function mixed(primaryIsPanel) {
    return logical => {
        const [panel, external] = [...logical].sort((a, b) => b.mode.width - a.mode.width);
        return [
            {...panel, x: 0, y: 0, scale: 2, primary: primaryIsPanel},
            {...external, x: panel.mode.width / 2, y: 0, scale: 1, primary: !primaryIsPanel},
        ];
    };
}

function glass(actor) {
    const effect = actor?.get_effect(GLASS_EFFECT);
    return effect ? {radius: effect.radius, enabled: effect.enabled, resourceScale: actor.get_resource_scale(), box: transformedRect(actor)} : null;
}

// 0014-blurcost.py's ms per re-blur: each scrim at its own scale, against one stage-wide scrim
// at the views' highest scale, as before a scrim per monitor.
function scrimCost(scrims) {
    const blurred = scrims.filter(s => s.radius > 0);
    const scale = Math.max(...blurred.map(s => s.resourceScale));
    const sigma = Math.max(...blurred.map(s => s.radius / 2 / s.resourceScale));
    return {
        perMonitor: blurred.reduce((ms, s) => ms + modelledMs(s.box.width * s.resourceScale, s.box.height * s.resourceScale, s.radius / 2), 0),
        wholeStage: modelledMs(global.stage.width * scale, global.stage.height * scale, sigma * scale),
    };
}

function glassState(apexDock) {
    // Each clone paints window_group as it is, at its own size and place: an unscaled copy.
    const scrims = scrimActors().map(scrim => ({
        ...glass(scrim), clone: transformedRect(scrim.get_first_child()), source: transformedRect(global.window_group),
    }));
    return {dock: glass(apexDock()._background), bar: glass(Main.panel), scrims, cost: scrimCost(scrims)};
}

export async function dockExternalReport(helpers) {
    const settled = await settleDesktop(helpers);
    const {apexDock} = helpers;
    const steps = {initial: {...layout(apexDock), dock: helpers.dockReport()}};
    const secondary = steps.initial.monitors.find(m => m.index !== steps.initial.primary)?.index;
    if (secondary === undefined)
        throw new Error(`G2 runs ${steps.initial.monitors.length} monitor(s), not two`);
    const primary = steps.initial.primary;

    const here = GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0]);
    const client = Gio.Subprocess.new(['gjs', '-m', GLib.build_filenamev([here, 'maximised-window.js'])],
        Gio.SubprocessFlags.NONE);
    try {
        if (!await until(() => testWindow()?.get_compositor_private()?.mapped, WINDOW_TIMEOUT_MS))
            throw new Error('the maximised window never mapped');
        steps.onSecondary = await placeWindow(secondary, apexDock);
        steps.onPrimary = await placeWindow(primary, apexDock);
        steps.backOnSecondary = await placeWindow(secondary, apexDock);

        Main.overview.show();
        await helpers.settle();
        steps.overview = {...overviewState(), glass: glassState(apexDock)};
        Main.overview.hide();
        await helpers.settle();
        Main.overview.showApps();
        await helpers.settle();
        steps.launcher = overviewState();
        Main.overview.hide();
        await helpers.settle();

        steps.swapped = {changed: await relayout(logical => logical.map(m => ({...m, primary: !m.primary})), helpers)};
        Object.assign(steps.swapped, layout(apexDock), {dock: helpers.dockReport()});

        steps.mixedOnExternal = {changed: await relayout(mixed(false), helpers)};
        Object.assign(steps.mixedOnExternal, layout(apexDock), {dock: helpers.dockReport()});
        Main.overview.show();
        await helpers.settle();
        Object.assign(steps.mixedOnExternal, {overview: overviewState(), glass: glassState(apexDock)});
        Main.overview.hide();
        await helpers.settle();
        steps.mixedOnExternal.desktopGlass = glassState(apexDock);

        steps.mixed = {changed: await relayout(mixed(true), helpers)};
        Object.assign(steps.mixed, layout(apexDock), {dock: helpers.dockReport(), glass: glassState(apexDock)});
    } finally {
        client.force_exit();
    }
    return {settled, steps};
}
