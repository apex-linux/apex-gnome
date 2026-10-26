// SPDX-License-Identifier: GPL-2.0-or-later

// cutout.js's uniforms, apart from its shader effect for the layer tests; null for a paint box
// with no area, whose 0 width or height would make every uniform NaN.
export function cutoutUniforms(box, extents, width, height, radius) {
    const [boxWidth, boxHeight] = [box.x2 - box.x1, box.y2 - box.y1];
    if (!(Number.isFinite(boxWidth) && boxWidth > 0 && Number.isFinite(boxHeight) && boxHeight > 0))
        return null;
    return {
        rect: [
            (extents.origin.x - box.x1) / boxWidth, (extents.origin.y - box.y1) / boxHeight,
            (extents.origin.x + extents.size.width - box.x1) / boxWidth,
            (extents.origin.y + extents.size.height - box.y1) / boxHeight,
        ],
        size: [width, height],
        radius: radius * width / boxWidth,
    };
}
