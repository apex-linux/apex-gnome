// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for panes-test.sh: board 33's panes, driven in a real Ptyxis.

import Clutter from 'gi://Clutter';
import GdkPixbuf from 'gi://GdkPixbuf';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Gio.Subprocess.prototype, 'communicate_utf8_async');
Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');

const WINDOW = {x: 100, y: 48, width: 1240, height: 762};
const WINDOW_WAIT_MS = 30000;
const SHELL_START_MS = 2500;
const WAIT_MS = 10000;
const SETTLE_MS = 600;
// fixture.c: cargo and rpmbuild exit after 2 s, claude rings the bell after 4 s (sessions.sh).
const RUN_WAIT_MS = 6000;
const SCROLLBAR_FADE_MS = 1500;

let keyboard;
let pointer;
let window;

function tap(keyval, modifiers = []) {
    const now = () => GLib.get_monotonic_time();
    for (const m of modifiers)
        keyboard.notify_keyval(now(), m, Clutter.KeyState.PRESSED);
    keyboard.notify_keyval(now(), keyval, Clutter.KeyState.PRESSED);
    keyboard.notify_keyval(now(), keyval, Clutter.KeyState.RELEASED);
    for (const m of [...modifiers].reverse())
        keyboard.notify_keyval(now(), m, Clutter.KeyState.RELEASED);
}

async function type(text) {
    for (const ch of text) {
        tap(Clutter.unicode_to_keysym(ch.codePointAt(0)));
        await Scripting.sleep(15);
    }
    tap(Clutter.KEY_Return);
}

