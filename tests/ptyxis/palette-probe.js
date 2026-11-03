// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for palette-test.sh: a palette file rewritten under an open terminal.

import GdkPixbuf from 'gi://GdkPixbuf';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Shell.Screenshot.prototype, 'pick_color');
Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');

const WINDOW_WAIT_MS = 30000;
const SHELL_START_MS = 3000;
const POLL_MS = 50;
const GIVE_UP_MS = 3000;
const AGENT_WAIT_MS = 10000;
const CARET_SLACK = 2;

const hexRgb = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
const near = (a, b) => a.every((v, i) => Math.abs(v - b[i]) <= CARET_SLACK);

function ptyxisWindow() {
    return global.get_window_actors().map(a => a.meta_window)
        .find(w => `${w.get_wm_class()} ${w.get_gtk_application_id()}`.includes('Ptyxis'));
}

// The middle of the largest patch drawn in RGB, in stage coordinates: the caret; the sidebar's accent is smaller.
async function find(window, rgb) {
    const r = window.get_frame_rect();
    const path = GLib.build_filenamev([GLib.get_tmp_dir(), `apex-palette-${GLib.get_monotonic_time()}.png`]);
    const stream = Gio.File.new_for_path(path).replace(null, false, Gio.FileCreateFlags.NONE, null);
    try {
        await new Shell.Screenshot().screenshot_area(r.x, r.y, r.width, r.height, stream);
    } finally {
        stream.close(null);
    }
    const pixbuf = GdkPixbuf.Pixbuf.new_from_file(path);
    GLib.unlink(path);
    const bytes = pixbuf.get_pixels();
    const [width, height] = [pixbuf.get_width(), pixbuf.get_height()];
    const n = pixbuf.get_n_channels(), stride = pixbuf.get_rowstride(), scale = width / r.width;
    const drawn = new Set();
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            const i = y * stride + x * n;
            if (near([bytes[i], bytes[i + 1], bytes[i + 2]], rgb))
                drawn.add(y * width + x);
        }
    }
    let best = null;
    for (const seed of drawn) {
        const patch = {size: 0, x0: width, y0: height, x1: 0, y1: 0};
        const todo = [seed];
        drawn.delete(seed);
        while (todo.length) {
            const p = todo.pop();
            const [x, y] = [p % width, Math.floor(p / width)];
            Object.assign(patch, {size: patch.size + 1, x0: Math.min(patch.x0, x), x1: Math.max(patch.x1, x),
                y0: Math.min(patch.y0, y), y1: Math.max(patch.y1, y)});
            for (const q of [p - 1, p + 1, p - width, p + width]) {
                if (drawn.delete(q))
                    todo.push(q);
            }
        }
        if (patch.size > (best?.size ?? 0))
            best = patch;
    }
    return best && [r.x + (best.x0 + best.x1) / 2 / scale, r.y + (best.y0 + best.y1) / 2 / scale];
}

async function colorAt([x, y]) {
    const picked = await new Shell.Screenshot().pick_color(x, y);
    const color = Array.isArray(picked) ? picked.at(-1) : picked;
    const channel = name => color[`get_${name}`]?.() ?? color[name];
    return ['red', 'green', 'blue'].map(name => Math.round(channel(name) <= 1 ? channel(name) * 255 : channel(name)));
}

function terminalColor(window) {
    const r = window.get_frame_rect();
    return colorAt([r.x + r.width / 2, r.y + r.height * 0.75]);
}

function startAgent() {
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
    launcher.set_stderr_file_path(GLib.getenv('APEX_AGENT_LOG'));
    launcher.set_stdout_file_path(`${GLib.getenv('APEX_AGENT_LOG')}.out`);
    const agent = {proc: launcher.spawnv([GLib.getenv('APEX_AGENT')]), running: true};
    agent.proc.wait_async(null, () => (agent.running = false));
    return agent;
}

async function caret(window) {
    const [from, to] = JSON.parse(GLib.getenv('APEX_CARET_ACCENTS'));
    const agent = startAgent();
    let at = null;
    for (let waited = 0; !(at = await find(window, hexRgb(from.hex))) && waited < AGENT_WAIT_MS; waited += 100)
        await Scripting.sleep(100);
    if (!at)
        throw new Error(`no ${from.name} caret ${AGENT_WAIT_MS} ms after the agent started (${agent.running})`);

    const before = await colorAt(at);
    new Gio.Settings({schema_id: 'org.gnome.desktop.interface'}).set_string('accent-color', to.name);
    const start = GLib.get_monotonic_time();
    let after = before;
    let ms = 0;
    while (ms < GIVE_UP_MS && !near(after, hexRgb(to.hex))) {
        await Scripting.sleep(POLL_MS);
        after = await colorAt(at);
        ms = Math.round((GLib.get_monotonic_time() - start) / 1000);
    }
    const result = {before, after, ms, agentRunning: agent.running};
    agent.proc.force_exit();
    return result;
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
    return {before, after, ms, caret: await caret(window)};
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
