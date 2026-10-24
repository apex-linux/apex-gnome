// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for palette-test.sh: a palette file rewritten under an open terminal.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Shell.Screenshot.prototype, 'pick_color');

const WINDOW_WAIT_MS = 30000;
const SHELL_START_MS = 3000;
const POLL_MS = 50;
const GIVE_UP_MS = 3000;

function ptyxisWindow() {
    return global.get_window_actors().map(a => a.meta_window)
        .find(w => `${w.get_wm_class()} ${w.get_gtk_application_id()}`.includes('Ptyxis'));
}

async function terminalColor(window) {
    const r = window.get_frame_rect();
    const picked = await new Shell.Screenshot().pick_color(r.x + r.width / 2, r.y + r.height * 0.75);
    const color = Array.isArray(picked) ? picked.at(-1) : picked;
    const channel = name => color[`get_${name}`]?.() ?? color[name];
    return ['red', 'green', 'blue'].map(name => Math.round(channel(name) <= 1 ? channel(name) * 255 : channel(name)));
}

async function measure() {
    Main.overview.hide();
    Gio.Subprocess.new(['ptyxis', '--new-window'], Gio.SubprocessFlags.NONE);
    let window;
    for (let waited = 0; !(window = ptyxisWindow()) && waited < WINDOW_WAIT_MS; waited += 100)
        await Scripting.sleep(100);
    if (!window)
        throw new Error(`no Ptyxis window ${WINDOW_WAIT_MS} ms after ptyxis --new-window`);
    await Scripting.sleep(SHELL_START_MS);

    const before = await terminalColor(window);
    const rewritten = GLib.getenv('APEX_PALETTE_REWRITE');
    const [, contents] = GLib.file_get_contents(rewritten);
    GLib.file_set_contents(GLib.getenv('APEX_PALETTE_FILE'), contents);
    const start = GLib.get_monotonic_time();

    let after = before;
    let ms = 0;
    while (ms < GIVE_UP_MS && after.every((v, i) => v === before[i])) {
        await Scripting.sleep(POLL_MS);
        after = await terminalColor(window);
        ms = Math.round((GLib.get_monotonic_time() - start) / 1000);
    }
    return {before, after, ms};
}

// main.js connects to startup-complete only after importing this module, so a startup that
// completes during the import would never run the script and leave the shell up.
export function init() {
    if (Main.layoutManager._startingUp)
        return;
    import(import.meta.url).then(self => Scripting.runPerfScript(self, GLib.getenv('SHELL_PERF_OUTPUT')));
}

export async function run() {
    let result;
    try {
        result = await measure();
    } catch (e) {
        result = {error: `${e.message}\n${e.stack}`};
    }
    console.log(`APEXPALETTE ${JSON.stringify(result)}`);
}
