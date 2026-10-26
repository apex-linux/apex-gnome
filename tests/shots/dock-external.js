// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's dock-external case (G2_DOCK_EXTERNAL=1): two virtual monitors. The dock and the bar stay on the
// primary, only its windows hide the dock or turn the bar solid, and both follow a new primary.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

import {settleDesktop, until} from './idle.js';

const WINDOW_TITLE = 'G2 maximised window';
const WINDOW_TIMEOUT_MS = 15000;
const SLIDE_MS = 3000;
const SOLID_BAR_STYLE_CLASS = 'apex-solid-bar';
const SCRIM_NAME = 'apexGlassScrim';
const LAUNCHER_STYLE_CLASS = 'apex-launcher';
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

// The scrim, and the overview's view of each monitor: stock shows one per monitor.
function overviewState() {
    const scrim = Main.uiGroup.get_children().find(actor => actor.name === SCRIM_NAME) ?? null;
    const views = Main.overview._overview.controls._workspacesDisplay._workspacesViews ?? [];
    return {
        shown: Main.overview.visible,
        controlsState: Main.overview._overview.controls._stateAdjustment.value,
        scrim: scrim ? {visible: scrim.visible, box: transformedRect(scrim), launcher: scrim.has_style_class_name(LAUNCHER_STYLE_CLASS)} : null,
        views: views.map(view => transformedRect(view)),
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

// The current layout with the primary flag moved to the other logical monitor.
async function swapPrimary() {
    const [serial, monitors, logical] = await call('GetCurrentState', null);
    const currentMode = new Map(monitors.map(([[connector], modes]) =>
        [connector, modes.find(([, , , , , , props]) => props['is-current']?.deepUnpack())?.[0]]));
    const swapped = logical.map(([x, y, scale, transform, primary, specs]) =>
        [x, y, scale, transform, !primary, specs.map(([connector]) => [connector, currentMode.get(connector), {}])]);
    await call('ApplyMonitorsConfig', new GLib.Variant('(uua(iiduba(ssa{sv}))a{sv})', [serial, TEMPORARY, swapped, {}]));
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
        steps.overview = overviewState();
        Main.overview.hide();
        await helpers.settle();
        Main.overview.showApps();
        await helpers.settle();
        steps.launcher = overviewState();
        Main.overview.hide();
        await helpers.settle();

        try {
            const changed = new Promise(resolve => {
                const id = Main.layoutManager.connect('monitors-changed', () => {
                    Main.layoutManager.disconnect(id);
                    resolve(true);
                });
            });
            await swapPrimary();
            steps.swapped = {changed: await Promise.race([changed, Scripting.sleep(WINDOW_TIMEOUT_MS).then(() => false)])};
            await Scripting.sleep(SLIDE_MS);
            await helpers.settle();
            Object.assign(steps.swapped, layout(apexDock), {dock: helpers.dockReport()});
        } catch (e) {
            steps.swapped = {refused: e.message};
        }
    } finally {
        client.force_exit();
    }
    return {settled, steps};
}
