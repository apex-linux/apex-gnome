// SPDX-License-Identifier: GPL-3.0-or-later
//
// gjs outside the shell has no St: run.sh points the features' gi://St imports here.

import GLib from 'gi://GLib';

const scaleFactor = Number(GLib.getenv('PROBE_SCALE') ?? '1');

class Label {
    constructor(params) {
        Object.assign(this, {visible: true, width: 120}, params);
    }

    show() {
        this.visible = true;
    }

    hide() {
        this.visible = false;
    }

    set_position(x, y) {
        Object.assign(this, {x, y});
    }

    destroy() {
        this.destroyed = true;
    }
}

class Bin extends Label {}
class Icon extends Label {}

// St.Settings' high-contrast, which the probe turns on and off.
const settingsHandlers = new Map();
let nextSettingsHandler = 1;
const settings = {
    high_contrast: false,
    connect(signal, fn) {
        settingsHandlers.set(nextSettingsHandler, [signal, fn]);
        return nextSettingsHandler++;
    },
    disconnect(id) {
        settingsHandlers.delete(id);
    },
    setHighContrast(on) {
        this.high_contrast = on;
        for (const [signal, fn] of [...settingsHandlers.values()]) {
            if (signal === 'notify::high-contrast')
                fn();
        }
    },
};

export default {
    Bin,
    Icon,
    Label,
    Corner: {TOPLEFT: 0, TOPRIGHT: 1, BOTTOMRIGHT: 2, BOTTOMLEFT: 3},
    Settings: {get: () => settings},
    ThemeContext: {get_for_stage: () => ({scale_factor: scaleFactor})},
};
