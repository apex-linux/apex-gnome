// SPDX-License-Identifier: GPL-3.0-or-later
//
// gjs outside the shell has no Clutter: run.sh points the features' gi://Clutter imports here.

import GLib from 'gi://GLib';

const TextDirection = {DEFAULT: 0, LTR: 1, RTL: 2};
const AnimationMode = {LINEAR: 1, EASE_OUT_QUAD: 5, EASE_OUT_CUBIC: 8, EASE_OUT_EXPO: 21,
    STEPS: 46, STEP_START: 47, STEP_END: 48, CUBIC_BEZIER: 49};

class Actor {}

class BinLayout {}

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
    connect(signal, fn) {
        if (signal === 'recognize')
            this.recognize = fn;
    }
}

export default {
    Actor,
    AnimationMode,
    BUTTON_SECONDARY: 3,
    BinLayout,
    ClickGesture,
    KeyController,
    EventPhase: {BUBBLE: 0, CAPTURE: 1},
    Orientation: {HORIZONTAL: 0, VERTICAL: 1},
    KEY_Down: 0xff54,
    KEY_Escape: 0xff1b,
    KEY_ISO_Enter: 0xfe34,
    KEY_KP_Enter: 0xff8d,
    KEY_Return: 0xff0d,
    KEY_Up: 0xff52,
    ActorAlign: {FILL: 0, START: 1, CENTER: 2, END: 3},
    TextDirection,
    EVENT_PROPAGATE: false,
    EVENT_STOP: true,
    get_default_text_direction: () =>
        GLib.getenv('PROBE_RTL') === '1' ? TextDirection.RTL : TextDirection.LTR,
};
