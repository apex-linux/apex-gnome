// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/apex/indicators/mask.js: a GLSL effect needs the shell's
// renderer, and G2 checks the colour it draws.

export class MaskEffect {
    setColor(color) {
        this.color = color;
    }
}
