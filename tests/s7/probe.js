// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for accent-test.sh: an accent change under Files, a file chooser and Spotlight.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

import * as Png from '../shots/png.js';

Gio._promisify(Shell.Screenshot.prototype, 'pick_color');
Gio._promisify(Shell.Screenshot.prototype, 'screenshot');

const WINDOW_WAIT_MS = 30000;
const AGENT_WAIT_MS = 10000;
const SPOTLIGHT_WAIT_MS = 15000;
const SETTLE_MS = 3000;
const POLL_MS = 20;
const GIVE_UP_MS = 3000;
const TOLERANCE = 8;
const INTERFACE = 'org.gnome.desktop.interface';
// Below Spotlight's panel, which opens 96 px down the monitor's middle.
const LAYOUT = {
    files: {x: 16, y: 440, width: 690, height: 440},
    chooser: {x: 734, y: 440, width: 690, height: 440},
};
// build-places.sh's template, in its 64 px box: the tab spans x 6 to 58 from y 11, the body's middle is 32, 38.5.
const TAB = {left: 6, right: 58, top: 11};
const BODY = {x: 32, y: 38.5};

const accents = JSON.parse(GLib.getenv('APEX_ACCENTS'));
const hexRgb = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
const near = (rgb, want) => rgb.every((v, i) => Math.abs(v - want[i]) <= TOLERANCE);
const msSince = start => Math.round((GLib.get_monotonic_time() - start) / 1000);

const appWindows = id => global.get_window_actors().map(a => a.meta_window)
    .filter(w => `${w.get_wm_class()} ${w.get_gtk_application_id()}`.includes(id));

async function open(argv, id) {
    Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
    for (let waited = 0; appWindows(id).length === 0 && waited < WINDOW_WAIT_MS; waited += 100)
        await Scripting.sleep(100);
    const [window] = appWindows(id);
    if (!window)
        throw new Error(`no window ${WINDOW_WAIT_MS} ms after ${argv.join(' ')}`);
    return window;
}

async function pick(x, y) {
    const picked = await new Shell.Screenshot().pick_color(x, y);
    const color = Array.isArray(picked) ? picked.at(-1) : picked;
    const channel = name => color[`get_${name}`]?.() ?? color[name];
    return ['red', 'green', 'blue'].map(name => Math.round(channel(name) <= 1 ? channel(name) * 255 : channel(name)));
}

async function screen(name) {
    const path = GLib.build_filenamev([GLib.getenv('APEX_SHOTS'), name]);
    const stream = Gio.File.new_for_path(path).replace(null, false, Gio.FileCreateFlags.NONE, null);
    try {
        await new Shell.Screenshot().screenshot(false, stream);
    } finally {
        stream.close(null);
    }
    return Png.decode(GLib.file_get_contents(path)[1]);
}

// The folder's tab in a region, in its back colour; from it, the stage point at the body's middle.
function folderBody(image, region, tab) {
    const scale = image.width / global.stage.width;
    const box = {x0: Infinity, y0: Infinity, x1: -Infinity};
    for (let y = Math.round(region.y * scale); y < Math.round((region.y + region.height) * scale); y++) {
        for (let x = Math.round(region.x * scale); x < Math.round((region.x + region.width) * scale); x++) {
            const at = (y * image.width + x) * 4;
            if (near([image.rgba[at], image.rgba[at + 1], image.rgba[at + 2]], tab)) {
                box.x0 = Math.min(box.x0, x);
                box.x1 = Math.max(box.x1, x);
                box.y0 = Math.min(box.y0, y);
            }
        }
    }
    if (box.x1 < box.x0)
        return null;
    const unit = (box.x1 - box.x0 + 1) / (TAB.right - TAB.left);
    return {
        x: (box.x0 + (BODY.x - TAB.left) * unit) / scale,
        y: (box.y0 + (BODY.y - TAB.top) * unit) / scale,
        size: Math.round(64 * unit / scale),
    };
}

function startAgent() {
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
    launcher.set_stderr_file_path(GLib.getenv('APEX_AGENT_LOG'));
    launcher.set_stdout_file_path(`${GLib.getenv('APEX_AGENT_LOG')}.out`);
    const agent = {proc: launcher.spawnv([GLib.getenv('APEX_AGENT')]), running: true};
    agent.proc.wait_async(null, () => (agent.running = false));
    return agent;
}

