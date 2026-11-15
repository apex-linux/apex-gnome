// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for run.sh: Apex Code started, measured, named, typed into and answered by pylsp in the toolbox.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Gio.Subprocess.prototype, 'communicate_utf8_async');
Gio._promisify(Gio.Subprocess.prototype, 'wait_async');

const env = name => GLib.getenv(name);
const PROJECT = env('APEX_BUILDER_PROJECT');
const LSP_FILE = env('APEX_BUILDER_LSP_FILE');
const TYPING_FILE = env('APEX_BUILDER_TYPING_FILE');
// E0's harness: three cold starts after a discarded one; 30 s settled, then 10 samples a second apart.
const STARTS = 3;
const WINDOW_WAIT_MS = 60000;
const QUIET_MS = 3000;
const SETTLE_MS = 30000;
const SAMPLES = 10;
const LSP_WAIT_MS = 45000;
const PRESS_WAIT_MS = 30000;
const CREATE_WAIT_MS = 900000;
const SETUP_WAIT_MS = 600000;
const TOOLBOX = env('APEX_BUILDER_TOOLBOX');
// E0's typing: a key every 150 ms, timed from the press to the frame presented after the window's first damage.
const TYPING_MS = 60000;
const KEY_GAP_MS = 150;
const KEY_WAIT_MS = 2000;
const TYPED_LINE = 'total_count = base_value + offset * 2\n';

const now = () => GLib.get_monotonic_time();
let keyboard;

function tap(keyval, modifiers = []) {
    for (const m of modifiers)
        keyboard.notify_keyval(now(), m, Clutter.KeyState.PRESSED);
    keyboard.notify_keyval(now(), keyval, Clutter.KeyState.PRESSED);
    keyboard.notify_keyval(now(), keyval, Clutter.KeyState.RELEASED);
    for (const m of [...modifiers].reverse())
        keyboard.notify_keyval(now(), m, Clutter.KeyState.RELEASED);
}

function keyval(ch) {
    return ch === '\n' ? Clutter.KEY_Return : Clutter.unicode_to_keysym(ch.codePointAt(0));
}

async function type(text) {
    for (const ch of text) {
        tap(keyval(ch));
        await Scripting.sleep(KEY_GAP_MS);
    }
}

// Each key's latency in ms, or null when the window drew nothing for KEY_WAIT_MS; the next key waits for it.
function timedTap(window, kv) {
    const actor = window.get_compositor_private();
    const t0 = now();
    return new Promise(resolve => {
        let pid = 0;
        const did = actor.connect('damaged', () => {
            actor.disconnect(did);
            pid = global.stage.connect('after-paint', () => {
                global.stage.disconnect(pid);
                resolve(Math.round((now() - t0) / 100) / 10);
            });
        });
        tap(kv);
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, KEY_WAIT_MS, () => {
            if (pid === 0) {
                actor.disconnect(did);
                resolve(null);
            }
            return GLib.SOURCE_REMOVE;
        });
    });
}

// Escape before Return, so that a completion popup never takes the newline.
async function typeTimed(window, ms) {
    const keys = [];
    const end = now() + ms * 1000;
    for (let i = 0; now() < end; i++) {
        const ch = TYPED_LINE[i % TYPED_LINE.length];
        if (ch === '\n')
            tap(Clutter.KEY_Escape);
        const t = now();
        keys.push(await timedTap(window, keyval(ch)));
        const left = KEY_GAP_MS - (now() - t) / 1000;
        if (left > 0)
            await Scripting.sleep(left);
    }
    return keys;
}

