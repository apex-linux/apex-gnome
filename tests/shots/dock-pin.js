// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's dock-pin case (G2_DOCK_PIN=1): a favourite pinned on a settled desktop. The dock shows it at once,
// and nothing repaints when main.js's 20 s fallback for deferred work comes round. tests/shots/README.md.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as AppFavorites from 'resource:///org/gnome/shell/ui/appFavorites.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

import {paintsOver, settleDesktop, until} from './idle.js';

const DOCK_UPDATE_MS = 3000;
// main.js runs an unmapped actor's deferred work 20 s after it is first queued.
const FALLBACK_WINDOW_MS = 21000;
const DEFERRED_SECONDS = 20;
const OVERVIEW_TIMEOUT_MS = 5000;
const APEX_SCHEMA = 'io.github.apex_linux.Apex.Desktop';
const DISABLED_FEATURES_KEY = 'disabled-features';

function appIds(dash) {
    return dash._box.get_children().map(item => item.child?._delegate?.app?.get_id?.()).filter(Boolean);
}

// The time main.js's fallback fires, so the window is shown to cover it.
function watchFallback(start) {
    const fired = [];
    const original = GLib.timeout_add_seconds_once;
    GLib.timeout_add_seconds_once = (priority, seconds, callback) => original.call(GLib, priority, seconds, () => {
        if (seconds === DEFERRED_SECONDS)
            fired.push(Math.round((GLib.get_monotonic_time() - start) / 1000));
        callback();
    });
    return () => {
        GLib.timeout_add_seconds_once = original;
        return fired;
    };
}

async function withoutDock(read) {
    const apex = new Gio.Settings({schema_id: APEX_SCHEMA});
    const disabled = apex.get_strv(DISABLED_FEATURES_KEY);
    apex.set_strv(DISABLED_FEATURES_KEY, [...disabled, 'dock']);
    await Scripting.sleep(DOCK_UPDATE_MS);
    try {
        return await read();
    } finally {
        apex.set_strv(DISABLED_FEATURES_KEY, disabled);
        await Scripting.sleep(DOCK_UPDATE_MS);
    }
}

export async function dockPinReport(helpers) {
    const settled = await settleDesktop(helpers);
    // Startup's own deferred work runs out first, so the windows below hold only the pin's.
    await Scripting.sleep(FALLBACK_WINDOW_MS);
    const favorites = AppFavorites.getAppFavorites();
    const apps = Shell.AppSystem.get_default();
    const pinned = apps.get_installed().filter(info => info.should_show()).map(info => info.get_id())
        .find(id => !favorites.isFavorite(id) && apps.lookup_app(id));
    if (!pinned)
        throw new Error('no installed app outside the favourites to pin');
    const start = GLib.get_monotonic_time();
    const stopWatching = watchFallback(start);
    let dockUpdate, fallback, dockApps;
    try {
        favorites.addFavorite(pinned);
        dockUpdate = await paintsOver(DOCK_UPDATE_MS);
        dockApps = appIds(helpers.apexDock());
        fallback = await paintsOver(FALLBACK_WINDOW_MS);
    } finally {
        favorites.removeFavorite(pinned);
    }
    const fallbackFiredMs = stopWatching();
    await Scripting.sleep(DOCK_UPDATE_MS);
    const stock = await withoutDock(async () => {
        Main.overview.show();
        const shown = await until(() => Main.overview.visible && Main.overview.dash.mapped, OVERVIEW_TIMEOUT_MS);
        await Scripting.sleep(DOCK_UPDATE_MS);
        const dash = Main.overview.dash;
        const result = {shown, dashApps: appIds(dash), favorites: favorites.getFavorites().map(app => app.get_id())};
        Main.overview.hide();
        return result;
    });
    return {
        settled, pinned, dockApps, dockUpdate: {afterPaints: dockUpdate.afterPaints},
        windowMs: {dockUpdate: DOCK_UPDATE_MS, fallback: FALLBACK_WINDOW_MS},
        fallbackFiredMs, fallback, stock,
    };
}