async function spotlightFolder(name) {
    const feature = await import('resource:///org/gnome/shell/ui/apex/spotlight/feature.js');
    const popup = feature.popup();
    if (!popup)
        throw new Error('Spotlight is off');
    popup.open(name);
    for (let waited = 0; waited < SPOTLIGHT_WAIT_MS; waited += 100) {
        const row = popup.rows.find(r => r.key.startsWith('Files/'));
        if (row)
            return {popup, title: row.title};
        await Scripting.sleep(100);
    }
    throw new Error(`Spotlight found no Files result for "${name}" in ${SPOTLIGHT_WAIT_MS} ms`);
}

async function measure(result) {
    Main.overview.hide();
    await Scripting.sleep(500);
    const settings = new Gio.Settings({schema_id: INTERFACE});
    const agent = GLib.getenv('APEX_AGENT') ? startAgent() : null;
    Object.assign(result, {control: agent === null, agentRunning: agent?.running ?? false});
    if (agent) {
        for (let waited = 0; settings.get_string('icon-theme') !== `Apex-${accents[0].name}` && waited < AGENT_WAIT_MS; waited += 100)
            await Scripting.sleep(100);
    }
    result.themeBefore = settings.get_string('icon-theme');

    const home = GLib.get_home_dir();
    const windows = {
        files: await open(['nautilus', '--new-window', home], 'org.gnome.Nautilus'),
        chooser: await open(['gjs', '-m', GLib.getenv('APEX_CHOOSER'), home], 'io.github.apex_linux.S7Chooser'),
    };
    for (let i = 0; i < 2; i++) {
        for (const [name, r] of Object.entries(LAYOUT))
            windows[name].move_resize_frame(false, r.x, r.y, r.width, r.height);
        await Scripting.sleep(SETTLE_MS);
    }
    const spotlight = await spotlightFolder(GLib.getenv('APEX_FOLDER'));
    result.spotlightRow = spotlight.title;
    await Scripting.sleep(SETTLE_MS);

    const regions = {
        files: windows.files.get_frame_rect(),
        chooser: windows.chooser.get_frame_rect(),
        spotlight: (() => {
            const [x, y] = spotlight.popup.panel.get_transformed_position();
            const [width, height] = spotlight.popup.panel.get_transformed_size();
            return {x, y, width, height};
        })(),
    };
    const image = await screen(`${GLib.getenv('APEX_RUN')}-${accents[0].name}.png`);
    const points = {};
    result.surfaces = {};
    for (const [name, region] of Object.entries(regions)) {
        points[name] = folderBody(image, region, hexRgb(accents[0].tab));
        result.surfaces[name] = {icon: points[name]?.size ?? null,
            before: points[name] ? await pick(points[name].x, points[name].y) : null};
    }
    // A surface without the first accent's folder is reported as such; the others are still measured.
    const found = Object.keys(points).filter(name => points[name]);

    result.changes = [];
    for (const accent of accents.slice(1)) {
        const want = hexRgb(accent.front);
        const change = {accent: accent.name, ms: {}};
        const started = GLib.get_monotonic_time();
        settings.set_string('accent-color', accent.name);
        const pending = new Set(found);
        while (pending.size > 0 && msSince(started) < GIVE_UP_MS) {
            for (const name of [...pending]) {
                const rgb = await pick(points[name].x, points[name].y);
                if (near(rgb, want)) {
                    change.ms[name] = msSince(started);
                    pending.delete(name);
                }
            }
            await Scripting.sleep(POLL_MS);
        }
        change.after = {};
        for (const name of Object.keys(points)) {
            change.ms[name] ??= null;
            change.after[name] = points[name] ? await pick(points[name].x, points[name].y) : null;
        }
        change.theme = settings.get_string('icon-theme');
        await screen(`${GLib.getenv('APEX_RUN')}-${accent.name}.png`);
        result.changes.push(change);
    }
    result.agentRunningAfter = agent?.running ?? false;
    spotlight.popup.close();
    agent?.proc.force_exit();
}

// main.js connects to startup-complete only after importing this module, so a startup that
// completes during the import would never run the script and leave the shell up.
export function init() {
    if (Main.layoutManager._startingUp)
        return;
    import(import.meta.url).then(self => Scripting.runPerfScript(self, GLib.getenv('SHELL_PERF_OUTPUT')));
}

export async function run() {
    const result = {};
    try {
        await measure(result);
    } catch (e) {
        result.error = `${e.message}\n${e.stack}`;
    }
    console.log(`APEXS7 ${JSON.stringify(result)}`);
}
