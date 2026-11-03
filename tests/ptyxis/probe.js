// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for shoot.sh: the board's sessions, typed into a real Ptyxis.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');
Gio._promisify(Gio.Subprocess.prototype, 'communicate_utf8_async');

const WINDOW = {x: 100, y: 48, width: 1240, height: 762};
const SHELL_START_MS = 2500;
const SETTLE_MS = 3000;
const WINDOW_WAIT_MS = 30000;

// Board 32 selects apex-image; board 33 splits apex-gnome to the right and runs git in the second pane.
const SCENES = {
    sessions: {selected: 2, split: null},
    split: {selected: 1, split: {keyval: 'r', command: 'git status --short'}},
};
const SESSIONS = [
    {dir: 'src/apex-gnome', command: 'claude'},
    {dir: 'apex-image', command: 'just vm-image'},
    {dir: 'src/apex-system', command: 'cargo test --workspace'},
    {dir: 'src/apex-desktop', command: 'rpmbuild -bb packaging/apex-desktop.spec'},
    {dir: '', command: 'ssh builder@apex-builder'},
];

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
    const scene = SCENES[GLib.getenv('APEX_SCENE') ?? 'sessions'];

    for (const [i, session] of SESSIONS.entries()) {
        const dir = GLib.build_filenamev([home, session.dir]);
        await launch(i === 0 ? ['--new-window', '-d', dir] : ['--tab', '-d', dir]);
        if (i === 0) {
            const [window] = ptyxisWindows();
            window.move_resize_frame(false, WINDOW.x, WINDOW.y, WINDOW.width, WINDOW.height);
        }
        await type(session.command);
        await Scripting.sleep(500);
        if (i === 0 && scene.split) {
            tap(Clutter.unicode_to_keysym(scene.split.keyval.codePointAt(0)), [Clutter.KEY_Control_L, Clutter.KEY_Alt_L]);
            await Scripting.sleep(SHELL_START_MS);
            await type(scene.split.command);
            await Scripting.sleep(500);
        }
    }

    tap(Clutter.KEY_1 + scene.selected - 1, [Clutter.KEY_Alt_L]);
    await Scripting.sleep(SETTLE_MS);

    const [window] = ptyxisWindows();
    window.move_resize_frame(false, WINDOW.x, WINDOW.y, WINDOW.width, WINDOW.height);
    await Scripting.sleep(SETTLE_MS);
    const r = window.get_frame_rect();
    const shot = await capture(window);
    await writeTargets();
    console.log(`APEXPTYXIS ${JSON.stringify({shot, frame: [r.x, r.y, r.width, r.height]})}`);
}

// contrast-test.sh's targets, read over AT-SPI once the capture is taken, when shoot.sh asks.
async function writeTargets() {
    const helper = GLib.getenv('APEX_SHOT_ATSPI');
    if (!helper)
        return;
    const proc = Gio.Subprocess.new(['python3', helper], Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
    const [stdout, stderr] = await proc.communicate_utf8_async(null, null);
    if (!proc.get_successful())
        throw new Error(`${helper} exited ${proc.get_exit_status()}: ${stderr}`);
    const path = GLib.build_filenamev([GLib.getenv('APEX_SHOTS'), `${GLib.getenv('APEX_SHOT')}.targets.json`]);
    GLib.file_set_contents(path, stdout);
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
