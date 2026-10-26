// SPDX-License-Identifier: GPL-2.0-or-later
//
// glass.js's frame reads: Cogl aborts the shell on a read with no area or past the framebuffer,
// so a step that computed such a rect fails by its name instead.

// The device-pixel rect G2Frame.read takes for a stage rect at scale, or a named error.
export function deviceRect(rect, scale, framebuffer, step) {
    const [x, y, width, height] = [rect.x, rect.y, rect.width, rect.height].map(v => Math.round(v * scale));
    const inside = [x, y, width, height].every(Number.isFinite) && width > 0 && height > 0 && x >= 0 && y >= 0 &&
        x + width <= framebuffer.width && y + height <= framebuffer.height;
    if (!inside) {
        throw new Error(`${step}: no frame read for ${x},${y} ${width}x${height} in a ` +
            `${framebuffer.width}x${framebuffer.height} framebuffer`);
    }
    return {x, y, width, height};
}
