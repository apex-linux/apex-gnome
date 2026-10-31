// SPDX-License-Identifier: GPL-3.0-or-later
//
// patch 0003's glass across two stage views: a box over their boundary, and one moved from one
// view to the other and back, each view's part read from its own framebuffer.

import GLib from 'gi://GLib';
import Mtk from 'gi://Mtk';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

import * as BlurRef from './blur-ref.js';

// The top bar's glass, as glass.js's pixel tests draw it (ADR 0014).
const SIGMA = 24;
const SATURATION = 1.6;
const CORNER_RADIUS = 18;
const BOX = {width: 320, height: 80, y: 300};
const TILE = 24;
const PALETTE = ['#e01b24', '#33d17a', '#3584e4', '#f6d32d', '#9141ac', '#ff7800', '#1c71d8', '#26a269'];
const FRAME_TIMEOUT_MS = 2000;

let G2Frame = null;

function colourOf(column, row) {
    return PALETTE[(column * 3 + row * 5) % PALETTE.length];
}

function rgbOf(hex) {
    return [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
}

function intersection(a, b) {
    const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
    const width = Math.min(a.x + a.width, b.x + b.width) - x, height = Math.min(a.y + a.height, b.y + b.height) - y;
    return width > 0 && height > 0 ? {x, y, width, height} : null;
}

function union(a, b) {
    const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
    return {x, y, width: Math.max(a.x + a.width, b.x + b.width) - x, height: Math.max(a.y + a.height, b.y + b.height) - y};
}

function layoutOf(view) {
    const layout = new Mtk.Rectangle();
    view.get_layout(layout);
    return {x: layout.x, y: layout.y, width: layout.width, height: layout.height};
}

function viewsOf(rect) {
    return global.stage.peek_stage_views().filter(view => intersection(layoutOf(view), rect));
}

// Each view's part of a stage rect, from the paint `redraw` causes in every view the rect meets,
// put together in device pixels; all of them share one scale here.
function viewFrame(rect, scale, redraw, label) {
    const wanted = viewsOf(rect);
    const rgba = new Uint8Array(rect.width * scale * rect.height * scale * 4);
    const painted = new Set();
    return new Promise((resolve, reject) => {
        const timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, FRAME_TIMEOUT_MS, () => {
            global.stage.disconnect(afterId);
            reject(new Error(`${label}: ${painted.size} of ${wanted.length} views painted within ${FRAME_TIMEOUT_MS} ms`));
            return GLib.SOURCE_REMOVE;
        });
        const afterId = global.stage.connect('after-paint', (_stage, view) => {
            if (!wanted.includes(view) || painted.has(view))
                return;
            painted.add(view);
            const layout = layoutOf(view);
            const part = intersection(layout, rect);
            const bytes = G2Frame.read(view.get_framebuffer(), (part.x - layout.x) * scale, (part.y - layout.y) * scale,
                part.width * scale, part.height * scale).toArray();
            const [width, offsetX, offsetY] = [rect.width * scale, (part.x - rect.x) * scale, (part.y - rect.y) * scale];
            for (let row = 0; row < part.height * scale; row++) {
                const from = row * part.width * scale * 4;
                rgba.set(bytes.slice(from, from + part.width * scale * 4), ((offsetY + row) * width + offsetX) * 4);
            }
            if (painted.size < wanted.length)
                return;
            global.stage.disconnect(afterId);
            GLib.source_remove(timeoutId);
            resolve({rgba, views: wanted.length});
        });
        redraw();
    });
}

function fullFrame(rect, scale, label) {
    return viewFrame(rect, scale, () => Main.uiGroup.queue_redraw(), label);
}

function tilesUnder(rect) {
    const pattern = new St.Widget({x: rect.x - TILE, y: rect.y - TILE});
    for (let row = 0; row < Math.ceil(rect.height / TILE) + 2; row++) {
        for (let column = 0; column < Math.ceil(rect.width / TILE) + 2; column++) {
            pattern.add_child(new St.Widget({
                x: column * TILE, y: row * TILE, width: TILE, height: TILE,
                style: `background-color: ${colourOf(column, row)};`,
            }));
        }
    }
    Main.uiGroup.insert_child_above(pattern, global.window_group);
    return pattern;
}

// The pattern under a box, in device pixels, as tilesUnder(around) laid it.
function patternUnder(box, around, scale) {
    const [width, height] = [box.width * scale, box.height * scale];
    const rgba = new Uint8Array(width * height * 4);
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            const column = Math.floor((box.x - around.x + TILE + x / scale) / TILE);
            const row = Math.floor((box.y - around.y + TILE + y / scale) / TILE);
            rgba.set([...rgbOf(colourOf(column, row)), 255], 4 * (y * width + x));
        }
    }
    return rgba;
}

