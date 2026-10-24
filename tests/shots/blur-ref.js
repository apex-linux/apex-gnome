// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CPU reference of glass: a Gaussian blur of what lies under the box, CSS saturate()
// and the rounded box's coverage, in the box's own pixels as ShellBlurEffect sees them.

const LUMA = [0.213, 0.715, 0.072];
const KERNEL_SIGMAS = 4;

function kernel(sigma) {
    const radius = Math.ceil(KERNEL_SIGMAS * sigma);
    const weights = new Float64Array(2 * radius + 1);
    let total = 0;
    for (let i = -radius; i <= radius; i++) {
        weights[i + radius] = Math.exp(-(i * i) / (2 * sigma * sigma));
        total += weights[i + radius];
    }
    return {radius, weights: weights.map(w => w / total)};
}

// The effect blurs a blit of the box alone, so its edges clamp.
function blurPass(src, width, height, sigma, horizontal) {
    const {radius, weights} = kernel(sigma);
    const out = new Float64Array(src.length);
    const along = horizontal ? width : height;
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            const at = horizontal ? x : y;
            let r = 0, g = 0, b = 0;
            for (let k = -radius; k <= radius; k++) {
                const p = Math.min(along - 1, Math.max(0, at + k));
                const i = 3 * (horizontal ? y * width + p : p * width + x);
                const w = weights[k + radius];
                r += w * src[i];
                g += w * src[i + 1];
                b += w * src[i + 2];
            }
            const o = 3 * (y * width + x);
            out[o] = r;
            out[o + 1] = g;
            out[o + 2] = b;
        }
    }
    return out;
}

export function rgbOf(rgba) {
    const rgb = new Float64Array(rgba.length / 4 * 3);
    for (let i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
        rgb[j] = rgba[i];
        rgb[j + 1] = rgba[i + 1];
        rgb[j + 2] = rgba[i + 2];
    }
    return rgb;
}

export function gaussianBlur(rgb, width, height, sigma) {
    if (sigma <= 0)
        return Float64Array.from(rgb);
    return blurPass(blurPass(rgb, width, height, sigma, true), width, height, sigma, false);
}

export function saturate(rgb, saturation) {
    const out = new Float64Array(rgb.length);
    for (let i = 0; i < rgb.length; i += 3) {
        const luma = LUMA[0] * rgb[i] + LUMA[1] * rgb[i + 1] + LUMA[2] * rgb[i + 2];
        for (let c = 0; c < 3; c++)
            out[i + c] = Math.min(255, Math.max(0, luma + (rgb[i + c] - luma) * saturation));
    }
    return out;
}

// The signed distance to a rounded box, at the pixel's centre, as the shader computes it.
export function coverage(x, y, width, height, radius) {
    const qx = Math.abs(x + 0.5 - width / 2) - (width / 2 - radius);
    const qy = Math.abs(y + 0.5 - height / 2) - (height / 2 - radius);
    const d = Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - radius;
    return Math.min(1, Math.max(0, 0.5 - d));
}

export function glass(rgba, width, height, {sigma, saturation, cornerRadius}) {
    const under = rgbOf(rgba);
    const blurred = saturate(gaussianBlur(under, width, height, sigma), saturation);
    const out = new Float64Array(under.length);
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            const a = coverage(x, y, width, height, cornerRadius);
            const i = 3 * (y * width + x);
            for (let c = 0; c < 3; c++)
                out[i + c] = blurred[i + c] * a + under[i + c] * (1 - a);
        }
    }
    return out;
}

function stats(rgba, expectedRgb, width, height, counts) {
    const max = [0, 0, 0];
    const sum = [0, 0, 0];
    let n = 0;
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            if (!counts(x, y))
                continue;
            n++;
            const p = y * width + x;
            for (let c = 0; c < 3; c++) {
                const e = Math.abs(rgba[4 * p + c] - expectedRgb[3 * p + c]);
                max[c] = Math.max(max[c], e);
                sum[c] += e;
            }
        }
    }
    return {
        max: max.map(v => Math.round(v * 100) / 100),
        mean: sum.map(v => Math.round(v / Math.max(n, 1) * 1000) / 1000),
        pixels: n,
    };
}

// Per channel, over the box, its interior and the band of `band` pixels along its edges.
export function errors(rgba, expectedRgb, width, height, band = 0) {
    const inBand = (x, y) => Math.min(x, y, width - 1 - x, height - 1 - y) < band;
    return {
        box: stats(rgba, expectedRgb, width, height, () => true),
        interior: stats(rgba, expectedRgb, width, height, (x, y) => !inBand(x, y)),
        edge: stats(rgba, expectedRgb, width, height, inBand),
    };
}

// patch 0003's fine downscale: the smallest power of two with sigma / ds <= 4 and a side of 4 px.
export function fineDownscale(width, height, sigma) {
    let ds = 1;
    while (sigma / ds > 4 && Math.min(width, height) / (ds * 2) >= 4)
        ds *= 2;
    return ds;
}

export function differing(a, b) {
    let count = 0;
    for (let i = 0; i < a.length; i += 4) {
        if (a[i] !== b[i] || a[i + 1] !== b[i + 1] || a[i + 2] !== b[i + 2] || a[i + 3] !== b[i + 3])
            count++;
    }
    return count;
}
