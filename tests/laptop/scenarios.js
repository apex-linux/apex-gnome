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
const POPOVERS = ['quickSettings', 'dateMenu'];
// Inside the popovers' rounded corners, so a window under a corner never counts as covered.
const CORNER_INSET = 26;

function box(actor) {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    return {x, y, width, height};
}

function inside(a, b) {
    return a.x >= b.x && a.y >= b.y && a.x + a.width <= b.x + b.width && a.y + a.height <= b.y + b.height;
}

// The window's whole buffer, its client-side shadow included, under one open popover's card.
function step(window, last) {
    const at = GLib.get_monotonic_time();
    const actor = window?.get_compositor_private();
    if (!actor)
        return [at, null];
    const drawn = box(actor);
    if (last && JSON.stringify(drawn) === JSON.stringify(last[2]))
        return null;
    const under = POPOVERS.map(name => Main.panel.statusArea[name]?.menu).filter(menu => menu?.isOpen).map(menu => {
        const card = box(menu.box);
        return {
            x: card.x + CORNER_INSET,
            y: card.y + CORNER_INSET,
            width: card.width - 2 * CORNER_INSET,
            height: card.height - 2 * CORNER_INSET,
        };
    });
    return [at, under.some(card => inside(drawn, card)) ? 'covered' : 'visible', drawn];
}

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
            onStep: window => {
                // A move the work area's constraints refuse changes nothing, so it is no step.
                const taken = step(window, steps.at(-1));
                if (taken)
                    steps.push(taken);
            },
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
