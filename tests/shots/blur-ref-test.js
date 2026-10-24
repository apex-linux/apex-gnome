// SPDX-License-Identifier: GPL-3.0-or-later

import System from 'system';

import * as BlurRef from './blur-ref.js';

let tests = 0;
let failed = 0;

function ok(condition, name) {
    tests++;
    if (!condition)
        failed++;
    print(`${condition ? 'ok' : 'not ok'} ${tests} - ${name}`);
}

function near(a, b, epsilon = 1e-6) {
    return Math.abs(a - b) <= epsilon;
}

function image(width, height, colourAt) {
    const rgba = new Uint8Array(width * height * 4);
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++)
            rgba.set([...colourAt(x, y), 255], 4 * (y * width + x));
    }
    return rgba;
}

const flat = BlurRef.rgbOf(image(32, 8, () => [200, 40, 90]));
ok(BlurRef.gaussianBlur(flat, 32, 8, 5).every((v, i) => near(v, flat[i])),
    'a flat image stays flat under the blur, edges included');

const impulse = new Float64Array(64 * 3);
impulse[3 * 32] = 255;
const spread = BlurRef.gaussianBlur(impulse, 64, 1, 3);
const total = spread.filter((_, i) => i % 3 === 0).reduce((a, b) => a + b, 0);
ok(near(total, 255, 1e-3), 'the blur keeps an impulse\'s energy away from the edges');
ok(near(spread[3 * 29], spread[3 * 35]), 'and spreads it symmetrically');
ok(near(spread[3 * 35] / spread[3 * 32], Math.exp(-9 / 18), 1e-6), 'as a Gaussian of the given sigma');

const step = BlurRef.rgbOf(image(16, 1, x => x < 8 ? [0, 0, 0] : [255, 255, 255]));
const edge = BlurRef.gaussianBlur(step, 16, 1, 40);
ok(edge[0] < 128 && edge[3 * 15] > 128, 'the box edges clamp: a wide blur of a step keeps its sides apart');

const colour = BlurRef.rgbOf(image(1, 1, () => [220, 60, 30]));
ok(BlurRef.saturate(colour, 1).every((v, i) => near(v, colour[i])), 'saturate(1) is the identity');
const grey = BlurRef.saturate(colour, 0);
ok(near(grey[0], grey[1]) && near(grey[1], grey[2]) && near(grey[0], 0.213 * 220 + 0.715 * 60 + 0.072 * 30),
    'saturate(0) is CSS\'s luminance');
const vivid = BlurRef.saturate(colour, 1.6);
ok(vivid[0] === 255 && vivid[2] >= 0 && vivid[2] < 30, 'saturate(1.6) pushes away from grey and clamps');

ok(BlurRef.coverage(50, 20, 100, 40, 18) === 1, 'coverage: the interior is covered');
ok(BlurRef.coverage(0, 20, 100, 40, 18) === 1, 'the straight edge\'s pixels are covered');
ok(BlurRef.coverage(0, 0, 100, 40, 18) === 0, 'the corner pixel outside the radius is not');
const rim = BlurRef.coverage(5, 5, 100, 40, 18);
ok(rim > 0 && rim < 1, 'pixels on the arc are partly covered');
ok(BlurRef.coverage(0, 0, 100, 40, 0) === 1, 'radius 0 covers every pixel');

const pattern = image(8, 4, x => x % 2 ? [255, 0, 0] : [0, 0, 255]);
const sharp = BlurRef.glass(pattern, 8, 4, {sigma: 0, saturation: 1, cornerRadius: 0});
ok(sharp.every((v, i) => near(v, pattern[4 * Math.floor(i / 3) + (i % 3)])), 'glass with sigma 0, saturation 1 and no corners is the pattern');

const exact = image(4, 2, () => [10, 20, 30]);
const expected = Float64Array.from([10, 20, 30, 10, 20, 30, 10, 20, 30, 10, 20, 30, 10, 20, 30, 10, 20, 30, 10, 20, 30, 10, 20, 34]);
const stats = BlurRef.errors(exact, expected, 4, 2);
ok(stats.max[2] === 4 && near(stats.mean[2], 0.5) && stats.max[0] === 0, 'errors: per-channel max and mean');
const wide = image(6, 4, () => [10, 20, 30]);
const offAtCorner = BlurRef.rgbOf(wide);
offAtCorner[2] = 90;
ok(BlurRef.errors(wide, offAtCorner, 6, 4).max[2] === 60 && BlurRef.errors(wide, offAtCorner, 6, 4, 1).max[2] === 0,
    'errors: a band leaves the edges out');
ok(BlurRef.differing(exact, exact) === 0 && BlurRef.differing(exact, image(4, 2, (x, y) => x + y ? [10, 20, 30] : [0, 0, 0])) === 1,
    'differing counts pixels, not channels');

// ADR 0014's cost model (0014-blurcost.py, apex_cost): the bar at 2880x64, sigma 48.
ok(BlurRef.fineDownscale(2880, 64, 48) === 16, 'fineDownscale: the bar downscales by 16, as the cost model does');
ok(BlurRef.fineDownscale(640, 160, 48) === 16 && BlurRef.fineDownscale(100, 100, 3) === 1,
    'and stops at sigma 4 or a 4 px side');

print(`1..${tests}`);
System.exit(failed === 0 ? 0 : 1);