async function helper(script, ...args) {
    const proc = Gio.Subprocess.new(['python3', env(script), ...args],
        Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
    const [stdout, stderr] = await proc.communicate_utf8_async(null, null);
    if (!proc.get_successful())
        throw new Error(`${script} ${args.join(' ')}: ${stderr.trim()}`);
    return JSON.parse(stdout.trim().split('\n').at(-1));
}

async function spawnWait(argv) {
    const proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
    await proc.wait_async(null);
    return proc.get_exit_status();
}

async function quit() {
    await spawnWait(['pkill', '-x', 'gnome-builder']);
    for (let i = 0; i < 50 && await spawnWait(['pgrep', '-x', 'gnome-builder']) === 0; i++)
        await Scripting.sleep(200);
    await spawnWait(['pkill', '-9', '-x', 'gnome-builder']);
    await Scripting.sleep(500);
}

// run.sh's root loop drops the page cache when this file appears, and removes it.
async function dropCaches() {
    const request = Gio.File.new_for_path(env('APEX_BUILDER_DROP'));
    request.replace_contents('drop\n', null, false, Gio.FileCreateFlags.NONE, null);
    for (let i = 0; i < 100 && request.query_exists(null); i++)
        await Scripting.sleep(100);
    if (request.query_exists(null))
        throw new Error('run.sh did not drop the page cache');
}

// t0 before the spawn; the first normal window's creation, its first frame, the stage paint after it,
// and its last damage before QUIET_MS without any (E0's "settled").
function launch(argv) {
    console.log(`APEXBUILDER-STEP launch ${argv.join(' ')}`);
    return new Promise((resolve, reject) => {
        const st = {t0: now()};
        let lastDamage = null;
        const timeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, WINDOW_WAIT_MS, () => {
            reject(new Error(`no Apex Code window within ${WINDOW_WAIT_MS} ms`));
            return GLib.SOURCE_REMOVE;
        });
        const id = global.display.connect('window-created', (d, w) => {
            console.log(`APEXBUILDER-STEP window ${w.get_wm_class()} type ${w.get_window_type()}`);
            if (w.get_window_type() !== Meta.WindowType.NORMAL)
                return;
            global.display.disconnect(id);
            st.created = now();
            const actor = w.get_compositor_private();
            actor.connect('damaged', () => {
                lastDamage = now();
            });
            actor.connect('first-frame', () => {
                st.firstFrame = now();
                const pid = global.stage.connect('after-paint', () => {
                    global.stage.disconnect(pid);
                    st.painted = now();
                    GLib.source_remove(timeout);
                    const quiet = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, () => {
                        if (lastDamage !== null && now() - lastDamage < QUIET_MS * 1000)
                            return GLib.SOURCE_CONTINUE;
                        st.settled = lastDamage ?? st.painted;
                        st.window = w;
                        GLib.source_remove(quiet);
                        resolve(st);
                        return GLib.SOURCE_REMOVE;
                    });
                });
            });
        });
        Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
    });
}

const ms = (st, key) => Math.round((st[key] - st.t0) / 100) / 10;

async function starts() {
    const out = [];
    await launch(['gnome-builder', '-p', PROJECT]);
    await quit();
    for (let i = 0; i < STARTS; i++) {
        await dropCaches();
        const st = await launch(['gnome-builder', '-p', PROJECT]);
        out.push({created: ms(st, 'created'), painted: ms(st, 'painted'), settled: ms(st, 'settled'), title: st.window.get_title()});
        await quit();
    }
    return out;
}

async function idle() {
    const st = await launch(['gnome-builder', '-p', PROJECT]);
    await spawnWait(['gnome-builder', LSP_FILE]);
    st.window.maximize(Meta.MaximizeFlags.BOTH);
    await Scripting.sleep(SETTLE_MS);
    const pid = st.window.get_pid();
    const samples = [];
    for (let i = 0; i < SAMPLES; i++) {
        samples.push(await helper('APEX_BUILDER_MEM', `${pid}`));
        await Scripting.sleep(1000);
    }
    const names = await helper('APEX_BUILDER_ATSPI');
    await quit();
    return {samples, names, title: st.window.get_title()};
}

