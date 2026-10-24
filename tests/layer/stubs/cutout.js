// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/apex/shadows/cutout.js: it records the radius it cuts out.

export const EFFECT_NAME = 'apex-shadow-cutout';

export function addCutout(layer, radius) {
    layer.cutout = radius;
}
