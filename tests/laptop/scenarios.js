// SPDX-License-Identifier: GPL-3.0-or-later
//
// The laptop glass protocol's side in the logged-in shell, imported through Eval by glass_protocol.py:
// one of glass-load.js's scenarios for as long as asked, its times written to a JSON file at the end.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

import {SCENARIOS} from '../shots/glass-load.js';

const GLASS_REGISTRY = 'resource:///org/gnome/shell/ui/apex/glass/registry.js';
const APEX_SCHEMA = 'io.github.apex_linux.Apex.Desktop';
const DOCK_INTELLIHIDE_KEY = 'dock-intellihide';
const SETTLE_MS = 1500;

function writeJson(path, value) {
    Gio.File.new_for_path(path).replace_contents(JSON.stringify(value), null, false,
        Gio.FileCreateFlags.REPLACE_DESTINATION, null);
}

// The owner's own dock setting comes back afterwards, whatever it was.
async function run(name, {seconds, out, measure, display}) {
    const apex = new Gio.Settings({schema_id: APEX_SCHEMA});
    const intellihide = apex.get_boolean(DOCK_INTELLIHIDE_KEY);
    const steps = [];
    const result = {scenario: name, seconds, steps};
    try {
        const Registry = await import(GLASS_REGISTRY);
        apex.set_boolean(DOCK_INTELLIHIDE_KEY, false);
        Main.overview.hide();
        await Scripting.sleep(SETTLE_MS);
        result.work = await SCENARIOS[name](Registry, {
            ms: seconds * 1000,
            display,
            clientArgs: [`measure=${measure}`],
            onStart: () => (result.startUs = GLib.get_monotonic_time()),
            onStep: () => steps.push(GLib.get_monotonic_time()),
        });
        result.endUs = GLib.get_monotonic_time();
    } catch (e) {
        result.error = `${e}`;
    } finally {
        apex.set_boolean(DOCK_INTELLIHIDE_KEY, intellihide);
        writeJson(out, result);
    }
}

export function start(name, options) {
    run(name, options).catch(logError);
    return 'started';
}
