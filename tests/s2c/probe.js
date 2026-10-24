// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for radius-test.sh: Settings' Corner Radius pressed under open libadwaita windows.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Shell.Screenshot.prototype, 'pick_color');
Gio._promisify(Shell.Screenshot.prototype, 'screenshot');
Gio._promisify(Gio.Subprocess.prototype, 'communicate_utf8_async');

const WINDOW_WAIT_MS = 30000;
const AGENT_WAIT_MS = 10000;
const SETTLE_MS = 3000;
const POLL_MS = 20;
const GIVE_UP_MS = 3000;
// Inside the frame and outside a 14 px corner; the reference is the header bar on the same row.
const CORNER = {x: 3, y: 3};
const REFERENCE = {x: 60, y: 3};
const TOLERANCE = 6;
// Each later window keeps clear of the earlier ones' corners; behind them is the maximised terminal's red.
const LAYOUT = {
    ptyxis: {x: 40, y: 120, width: 560, height: 420},
    files: {x: 320, y: 220, width: 640, height: 460},
    settings: {x: 640, y: 320, width: 780, height: 560},
};

const appWindows = id => global.get_window_actors().map(a => a.meta_window)
    .filter(w => `${w.get_wm_class()} ${w.get_gtk_application_id()}`.includes(id));

async function open(argv, id, count = 1) {
    Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
    for (let waited = 0; appWindows(id).length < count && waited < WINDOW_WAIT_MS; waited += 100)
        await Scripting.sleep(100);
    const windows = appWindows(id);
    if (windows.length < count)
        throw new Error(`no window ${WINDOW_WAIT_MS} ms after ${argv.join(' ')}`);
    return windows.sort((a, b) => b.get_stable_sequence() - a.get_stable_sequence())[0];
}

async function pick(x, y) {
    const picked = await new Shell.Screenshot().pick_color(x, y);
    const color = Array.isArray(picked) ? picked.at(-1) : picked;
    const channel = name => color[`get_${name}`]?.() ?? color[name];
    return ['red', 'green', 'blue'].map(name => Math.round(channel(name) <= 1 ? channel(name) * 255 : channel(name)));
}

async function square(window) {
    const r = window.get_frame_rect();
    const corner = await pick(r.x + CORNER.x, r.y + CORNER.y);
    const reference = await pick(r.x + REFERENCE.x, r.y + REFERENCE.y);
    return {square: corner.every((v, i) => Math.abs(v - reference[i]) <= TOLERANCE), corner, reference};
}

async function captureScreen(name) {
    const stream = Gio.File.new_for_path(GLib.build_filenamev([GLib.getenv('APEX_SHOTS'), name]))
        .replace(null, false, Gio.FileCreateFlags.NONE, null);
    try {
        await new Shell.Screenshot().screenshot(false, stream);
    } finally {
        stream.close(null);
    }
}

const readCss = () => {
    try {
        return new TextDecoder().decode(GLib.file_get_contents(GLib.getenv('APEX_CSS_FILE'))[1]);
    } catch {
        return '';
    }
};

function startAgent() {
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
    launcher.set_stderr_file_path(GLib.getenv('APEX_AGENT_LOG'));
    launcher.set_stdout_file_path(`${GLib.getenv('APEX_AGENT_LOG')}.out`);
    const agent = {proc: launcher.spawnv([GLib.getenv('APEX_AGENT')]), running: true};
    agent.proc.wait_async(null, () => (agent.running = false));
    return agent;
}

async function waitForAgent(agent) {
    const log = () => {
        try {
            return new TextDecoder().decode(GLib.file_get_contents(GLib.getenv('APEX_AGENT_LOG'))[1]);
        } catch {
            return '';
        }
    };
    for (let waited = 0; waited < AGENT_WAIT_MS && agent.running; waited += 100) {
        if (log().includes('wrote apex.css') && /:root \{ --window-radius: 14px;/.test(readCss()))
            return;
        await Scripting.sleep(100);
    }
    throw new Error(`the agent wrote no 14px apex.css in ${AGENT_WAIT_MS} ms (running: ${agent.running})`);
}

async function click(label) {
    const proc = Gio.Subprocess.new(['python3', GLib.getenv('APEX_CLICK'), label],
        Gio.SubprocessFlags.STDOUT_PIPE);
    const [stdout] = await proc.communicate_utf8_async(null, null);
    if (!proc.get_successful())
        throw new Error(`click.py ${label} failed: ${stdout}`);
    return JSON.parse(stdout.trim().split('\n').at(-1)).clicked_us;
}

async function measure() {
    Main.overview.hide();
    await Scripting.sleep(500);
    const agent = startAgent();
    await waitForAgent(agent);

    const windows = {};
    windows.maximised = await open(['ptyxis', '--new-window'], 'Ptyxis');
    windows.maximised.maximize();
    windows.ptyxis = await open(['ptyxis', '--new-window'], 'Ptyxis', 2);
    windows.files = await open(['nautilus', '--new-window', GLib.get_home_dir()], 'org.gnome.Nautilus');
    windows.settings = await open(['gnome-control-center', 'apex'], 'org.gnome.Settings');
    // The first resize can land before a window is mapped, so the second makes it stick.
    for (let i = 0; i < 2; i++) {
        for (const [name, r] of Object.entries(LAYOUT))
            windows[name].move_resize_frame(false, r.x, r.y, r.width, r.height);
        await Scripting.sleep(SETTLE_MS);
    }

    const result = {windows: {}, maximised: windows.maximised.is_maximized(), agent_running: agent.running};
    for (const [name, w] of Object.entries(windows))
        result.windows[name] = {before: await square(w)};
    await captureScreen('s2c-14.png');

    const clickedUs = await click('0');
    const pending = new Set(Object.keys(LAYOUT));
    let elapsedMs = 0;
    while (pending.size > 0 && elapsedMs < GIVE_UP_MS) {
        for (const name of [...pending]) {
            const s = await square(windows[name]);
            elapsedMs = Math.round((GLib.get_monotonic_time() - clickedUs) / 1000);
            if (s.square) {
                result.windows[name].ms = elapsedMs;
                pending.delete(name);
            }
        }
        await Scripting.sleep(POLL_MS);
    }
    for (const [name, w] of Object.entries(windows))
        result.windows[name].after = await square(w);
    await Scripting.sleep(500);
    await captureScreen('s2c-0.png');

    result.key = new Gio.Settings({schema_id: 'io.github.apex_linux.Apex.Desktop'}).get_uint('window-corner-radius');
    result.css = readCss();
    result.agent_running_after = agent.running;
    agent.proc.force_exit();
    return result;
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
    console.log(`APEXS2C ${JSON.stringify(result)}`);
}
