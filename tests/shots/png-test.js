// SPDX-License-Identifier: GPL-3.0-or-later

import GLib from 'gi://GLib';
import System from 'system';

import * as Png from './png.js';

let tests = 0;
let failed = 0;

function usage() {
    return `usage: gjs -m tests/shots/png-test.js [SCRATCH_DIR]

Tests png.js against itself, with every filter type, and against libpng through GdkPixbuf,
whose adaptive filtering is what a shell capture uses. Prints TAP. The libpng cross-check
is skipped where GdkPixbuf cannot write a PNG (its loaders may be sandboxed). SCRATCH_DIR
defaults to the temporary directory.`;
}

function ok(condition, name) {
    tests++;
    if (!condition)
        failed++;
    print(`${condition ? 'ok' : 'not ok'} ${tests} - ${name}`);
}

function skip(name, why) {
    tests++;
    print(`ok ${tests} # SKIP ${name}: ${why}`);
}

function throws(fn, pattern, name) {
    try {
        fn();
        ok(false, `${name} (no exception)`);
    } catch (e) {
        ok(pattern.test(e.message), `${name} (${e.message})`);
    }
}

function equalBytes(a, b) {
    return a.length === b.length && a.every((v, i) => v === b[i]);
}

function noisyGradient(width, height, alpha) {
    const rgba = new Uint8Array(width * height * 4);
    let seed = 12345;
    for (let p = 0; p < width * height; p++) {
        seed = (seed * 1103515245 + 12345) >>> 0;
        const x = p % width;
        const y = (p - x) / width;
        rgba[p * 4] = (x * 7 + (seed >>> 24)) & 0xff;
        rgba[p * 4 + 1] = (y * 5 + (seed >>> 16)) & 0xff;
        rgba[p * 4 + 2] = (x * y) & 0xff;
        rgba[p * 4 + 3] = alpha ? (seed >>> 8) & 0xff : 255;
    }
    return {width, height, rgba};
}

function roundTrips() {
    const image = noisyGradient(37, 23, true);
    for (const [name, filter] of Object.entries(Png.Filter)) {
        const decoded = Png.decode(Png.encode(image, () => filter));
        ok(decoded.width === 37 && decoded.height === 23 && equalBytes(decoded.rgba, image.rgba),
            `every row filtered ${name} decodes to the same pixels`);
    }
    const mixed = Png.decode(Png.encode(image, y => y % 5));
    ok(equalBytes(mixed.rgba, image.rgba), 'rows with alternating filter types decode to the same pixels');
    ok(JSON.stringify(Png.size(Png.encode(image))) === '{"width":37,"height":23}', 'size reads the header');
}

function rejects() {
    throws(() => Png.decode(new TextEncoder().encode('not a png at all, just text')), /not a PNG/,
        'a file that is not a PNG is refused');
    const sixteenBit = Png.encode(noisyGradient(4, 4, true));
    sixteenBit[24] = 16;
    throws(() => Png.decode(sixteenBit), /8-bit RGB or RGBA only/, 'a 16-bit PNG is refused');
}

async function againstLibpng(scratch) {
    let GdkPixbuf;
    try {
        GdkPixbuf = (await import('gi://GdkPixbuf')).default;
    } catch (e) {
        skip('libpng cross-check', `no GdkPixbuf (${e.message})`);
        return;
    }
    for (const alpha of [true, false]) {
        const name = alpha ? 'RGBA' : 'RGB';
        const image = noisyGradient(61, 29, alpha);
        const pixbuf = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, alpha, 8, 61, 29);
        const stride = pixbuf.get_rowstride();
        const channels = alpha ? 4 : 3;
        const packed = new Uint8Array(stride * 29);
        for (let p = 0; p < 61 * 29; p++) {
            const x = p % 61;
            const y = (p - x) / 61;
            for (let c = 0; c < channels; c++)
                packed[y * stride + x * channels + c] = image.rgba[p * 4 + c];
        }
        const source = GdkPixbuf.Pixbuf.new_from_bytes(new GLib.Bytes(packed),
            GdkPixbuf.Colorspace.RGB, alpha, 8, 61, 29, stride);
        const path = GLib.build_filenamev([scratch, `libpng-${name}.png`]);
        try {
            source.savev(path, 'png', [], []);
        } catch (e) {
            skip(`libpng cross-check (${name})`, `GdkPixbuf cannot write PNG (${e.message})`);
            continue;
        }
        const [, bytes] = GLib.file_get_contents(path);
        ok(equalBytes(Png.decode(bytes).rgba, image.rgba), `an ${name} PNG written by libpng decodes to its pixels`);
    }
}

const [scratch] = System.programArgs;
if (scratch === '-h' || scratch === '--help') {
    print(usage());
    System.exit(0);
}
roundTrips();
rejects();
await againstLibpng(scratch ?? GLib.get_tmp_dir());
print(`1..${tests}`);
System.exit(failed === 0 ? 0 : 1);
