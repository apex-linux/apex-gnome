// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for shoot.sh: the board's sessions, typed into a real Ptyxis.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');

const WINDOW = {x: 100, y: 48, width: 1240, height: 762};
const SHELL_START_MS = 2500;
const SETTLE_MS = 3000;
const WINDOW_WAIT_MS = 30000;

const SESSIONS = [
    {dir: 'src/apex-gnome', command: 'claude'},
    {dir: 'apex-image', command: 'just vm-image'},
    {dir: 'src/apex-system', command: 'cargo test --workspace'},
    {dir: 'src/apex-desktop', command: 'rpmbuild -bb packaging/apex-desktop.spec'},
    {dir: '', command: 'ssh builder@apex-builder'},
];
const SELECTED_SESSION = 2;

let keyboard;

function tap(keyval, modifiers = []) {
    const now = () => GLib.get_monotonic_time();
    for (const m of modifiers)
        keyboard.notify_keyval(now(), m, Clutter.KeyState.PRESSED);
    keyboard.notify_keyval(now(), keyval, Clutter.KeyState.PRESSED);
    keyboard.notify_keyval(now(), keyval, Clutter.KeyState.RELEASED);
    for (const m of modifiers.reverse())
        keyboard.notify_keyval(now(), m, Clutter.KeyState.RELEASED);
}

async function type(text) {
    for (const ch of text) {
        tap(Clutter.unicode_to_keysym(ch.codePointAt(0)));
        await Scripting.sleep(15);
    }
    tap(Clutter.KEY_Return);
}

function ptyxisWindows() {
    return global.get_window_actors().map(a => a.meta_window)
        .filter(w => `${w.get_wm_class()} ${w.get_gtk_application_id()}`.includes('Ptyxis'));
}

async function launch(args) {
    Gio.Subprocess.new(['ptyxis', ...args], Gio.SubprocessFlags.NONE);
    for (let i = 0; i < WINDOW_WAIT_MS / 100 && ptyxisWindows().length === 0; i++)
        await Scripting.sleep(100);
    if (ptyxisWindows().length === 0)
        throw new Error(`no Ptyxis window ${WINDOW_WAIT_MS} ms after ptyxis ${args.join(' ')}`);
    await Scripting.sleep(SHELL_START_MS);
}

async function capture(window) {
    const dir = GLib.getenv('APEX_SHOTS');
    const name = `${GLib.getenv('APEX_SHOT')}.png`;
    const stream = Gio.File.new_for_path(GLib.build_filenamev([dir, name]))
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
    keyboard = global.stage.context.get_backend().get_default_seat()
        .create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    Main.overview.hide();
    await Scripting.sleep(500);
    const home = GLib.get_home_dir();

    for (const [i, session] of SESSIONS.entries()) {
        const dir = GLib.build_filenamev([home, session.dir]);
        await launch(i === 0 ? ['--new-window', '-d', dir] : ['--tab', '-d', dir]);
        if (i === 0) {
            const [window] = ptyxisWindows();
            window.move_resize_frame(false, WINDOW.x, WINDOW.y, WINDOW.width, WINDOW.height);
        }
        await type(session.command);
        await Scripting.sleep(500);
    }

    tap(Clutter.KEY_1 + SELECTED_SESSION - 1, [Clutter.KEY_Alt_L]);
    await Scripting.sleep(SETTLE_MS);

    const [window] = ptyxisWindows();
    const r = window.get_frame_rect();
    console.log(`APEXPTYXIS ${JSON.stringify({shot: await capture(window), frame: [r.x, r.y, r.width, r.height]})}`);
}

// main.js connects to startup-complete only after importing this module, so a startup that
// completes during the import would never run the script and leave the shell up.
export function init() {
    if (Main.layoutManager._startingUp)
        return;
    console.log('APEXPTYXIS-LATE startup completed while main.js imported the probe');
    import(import.meta.url).then(self => Scripting.runPerfScript(self, GLib.getenv('SHELL_PERF_OUTPUT')));
}

export async function run() {
    try {
        await shoot();
    } catch (e) {
        console.log(`APEXPTYXIS-ERROR ${e.message}\n${e.stack}`);
    }
}