function effectFor(scale) {
    return new Shell.BlurEffect({
        mode: Shell.BlurMode.BACKGROUND, radius: 2 * SIGMA * scale, saturation: SATURATION,
        corner_radius: CORNER_RADIUS * scale, fine: true,
    });
}

// A fresh effect keeps no result of an earlier frame: its full redraw is the same state's own.
async function freshFrame(glass, rect, scale, label) {
    glass.clear_effects();
    glass.add_effect(effectFor(scale));
    return (await fullFrame(rect, scale, label)).rgba;
}

// Against blur-ref.js's blur: in the columns a kernel's reach, 3 sigma, takes from the boundary,
// where each view blurs without the other's pixels, and away from them as glass.js's bounds read.
function againstReference(rgba, expected, box, boundary, scale) {
    const [width, height] = [box.width * scale, box.height * scale];
    const band = BlurRef.fineDownscale(width, height, SIGMA * scale) / 2;
    const seamX = (boundary - box.x) * scale, reach = 3 * SIGMA * scale;
    const seam = {max: 0}, interior = {max: 0}, edge = {max: 0};
    const sums = [0, 0, 0];
    let count = 0;
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            const p = y * width + x;
            const errors = [0, 1, 2].map(c => Math.abs(rgba[4 * p + c] - expected[3 * p + c]));
            if (Math.abs(x - seamX) < reach) {
                seam.max = Math.max(seam.max, ...errors);
                continue;
            }
            const near = Math.min(x, y, width - 1 - x, height - 1 - y) < band ? edge : interior;
            near.max = Math.max(near.max, ...errors);
            errors.forEach((error, c) => (sums[c] += error));
            count++;
        }
    }
    // As blur-ref.js's errors(): the mean per channel, the largest of the three.
    const round = v => Math.round(v * 1000) / 1000;
    return {
        band, seamMax: round(seam.max), interiorMax: round(interior.max), edgeMax: round(edge.max),
        mean: round(Math.max(...sums) / count),
    };
}

export async function glassViewsReport() {
    G2Frame = (await import('gi://G2Frame')).default;
    const views = global.stage.peek_stage_views().sort((a, b) => layoutOf(a).x - layoutOf(b).x);
    if (views.length !== 2 || views[0].get_scale() !== views[1].get_scale())
        return {views: views.length, scales: views.map(view => view.get_scale())};
    const boundary = layoutOf(views[1]).x;
    const scale = views[0].get_scale();
    const straddle = {...BOX, x: boundary - BOX.width / 2};
    const inLeft = {...BOX, x: boundary - BOX.width - 2 * TILE};
    const inRight = {...BOX, x: boundary + 2 * TILE};
    const around = union(union(inLeft, inRight), straddle);
    const pattern = tilesUnder(around);
    const glass = new St.Widget({...straddle});
    Main.uiGroup.add_child(glass);
    glass.add_effect(effectFor(scale));
    try {
        await Scripting.waitLeisure();
        await fullFrame(straddle, scale, 'settle');
        const live = (await fullFrame(straddle, scale, 'straddling')).rgba;
        const expected = BlurRef.glass(patternUnder(straddle, around, scale), straddle.width * scale, straddle.height * scale,
            {sigma: SIGMA * scale, saturation: SATURATION, cornerRadius: CORNER_RADIUS * scale});
        const fresh = await freshFrame(glass, straddle, scale, 'straddling, fresh');
        const straddling = {
            views: viewsOf(straddle).length,
            live: againstReference(live, expected, straddle, boundary, scale),
            fresh: againstReference(fresh, expected, straddle, boundary, scale),
            liveDifferingFromFresh: BlurRef.differing(live, fresh),
        };

        const move = async (from, to, label) => {
            glass.set_position(from.x, from.y);
            await fullFrame(from, scale, `${label}, before`);
            const span = union(from, to);
            const frame = await viewFrame(span, scale, () => glass.set_position(to.x, to.y), label);
            const full = await freshFrame(glass, span, scale, `${label}, fresh`);
            return {views: frame.views, differingFromFresh: BlurRef.differing(frame.rgba, full), pixels: full.length / 4};
        };
        const across = await move(inLeft, inRight, 'moved across');
        const back = await move(inRight, inLeft, 'moved back');
        return {views: 2, scale, boundary, straddling, across, back};
    } finally {
        glass.destroy();
        pattern.destroy();
    }
}