async function atspi(...args) {
    const proc = Gio.Subprocess.new(['python3', GLib.getenv('APEX_PANES_ATSPI'), ...args],
        Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
    const [stdout, stderr] = await proc.communicate_utf8_async(null, null);
    if (!proc.get_successful())
        throw new Error(`panes-atspi.py ${args.join(' ')}: ${stderr.trim()}`);
    return JSON.parse(stdout.trim().split('\n').at(-1));
}

const state = () => atspi('state');

async function until(what, check) {
    const start = GLib.get_monotonic_time();
    let s = await state();
    while (!check(s)) {
        if ((GLib.get_monotonic_time() - start) / 1000 > WAIT_MS)
            throw new Error(`${what}: not within ${WAIT_MS} ms; last state ${JSON.stringify(s)}`);
        await Scripting.sleep(200);
        s = await state();
    }
    await Scripting.sleep(SETTLE_MS);
    return state();
}

// AT-SPI gives Ptyxis's own coordinates; the stage's start at the window's frame.
function onStage([x, y, width, height]) {
    const r = window.get_frame_rect();
    return [r.x + x, r.y + y, width, height];
}

async function clickAt(box) {
    const [x, y, width, height] = onStage(box);
    const now = () => GLib.get_monotonic_time();
    pointer.notify_absolute_motion(now(), x + width / 2, y + height / 2);
    await Scripting.sleep(50);
    pointer.notify_button(now(), Clutter.BUTTON_PRIMARY, Clutter.ButtonState.PRESSED);
    pointer.notify_button(now(), Clutter.BUTTON_PRIMARY, Clutter.ButtonState.RELEASED);
}

async function pixels(box) {
    const [x, y, width, height] = onStage(box);
    const path = GLib.build_filenamev([GLib.get_tmp_dir(), `apex-panes-${GLib.get_monotonic_time()}.png`]);
    const stream = Gio.File.new_for_path(path).replace(null, false, Gio.FileCreateFlags.NONE, null);
    try {
        await new Shell.Screenshot().screenshot_area(x, y, width, height, stream);
    } finally {
        stream.close(null);
    }
    const pixbuf = GdkPixbuf.Pixbuf.new_from_file(path);
    GLib.unlink(path);
    const bytes = pixbuf.get_pixels();
    const n = pixbuf.get_n_channels(), stride = pixbuf.get_rowstride();
    const rgb = [];
    for (let row = 0; row < pixbuf.get_height(); row++) {
        for (let col = 0; col < pixbuf.get_width(); col++)
            rgb.push(...bytes.slice(row * stride + col * n, row * stride + col * n + 3));
    }
    return rgb;
}

// Dimmed = alpha × undimmed + (1 − alpha) × what lies under the pane: alpha is the slope, whatever lies under it.
function alpha(undimmed, dimmed) {
    const mean = v => v.reduce((a, b) => a + b, 0) / v.length;
    const [mu, md] = [mean(undimmed), mean(dimmed)];
    let cov = 0, variance = 0;
    undimmed.forEach((u, i) => {
        cov += (u - mu) * (dimmed[i] - md);
        variance += (u - mu) ** 2;
    });
    return Math.round(cov / variance * 1000) / 1000;
}

// The header, and the body's upper half: the output above the prompt, away from the caret.
function regions(pane) {
    const [x, y, width, height] = pane.body;
    return {header: pane.header, body: [x + 4, y + 4, width - 8, Math.floor(height / 2)]};
}

// The pointer, and the overlay scrollbar it shows, would differ between the two captures.
async function park() {
    pointer.notify_absolute_motion(GLib.get_monotonic_time(), 0, 0);
    await Scripting.sleep(SCROLLBAR_FADE_MS);
}

async function capture(pane) {
    const r = regions(pane);
    return {header: await pixels(r.header), body: await pixels(r.body)};
}

async function drive() {
    const seat = global.stage.context.get_backend().get_default_seat();
    keyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    pointer = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
    Main.overview.hide();
    await Scripting.sleep(500);

    Gio.Subprocess.new(['ptyxis', '--new-window', '-d', GLib.get_home_dir()], Gio.SubprocessFlags.NONE);
    const ptyxis = () => global.get_window_actors().map(a => a.meta_window)
        .find(w => `${w.get_wm_class()} ${w.get_gtk_application_id()}`.includes('Ptyxis'));
    for (let waited = 0; !(window = ptyxis()) && waited < WINDOW_WAIT_MS; waited += 100)
        await Scripting.sleep(100);
    if (!window)
        throw new Error(`no Ptyxis window ${WINDOW_WAIT_MS} ms after ptyxis --new-window`);
    await Scripting.sleep(SHELL_START_MS);
    // A resize that lands while the window is still settling its first size is dropped.
    for (let waited = 0; window.get_frame_rect().width !== WINDOW.width && waited < WAIT_MS; waited += 200) {
        window.move_resize_frame(false, WINDOW.x, WINDOW.y, WINDOW.width, WINDOW.height);
        await Scripting.sleep(200);
    }

    const r = {};
    r.start = await until('one terminal, prompted',
        s => s.terminals === 1 && s.prompted[0] && window.get_frame_rect().width === WINDOW.width);
    const split = s => s.panes.length === 2;
    const single = s => s.terminals === 1 && s.panes.length === 0;
    const right = s => split(s) && s.panes[1].body[0] > s.panes[0].body[0];
    const down = s => split(s) && s.panes[1].body[1] > s.panes[0].body[1];

    await atspi('click', 'Split Right', '0');
    r.toggleRight = await until('Split Right', right);
    await atspi('click', 'Split Right', '0');
    r.toggleRightOff = await until('Split Right again', single);
    await atspi('click', 'Split Down', '0');
    r.toggleDown = await until('Split Down', down);
    await atspi('click', 'Split Down', '0');
    r.toggleDownOff = await until('Split Down again', single);

    const ctrlAlt = [Clutter.KEY_Control_L, Clutter.KEY_Alt_L];
    tap(Clutter.KEY_r, ctrlAlt);
    r.keyRight = await until('Ctrl+Alt+R', right);
    tap(Clutter.KEY_d, ctrlAlt);
    r.keyDown = await until('Ctrl+Alt+D', down);
    tap(Clutter.KEY_d, ctrlAlt);
    r.keyDownOff = await until('Ctrl+Alt+D again', single);

    // VTE reports a command that ends within one batch as precmd before preexec, which leaves its pane running.
    const OUTLAST_A_BATCH = '; sleep 1';
    tap(Clutter.KEY_r, ctrlAlt);
    // A command typed before the new shell's first prompt can leave the pane reading running.
    const s = await until('Ctrl+Alt+R, and the new shell prompted', t => right(t) && t.panes[1].prompted);
    await type(`seq 1 30${OUTLAST_A_BATCH}`);
    await clickAt(s.panes[0].body);
    r.clickFirst = await until('a click on the first pane', t => t.panes[0].focused);
    await type(`seq 1 30${OUTLAST_A_BATCH}`);
    await until('both seq done', t => t.footer.done === 1);
    await park();
    const firstFocused = {first: await capture(r.clickFirst.panes[0]), second: await capture(r.clickFirst.panes[1])};
    await clickAt(r.clickFirst.panes[1].body);
    r.clickSecond = await until('a click on the second pane', t => t.panes[1].focused);
    await park();
    const secondFocused = {
        first: await capture(r.clickSecond.panes[0]),
        second: await capture(r.clickSecond.panes[1]),
    };
    r.dim = {
        first: {header: alpha(firstFocused.first.header, secondFocused.first.header),
            body: alpha(firstFocused.first.body, secondFocused.first.body)},
        second: {header: alpha(secondFocused.second.header, firstFocused.second.header),
            body: alpha(secondFocused.second.body, firstFocused.second.body)},
    };

    await type('cargo test --workspace');
    r.cargoRunning = await until('cargo running', t => t.panes[1].title === 'cargo test --workspace');
    await Scripting.sleep(RUN_WAIT_MS);
    r.cargoDone = await until('cargo done', t => t.panes[1].title === 'Shell' && t.footer.done === 1);

    await clickAt(r.cargoDone.panes[0].body);
    await until('a click on the first pane', t => t.panes[0].focused);
    await type('rpmbuild -bb packaging/apex-desktop.spec');
    await Scripting.sleep(RUN_WAIT_MS);
    r.rpmbuildFailed = await until('rpmbuild failed', t => t.footer.failed === 1);

    await type('just vm-image');
    r.justRunning = await until('just running', t => t.panes[0].title === 'just vm-image' && t.row.progress !== null);

    await clickAt(r.justRunning.panes[1].body);
    await until('a click on the second pane', t => t.panes[1].focused);
    await type(`printf '\\e]9;4;1;20\\e\\\\'${OUTLAST_A_BATCH}`);
    await Scripting.sleep(RUN_WAIT_MS / 2);
    r.secondProgress = await state();

    await type('claude');
    await clickAt(r.justRunning.panes[0].body);
    await until('a click on the first pane', t => t.panes[0].focused);
    await Scripting.sleep(RUN_WAIT_MS);
    r.bell = await until('the bell', t => t.panes[1].needsYou);
    await clickAt(r.bell.panes[1].body);
    r.bellCleared = await until('the second pane focused', t => t.panes[1].focused && !t.panes[1].needsYou);

    await atspi('click', 'Close Pane', '0');
    r.closed = await until('Close Pane', single);
    return r;
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
        result = await drive();
    } catch (e) {
        result = {error: `${e.message}\n${e.stack}`};
    }
    console.log(`APEXPANES ${JSON.stringify(result)}`);
}
