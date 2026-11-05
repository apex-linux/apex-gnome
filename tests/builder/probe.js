// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for run.sh: Apex Code started, measured, named and answered by pylsp in the toolbox.

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
// E0's harness: three cold starts after a discarded one; 30 s settled, then 10 samples a second apart.
const STARTS = 3;
const WINDOW_WAIT_MS = 60000;
const QUIET_MS = 3000;
const SETTLE_MS = 30000;
const SAMPLES = 10;
const LSP_WAIT_MS = 45000;

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

async function type(text) {
    for (const ch of text) {
        tap(ch === '\n' ? Clutter.KEY_Return : Clutter.unicode_to_keysym(ch.codePointAt(0)));
        await Scripting.sleep(150);
    }
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

// A completion request answered by pylsp in the toolbox, from Builder's own log.
async function answers() {
    const log = env('APEX_BUILDER_LOG');
    await launch(['sh', '-c', `exec gnome-builder -vvv -p '${PROJECT}' > '${log}' 2>&1`]);
    await spawnWait(['gnome-builder', LSP_FILE]);
    await Scripting.sleep(15000);
    tap(Clutter.KEY_End, [Clutter.KEY_Control_L]);
    await type('\nos.pa');
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
    return {completionItems: found};
}

async function drive() {
    keyboard = global.stage.context.get_backend().get_default_seat()
        .create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    Main.overview.hide();
    return {starts: await starts(), idle: await idle(), server: await answers()};
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
