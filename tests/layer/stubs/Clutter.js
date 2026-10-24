// SPDX-License-Identifier: GPL-3.0-or-later
//
// gjs outside the shell has no Clutter: run.sh points the features' gi://Clutter imports here.

import GLib from 'gi://GLib';

const TextDirection = {DEFAULT: 0, LTR: 1, RTL: 2};
const AnimationMode = {LINEAR: 1, EASE_OUT_QUAD: 5, EASE_OUT_CUBIC: 8, EASE_OUT_EXPO: 21,
    STEPS: 46, STEP_START: 47, STEP_END: 48, CUBIC_BEZIER: 49};

class Actor {}

class BinLayout {}

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
    ActorAlign: {FILL: 0, START: 1, CENTER: 2, END: 3},
    TextDirection,
    EVENT_PROPAGATE: false,
    EVENT_STOP: true,
    get_default_text_direction: () =>
        GLib.getenv('PROBE_RTL') === '1' ? TextDirection.RTL : TextDirection.LTR,
};
