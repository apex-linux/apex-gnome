// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for shoot.sh: one Files window at board 27's geometry.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');
Gio._promisify(Gio.Subprocess.prototype, 'wait_check_async');

const WINDOW = {x: 100, y: 48, width: 1240, height: 762};
const MAP_MS = 2500;
const SETTLE_MS = 4000;
const WINDOW_WAIT_MS = 30000;

function filesWindows() {
    return global.get_window_actors().map(a => a.meta_window)
        .filter(w => `${w.get_wm_class()} ${w.get_gtk_application_id()}`.includes('Nautilus'));
}

async function launch(args) {
    Gio.Subprocess.new(['nautilus', ...args], Gio.SubprocessFlags.NONE);
    for (let i = 0; i < WINDOW_WAIT_MS / 100 && filesWindows().length === 0; i++)
        await Scripting.sleep(100);
    const [window] = filesWindows();
    if (!window)
        throw new Error(`no Files window ${WINDOW_WAIT_MS} ms after nautilus ${args.join(' ')}`);
    return window;
}

async function capture(window, name) {
    const stream = Gio.File.new_for_path(GLib.build_filenamev([GLib.getenv('APEX_SHOTS'), name]))
        .replace(null, false, Gio.FileCreateFlags.NONE, null);
    const r = window.get_frame_rect();
    try {
        await new Shell.Screenshot().screenshot_area(r.x, r.y, r.width, r.height, stream);
    } finally {
        stream.close(null);
    }
}

async function shoot() {
    Main.overview.hide();
    await Scripting.sleep(500);
    const shot = GLib.getenv('APEX_SHOT');
    const window = await launch(JSON.parse(GLib.getenv('APEX_FILES_ARGS')));
    await Scripting.sleep(MAP_MS);
    window.move_resize_frame(false, WINDOW.x, WINDOW.y, WINDOW.width, WINDOW.height);
    await Scripting.sleep(SETTLE_MS);
    const r = window.get_frame_rect();
    if (r.width !== WINDOW.width || r.height !== WINDOW.height)
        throw new Error(`the window is ${r.width}x${r.height}, not ${WINDOW.width}x${WINDOW.height}`);

    const tree = GLib.build_filenamev([GLib.getenv('APEX_SHOTS'), `${shot}.a11y.json`]);
    await Gio.Subprocess.new(['python3', GLib.getenv('APEX_A11Y'), tree], Gio.SubprocessFlags.NONE)
        .wait_check_async(null);
    await capture(window, `${shot}.png`);
    console.log(`APEXFILES ${JSON.stringify({shot: `${shot}.png`, frame: [r.x, r.y, r.width, r.height]})}`);
}

// main.js connects to startup-complete only after importing this module, so a startup that
// completes during the import would never run the script and leave the shell up.
export function init() {
    if (Main.layoutManager._startingUp)
        return;
    console.log('APEXFILES-LATE startup completed while main.js imported the probe');
    import(import.meta.url).then(self => Scripting.runPerfScript(self, GLib.getenv('SHELL_PERF_OUTPUT')));
}

export async function run() {
    try {
        await shoot();
    } catch (e) {
        console.log(`APEXFILES-ERROR ${e.message}\n${e.stack}`);
    }
}
