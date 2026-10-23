// SPDX-License-Identifier: GPL-3.0-or-later

import GLib from 'gi://GLib';
import System from 'system';

import * as Png from './png.js';

const MASK_TINT = [40, 90, 200];
const DIFFERENCE = [255, 0, 40];

function usage() {
    return `usage: gjs -m tests/shots/compare.js PLAN.json RESULTS.json

PLAN is a list of {name, expected, actual, masks: [{name, x, y, width, height}], diff}:
two captures of one scene, compared pixel for pixel outside the masks (in capture pixels),
and where to write the difference image. RESULTS gets one entry per pair.

Exit status: 0 when every pair is equal outside its masks, 1 when one differs, 2 when a
pair could not be compared.`;
}

function read(path) {
    const [, bytes] = GLib.file_get_contents(path);
    return Png.decode(bytes);
}

function maskMap(width, height, masks) {
    const masked = new Uint8Array(width * height);
    for (const m of masks) {
        const x0 = Math.max(0, m.x);
        const y0 = Math.max(0, m.y);
        const x1 = Math.min(width, m.x + m.width);
        const y1 = Math.min(height, m.y + m.height);
        for (let y = y0; y < y1; y++)
            masked.fill(1, y * width + x0, y * width + Math.max(x0, x1));
    }
    return masked;
}

function differenceImage(expected, masked, differs) {
    const rgba = new Uint8Array(expected.rgba.length);
    for (let p = 0; p < masked.length; p++) {
        const at = p * 4;
        const grey = (expected.rgba[at] + expected.rgba[at + 1] + expected.rgba[at + 2]) / 9;
        if (differs[p])
            rgba.set(DIFFERENCE, at);
        else if (masked[p])
            rgba.set(MASK_TINT.map(c => (c + grey) / 2), at);
        else
            rgba.set([grey, grey, grey], at);
        rgba[at + 3] = 255;
    }
    return {width: expected.width, height: expected.height, rgba};
}

function comparePair(pair) {
    const expected = read(pair.expected);
    const actual = read(pair.actual);
    if (expected.width !== actual.width || expected.height !== actual.height) {
        return {
            name: pair.name, error: `sizes differ: ${expected.width}x${expected.height} ` +
                `against ${actual.width}x${actual.height}`,
        };
    }
    const {width, height} = expected;
    const masked = maskMap(width, height, pair.masks);
    const differs = new Uint8Array(width * height);
    let maskedCount = 0;
    let differing = 0;
    let box = null;
    for (let p = 0; p < masked.length; p++) {
        if (masked[p]) {
            maskedCount++;
            continue;
        }
        const at = p * 4;
        if (expected.rgba[at] === actual.rgba[at] && expected.rgba[at + 1] === actual.rgba[at + 1] &&
            expected.rgba[at + 2] === actual.rgba[at + 2] && expected.rgba[at + 3] === actual.rgba[at + 3])
            continue;
        differs[p] = 1;
        differing++;
        const x = p % width;
        const y = (p - x) / width;
        box = box
            ? {x0: Math.min(box.x0, x), y0: Math.min(box.y0, y), x1: Math.max(box.x1, x), y1: Math.max(box.y1, y)}
            : {x0: x, y0: y, x1: x, y1: y};
    }
    if (pair.diff && differing > 0)
        GLib.file_set_contents(pair.diff, Png.encode(differenceImage(expected, masked, differs)));
    return {
        name: pair.name,
        width,
        height,
        masks: pair.masks.map(m => m.name),
        masked: maskedCount,
        differing,
        box: box && {x: box.x0, y: box.y0, width: box.x1 - box.x0 + 1, height: box.y1 - box.y0 + 1},
        diff: differing > 0 ? pair.diff ?? null : null,
    };
}

function main(args) {
    if (args[0] === '-h' || args[0] === '--help') {
        print(usage());
        return 0;
    }
    const [planPath, resultsPath] = args;
    if (!planPath || !resultsPath) {
        printerr(usage());
        return 2;
    }
    const [, planBytes] = GLib.file_get_contents(planPath);
    const plan = JSON.parse(new TextDecoder().decode(planBytes));
    const results = plan.map(pair => {
        try {
            return comparePair(pair);
        } catch (e) {
            return {name: pair.name, error: e.message};
        }
    });
    GLib.file_set_contents(resultsPath, `${JSON.stringify(results, null, 1)}\n`);
    if (results.some(r => r.error))
        return 2;
    return results.some(r => r.differing > 0) ? 1 : 0;
}

let status;
try {
    status = main(System.programArgs);
} catch (e) {
    printerr(`compare.js: ${e.message}`);
    status = 2;
}
System.exit(status);
