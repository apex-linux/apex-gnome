// SPDX-License-Identifier: GPL-3.0-or-later
//
// gjs outside the shell has no Clutter: run.sh points the features' gi://Clutter imports here.

import GLib from 'gi://GLib';

const TextDirection = {DEFAULT: 0, LTR: 1, RTL: 2};

class BinLayout {}

class BindConstraint {
    constructor(params) {
        Object.assign(this, params);
    }
}

class Clone {
    constructor(params) {
        Object.assign(this, params);
    }

    destroy() {}
}

class ClickGesture {
    connect(signal, fn) {
        if (signal === 'recognize')
            this.recognize = fn;
    }
}

export default {
    AnimationMode: {EASE_OUT_QUAD: 5, EASE_OUT_CUBIC: 8},
    BUTTON_SECONDARY: 3,
    BinLayout,
    BindConstraint,
    BindCoordinate: {X: 0, Y: 1, WIDTH: 2, HEIGHT: 3, POSITION: 4, SIZE: 5, ALL: 6},
    ClickGesture,
    Clone,
    ActorAlign: {FILL: 0, START: 1, CENTER: 2, END: 3},
    TextDirection,
    EVENT_PROPAGATE: false,
    EVENT_STOP: true,
    get_default_text_direction: () =>
        GLib.getenv('PROBE_RTL') === '1' ? TextDirection.RTL : TextDirection.LTR,
};
