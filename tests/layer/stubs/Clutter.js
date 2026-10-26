// SPDX-License-Identifier: GPL-3.0-or-later
//
// gjs outside the shell has no Clutter: run.sh points the features' gi://Clutter imports here.

import GLib from 'gi://GLib';

const TextDirection = {DEFAULT: 0, LTR: 1, RTL: 2};
const AnimationMode = {LINEAR: 1, EASE_OUT_QUAD: 5, EASE_OUT_CUBIC: 8, EASE_OUT_EXPO: 21,
    STEPS: 46, STEP_START: 47, STEP_END: 48, CUBIC_BEZIER: 49};

class Actor {}

class BinLayout {}

class BoxLayout {
    constructor(params = {}) {
        Object.assign(this, params);
    }
}

class Clone {
    constructor(params) {
        Object.assign(this, params);
    }

    destroy() {}
}

class Stage {}

// The probe sets the key a press reports, as Clutter does before emitting key-press.
class KeyController {
    connect(signal, fn) {
        if (signal === 'key-press')
            this.press = (symbol, keycode = 0) => {
                this._key = [true, symbol, keycode];
                return fn(this);
            };
    }

    get_key() {
        return this._key;
    }

    get_state() {
        return [true, 0, 0, 0];
    }
}

class ClickGesture {
    constructor(params = {}) {
        Object.assign(this, params);
    }

    connect(signal, fn) {
        if (signal === 'recognize')
            this.recognize = fn;
    }

    // What a click with that mouse button would do.
    click(button) {
        this._button = button;
        this.recognize(this);
    }

    get_button() {
        return this._button;
    }
}

class BindConstraint {
    constructor(params) {
        Object.assign(this, params);
    }
}

class ScrollController {
    constructor(params) {
        Object.assign(this, params);
    }

    connect(signal, fn) {
        if (signal === 'scroll')
            this.scroll = (dx, dy) => fn(this, null, null, dx, dy);
    }
}

export default {
    Actor,
    AnimationMode,
    BindConstraint,
    BindCoordinate: {X: 0, Y: 1, WIDTH: 2, HEIGHT: 3, POSITION: 4, SIZE: 5, ALL: 6},
    BUTTON_PRIMARY: 1,
    BUTTON_MIDDLE: 2,
    BUTTON_SECONDARY: 3,
    BinLayout,
    BoxLayout,
    Stage,
    ClickGesture,
    Clone,
    KeyController,
    EventPhase: {BUBBLE: 0, CAPTURE: 1},
    Orientation: {HORIZONTAL: 0, VERTICAL: 1},
    KEY_Down: 0xff54,
    KEY_Escape: 0xff1b,
    KEY_ISO_Enter: 0xfe34,
    KEY_KP_Enter: 0xff8d,
    KEY_Return: 0xff0d,
    KEY_Up: 0xff52,
    ScrollController,
    ScrollControllerFlags: {DISCRETE: 1, SCROLL_VERTICAL: 2, SCROLL_HORIZONTAL: 4},
    get_current_event_time: () => 0,
    ActorAlign: {FILL: 0, START: 1, CENTER: 2, END: 3},
    GridPosition: {LEFT: 0, RIGHT: 1, TOP: 2, BOTTOM: 3},
    TextDirection,
    EVENT_PROPAGATE: false,
    EVENT_STOP: true,
    get_default_text_direction: () =>
        GLib.getenv('PROBE_RTL') === '1' ? TextDirection.RTL : TextDirection.LTR,
};
