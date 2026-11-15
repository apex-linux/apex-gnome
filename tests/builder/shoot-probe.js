// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for shoot.sh: board 40's Apex Code, captured at the board's window geometry.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');
Gio._promisify(Gio.Subprocess.prototype, 'wait_async');
Gio._promisify(Gio.Subprocess.prototype, 'communicate_utf8_async');

const WINDOW = {x: 100, y: 48, width: 1240, height: 762};
const WINDOW_WAIT_MS = 60000;
const SETTLE_MS = 6000;
const env = name => GLib.getenv(name);
// The nodes each capture must name, as run.sh's lane checks have them.
const NAMED = [{role: 'text', name: 'Editor for dock.js'}, {role: 'list', name: 'Project Tree'},
    {role: 'page tab list', name: 'Sidebar views'}, {role: 'page tab', name: 'Project'}];

function builderWindows() {
    return global.get_window_actors().map(a => a.meta_window)
        .filter(w => w.get_window_type() === 0 && `${w.get_wm_class()}`.includes('Builder'));
}

async function spawnWait(argv) {
    const proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
    await proc.wait_async(null);
}

// The window where the board puts it; the shell may place it below the top bar first.
async function place(window) {
    window.unmaximize(3);
    for (let i = 0; i < 20; i++) {
        window.move_resize_frame(false, WINDOW.x, WINDOW.y, WINDOW.width, WINDOW.height);
        await Scripting.sleep(250);
        const r = window.get_frame_rect();
        if (r.x === WINDOW.x && r.y === WINDOW.y && r.width === WINDOW.width && r.height === WINDOW.height)
            return;
    }
    const r = window.get_frame_rect();
    throw new Error(`the window stays at ${r.x},${r.y} ${r.width}x${r.height}, not the board's`);
}

async function names() {
    const proc = Gio.Subprocess.new(['python3', env('APEX_BUILDER_ATSPI')],
        Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
    const [stdout, stderr] = await proc.communicate_utf8_async(null, null);
    if (!proc.get_successful())
        throw new Error(`atspi.py: ${stderr.trim()}`);
    return JSON.parse(stdout.trim().split('\n').at(-1)).nodes;
}

async function capture(window) {
    const name = `${env('APEX_SHOT')}.png`;
    const stream = Gio.File.new_for_path(GLib.build_filenamev([env('APEX_SHOTS'), name]))
        .replace(null, false, Gio.FileCreateFlags.NONE, null);
    const r = window.get_frame_rect();
    try {
        await new Shell.Screenshot().screenshot_area(r.x, r.y, r.width, r.height, stream);
    } finally {
        stream.close(null);
    }
    return name;
}

async function shoot() {
    Main.overview.hide();
    const project = env('APEX_BUILDER_PROJECT');
    Gio.Subprocess.new(['gnome-builder', '-p', project], Gio.SubprocessFlags.NONE);
    for (let i = 0; i < WINDOW_WAIT_MS / 100 && builderWindows().length === 0; i++)
        await Scripting.sleep(100);
    const [window] = builderWindows();
    if (!window)
        throw new Error(`no Apex Code window ${WINDOW_WAIT_MS} ms after gnome-builder -p ${project}`);
    await Scripting.sleep(SETTLE_MS);
    await spawnWait(['gnome-builder', `${project}/${env('APEX_BUILDER_FILE')}`]);
    await place(window);
    await Scripting.sleep(SETTLE_MS);
    await place(window);
    const r = window.get_frame_rect();
    const shot = await capture(window);
    const nodes = await names();
    GLib.file_set_contents(GLib.build_filenamev([env('APEX_SHOTS'), `${env('APEX_SHOT')}.names.json`]),
        JSON.stringify(nodes, null, 1));
    const missing = NAMED.filter(n => !nodes.some(m => m.role === n.role && m.name === n.name));
    if (missing.length)
        throw new Error(`no ${missing.map(n => `${n.role} named "${n.name}"`).join(', ')}`);
    console.log(`APEXBUILDERSHOT ${JSON.stringify({shot, frame: [r.x, r.y, r.width, r.height]})}`);
}

// main.js connects to startup-complete only after importing this module, so a startup that
// completes during the import would never run the script and leave the shell up.
export function init() {
    if (Main.layoutManager._startingUp)
        return;
    import(import.meta.url).then(self => Scripting.runPerfScript(self, GLib.getenv('SHELL_PERF_OUTPUT')));
}

export async function run() {
    try {
        await shoot();
    } catch (e) {
        console.log(`APEXBUILDERSHOT-ERROR ${e.message}\n${e.stack}`);
    }
}
