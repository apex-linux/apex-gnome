// SPDX-License-Identifier: GPL-3.0-or-later
//
// The backdrop direct.sh pinned, checked where the empty desktop shows it: a grid of patches
// across the middle of the screen, each one's mean against the expected image's.

import GdkPixbuf from 'gi://GdkPixbuf';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

import * as Png from './png.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');

const COLUMNS = 4;
const ROWS = 3;
const PATCH = 24;
export const TOLERANCE = 12;
const WAIT_MS = 10000;
const STEP_MS = 250;

function hex([r, g, b]) {
    return `#${[r, g, b].map(v => Math.round(v).toString(16).padStart(2, '0')).join('')}`;
}

function mean(rgba, stride, x0, y0, width, height) {
    const sum = [0, 0, 0];
    for (let y = y0; y < y0 + height; y++) {
        for (let x = x0; x < x0 + width; x++) {
            const i = y * stride + x * 4;
            sum[0] += rgba[i];
            sum[1] += rgba[i + 1];
            sum[2] += rgba[i + 2];
        }
    }
    return sum.map(s => s / (width * height));
}

async function shot(x, y, size) {
    const stream = Gio.MemoryOutputStream.new_resizable();
    await new Shell.Screenshot().screenshot_area(x, y, size, size, stream);
    stream.close(null);
    const {width, height, rgba} = Png.decode(stream.steal_as_bytes().toArray());
    return mean(rgba, width * 4, 0, 0, width, height);
}

// The pixbuf scaled to the primary monitor, as picture-options zoom draws a 16:10 image on a 16:10 monitor.
function expectedMeans(want, patches, scale, monitor) {
    if (want.solid)
        return patches.map(() => want.solid);
    const pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(want.file,
        monitor.width * scale, monitor.height * scale, false);
    const bytes = pixbuf.read_pixel_bytes().toArray();
    const channels = pixbuf.get_n_channels();
    const stride = pixbuf.get_rowstride();
    return patches.map(({x: stageX, y: stageY}) => {
        const [x, y] = [stageX - monitor.x, stageY - monitor.y];
        const sum = [0, 0, 0];
        const size = PATCH * scale;
        for (let py = y * scale; py < (y + PATCH) * scale; py++) {
            for (let px = x * scale; px < (x + PATCH) * scale; px++) {
                const i = py * stride + px * channels;
                sum[0] += bytes[i];
                sum[1] += bytes[i + 1];
                sum[2] += bytes[i + 2];
            }
        }
        return sum.map(s => s / (size * size));
    });
}

function expected() {
    if (GLib.getenv('G2_BACKDROP') === 'solid') {
        const color = GLib.getenv('G2_SOLID_BACKDROP');
        return {name: color, solid: [1, 3, 5].map(i => parseInt(color.slice(i, i + 2), 16))};
    }
    const dark = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'}).get_string('color-scheme') === 'prefer-dark';
    const name = `facets-${dark ? 'dark' : 'light'}`;
    return {name, file: GLib.build_filenamev([GLib.getenv('G2_FACETS_DIR'), `apex-${name}.png`])};
}

// Waits up to WAIT_MS for the backdrop, which the shell loads asynchronously; an error names
// what the desktop showed instead.
export async function backdropReport({settle}) {
    if (Main.overview.visible) {
        Main.overview.hide();
        await settle();
    }
    const want = expected();
    const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
    // dock-external's second monitor draws the backdrop zoomed to its own size.
    const monitor = Main.layoutManager.primaryMonitor;
    const patches = [];
    for (let row = 0; row < ROWS; row++) {
        for (let column = 0; column < COLUMNS; column++) {
            patches.push({
                x: monitor.x + Math.round(monitor.width * (0.2 + 0.6 * (column + 0.5) / COLUMNS) - PATCH / 2),
                y: monitor.y + Math.round(monitor.height * (0.3 + 0.3 * (row + 0.5) / ROWS) - PATCH / 2),
            });
        }
    }
    const wants = expectedMeans(want, patches, scale, monitor);
    const picture = new Gio.Settings({schema_id: 'org.gnome.desktop.background'}).get_string('picture-uri');
    let worst;
    for (let waited = 0; ; waited += STEP_MS) {
        // eslint-disable-next-line no-await-in-loop
        const gots = await Promise.all(patches.map(p => shot(p.x, p.y, PATCH)));
        worst = gots.map((got, i) => ({at: patches[i], got, delta: Math.max(...got.map((v, c) => Math.abs(v - wants[i][c]))), want: wants[i]}))
            .reduce((a, b) => b.delta > a.delta ? b : a);
        if (worst.delta <= TOLERANCE)
            return {expected: want.name, file: want.file ?? null, patches: patches.length, delta: Math.round(worst.delta * 10) / 10, waitedMs: waited};
        if (waited >= WAIT_MS)
            break;
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(STEP_MS);
    }
    return {
        expected: want.name, file: want.file ?? null, pictureUri: picture,
        error: `the backdrop did not paint: after ${WAIT_MS} ms the desktop at ${worst.at.x},${worst.at.y} shows ` +
            `${hex(worst.got)} where ${want.name} has ${hex(worst.want)} (off by ${Math.round(worst.delta)})`,
    };
}
