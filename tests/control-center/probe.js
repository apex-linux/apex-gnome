// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for run.sh: opens a Settings page (APEX_OPEN), captures it, runs a checker (APEX_CHECK).
// APEX_LAUNCH prefixes the command, as umockdev-run does for Power's graphics card.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');
Gio._promisify(Gio.Subprocess.prototype, 'wait_check_async');
Gio._promisify(Gio.Subprocess.prototype, 'communicate_utf8_async');

// Board 11's Settings window, in the logical pixels of its 1440 × 900 desktop.
const WINDOW = {x: 170, y: 64, width: 1100, height: 730};
const SETTLE_MS = 3000;
const WINDOW_WAIT_MS = 30000;

function settingsWindows() {
    return global.get_window_actors().map(a => a.meta_window)
        .filter(w => `${w.get_wm_class()} ${w.get_gtk_application_id()}`.includes('org.gnome.Settings'));
}

async function capture(window, suffix) {
    const name = `${GLib.getenv('APEX_SHOT')}${suffix}.png`;
    const stream = Gio.File.new_for_path(GLib.build_filenamev([GLib.getenv('APEX_SHOTS'), name]))
        .replace(null, false, Gio.FileCreateFlags.NONE, null);
    const r = window.get_frame_rect();
    try {
        await new Shell.Screenshot().screenshot_area(r.x, r.y, r.width, r.height, stream);
    } finally {
        stream.close(null);
    }
    return name;
}

async function scrollToEnd(window) {
    const pointer = global.stage.context.get_backend().get_default_seat()
        .create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
    const r = window.get_frame_rect();
    const now = () => GLib.get_monotonic_time();
    pointer.notify_absolute_motion(now(), r.x + r.width * 0.65, r.y + r.height / 2);
    await Scripting.sleep(500);
    // A new virtual pointer starts in the top-left corner, so its first motion can trip the hot corner.
    Main.overview.hide();
    await Scripting.sleep(1000);
    pointer.notify_absolute_motion(now(), r.x + r.width * 0.65 + 4, r.y + r.height / 2 + 4);
    await Scripting.sleep(300);
    for (let i = 0; i < 40; i++) {
        pointer.notify_discrete_scroll(now(), Clutter.ScrollDirection.DOWN, Clutter.ScrollSource.WHEEL);
        await Scripting.sleep(30);
    }
}

// APEX_CLICK's locator prints "APEXCC-AT x y" in window coordinates: a row AT-SPI cannot activate gets a click.
async function clickLocated(window, command) {
    const [script, ...args] = command.split(' ');
    const proc = Gio.Subprocess.new(['python3', GLib.build_filenamev([GLib.getenv('CC_TESTS'), script]), ...args],
        Gio.SubprocessFlags.STDOUT_PIPE);
    const [stdout] = await proc.communicate_utf8_async(null, null);
    const at = stdout.match(/^APEXCC-AT (\d+) (\d+)$/m);
    if (!at)
        return false;
    const r = window.get_buffer_rect();
    const pointer = global.stage.context.get_backend().get_default_seat()
        .create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
    const now = () => GLib.get_monotonic_time();
    // The seat drops a new pointer's first motion, so it moves twice.
    for (let i = 0; i < 2; i++) {
        pointer.notify_absolute_motion(now(), r.x + Number(at[1]), r.y + Number(at[2]));
        await Scripting.sleep(100);
    }
    pointer.notify_button(now(), Clutter.BUTTON_PRIMARY, Clutter.ButtonState.PRESSED);
    pointer.notify_button(now(), Clutter.BUTTON_PRIMARY, Clutter.ButtonState.RELEASED);
    await Scripting.sleep(SETTLE_MS);
    return true;
}

async function check(command) {
    const [script, ...args] = command.split(' ');
    const proc = Gio.Subprocess.new(['python3', GLib.build_filenamev([GLib.getenv('CC_TESTS'), script]), ...args],
        Gio.SubprocessFlags.NONE);
    try {
        await proc.wait_check_async(null);
        return true;
    } catch {
        return false;
    }
}

async function probe() {
    Main.overview.hide();
    await Scripting.sleep(500);
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
    const page = (GLib.getenv('APEX_OPEN') ?? 'apex').split(' ');
    const prefix = (GLib.getenv('APEX_LAUNCH') ?? '').split(' ').filter(word => word);
    launcher.spawnv([...prefix, 'gnome-control-center', ...page]);
    for (let i = 0; i < WINDOW_WAIT_MS / 100 && settingsWindows().length === 0; i++)
        await Scripting.sleep(100);
    const [window] = settingsWindows();
    if (!window)
        throw new Error(`no Settings window ${WINDOW_WAIT_MS} ms after gnome-control-center ${page.join(' ')}`);
    // The first resize can land before the window is mapped, so the second makes the size stick.
    for (let i = 0; i < 2; i++) {
        window.move_resize_frame(false, WINDOW.x, WINDOW.y, WINDOW.width, WINDOW.height);
        await Scripting.sleep(SETTLE_MS);
    }

    const command = GLib.getenv('APEX_CHECK');
    const result = {top: await capture(window, '')};
    if (GLib.getenv('APEX_SCROLL')) {
        await scrollToEnd(window);
        await Scripting.sleep(SETTLE_MS);
        result.scrolled = await capture(window, '-scrolled');
    }
    const click = GLib.getenv('APEX_CLICK');
    if (click)
        result.clicked = await clickLocated(window, click);
    if (command)
        result.check = result.clicked !== false && await check(command);
    const r = window.get_frame_rect();
    result.frame = [r.x, r.y, r.width, r.height];
    console.log(`APEXCC ${JSON.stringify(result)}`);
}

// main.js connects to startup-complete only after importing this module, so a startup that
// completes during the import would never run the script and leave the shell up.
export function init() {
    if (Main.layoutManager._startingUp)
        return;
    console.log('APEXCC-LATE startup completed while main.js imported the probe');
    import(import.meta.url).then(self => Scripting.runPerfScript(self, GLib.getenv('SHELL_PERF_OUTPUT')));
}

export async function run() {
    try {
        await probe();
    } catch (e) {
        console.log(`APEXCC-ERROR ${e.message}\n${e.stack}`);
    }
}