// Keys timed from the moment the first file opens and starts its diagnostics, then pylsp's answer.
// Cairo compiles no shaders: lavapipe's first popup pipeline costs 290-430 ms, the driver's cost.
async function typing() {
    const log = env('APEX_BUILDER_LOG');
    const st = await launch(['sh', '-c', `GSK_RENDERER=cairo exec gnome-builder -vvv -p '${PROJECT}' > '${log}' 2>&1`]);
    await spawnWait(['gnome-builder', TYPING_FILE]);
    const keys = await typeTimed(st.window, TYPING_MS);
    tap(Clutter.KEY_Escape);
    await type('\nimport os\nos.pa');
    const start = now();
    let found = null;
    while (found === null && (now() - start) / 1000 < LSP_WAIT_MS) {
        await Scripting.sleep(500);
        const [, bytes] = GLib.file_get_contents(log);
        const m = new TextDecoder().decode(bytes).match(/pylsp-language-server\+CompletionProvider populated initial result set of (\d+) items/);
        if (m)
            found = Number(m[1]);
    }
    await quit();
    return {keys, completionItems: found};
}

// Apex Code's own Create Toolbox, pressed in the notification the project shows without a
// toolbox; pylsp starting through podman exec shows the new runtime used without a reopen.
async function create() {
    const log = env('APEX_BUILDER_CREATE_LOG');
    await launch(['sh', '-c', `exec gnome-builder -vvv -p '${PROJECT}' > '${log}' 2>&1`]);
    await spawnWait(['gnome-builder', LSP_FILE]);
    const t0 = now();
    let pressed = false;
    while (!pressed && (now() - t0) / 1000 < PRESS_WAIT_MS) {
        await Scripting.sleep(1000);
        ({pressed} = await helper('APEX_BUILDER_PRESS', 'Create Toolbox'));
    }
    // pylsp itself launched in the toolbox, not a `which pylsp` lookup, and spawned.
    let lspInToolboxAfterS = null;
    let text = '';
    const t1 = now();
    while (pressed && lspInToolboxAfterS === null && (now() - t1) / 1000 < CREATE_WAIT_MS) {
        await Scripting.sleep(2000);
        const [, bytes] = GLib.file_get_contents(log);
        text = new TextDecoder().decode(bytes);
        if (/Launching podman exec [^\n]* pylsp \[env /.test(text) && /Language server .pylsp. spawned as process/.test(text))
            lspInToolboxAfterS = Math.round((now() - t1) / 1e6);
    }
    const createEnv = (text.match(/Launching sh -c \{ podman container exists [^\n]*/) ?? [''])[0];
    const {names} = await helper('APEX_BUILDER_PRESS', '--names');
    await quit();
    return {pressed, lspInToolboxAfterS, createHasRuntimeDir: /\[env [^\]]*XDG_RUNTIME_DIR=/.test(createEnv),
            toolboxNames: names.filter(n => /oolbox/.test(n))};
}

// A toolbox whose setup stopped halfway: Apex Code says so, and Finish Setup completes it.
async function finishSetup() {
    const has = () => spawnWait(['podman', 'exec', TOOLBOX, 'sh', '-c', 'command -v typescript-language-server']);
    await spawnWait(['podman', 'exec', TOOLBOX, 'npm', 'uninstall', '-g', '--no-fund', '--no-audit', 'typescript-language-server']);
    const removed = await has() !== 0;
    await launch(['gnome-builder', '-p', PROJECT]);
    const t0 = now();
    let pressed = false;
    while (!pressed && (now() - t0) / 1000 < PRESS_WAIT_MS) {
        await Scripting.sleep(1000);
        ({pressed} = await helper('APEX_BUILDER_PRESS', 'Finish Setup'));
    }
    let restoredAfterS = null;
    const t1 = now();
    while (pressed && restoredAfterS === null && (now() - t1) / 1000 < SETUP_WAIT_MS) {
        await Scripting.sleep(2000);
        if (await has() === 0)
            restoredAfterS = Math.round((now() - t1) / 1e6);
    }
    await quit();
    return {removed, pressed, restoredAfterS};
}

async function drive() {
    keyboard = global.stage.context.get_backend().get_default_seat()
        .create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    Main.overview.hide();
    const created = env('APEX_BUILDER_CREATE') === 'true' ? await create() : null;
    const setup = created !== null ? await finishSetup() : null;
    return {create: created, setup, starts: await starts(), idle: await idle(), typing: await typing()};
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
    console.log(`APEXBUILDER ${JSON.stringify(result)}`);
}
