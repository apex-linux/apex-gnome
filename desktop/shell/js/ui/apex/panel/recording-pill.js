// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: screen recording is its own red pill, a stop square before the timer (board 39).
// remoteAccess.js's indicator keeps its click; only its glyph and their order change.

import Clutter from 'gi://Clutter';
import St from 'gi://St';

import * as Main from '../../main.js';

const ROLE = 'screenRecording';

let _indicator = null;
let _square = null;
let _sessionId = 0;

function _attach() {
    const indicator = Main.panel.statusArea[ROLE];
    if (!indicator || indicator === _indicator)
        return;
    _detach();
    _indicator = indicator;
    _square = new St.Widget({style_class: 'apex-recording-stop', y_align: Clutter.ActorAlign.CENTER});
    indicator._box.insert_child_at_index(_square, 0);
    indicator._icon.hide();
}

function _detach() {
    if (!_indicator)
        return;
    _square.destroy();
    _square = null;
    _indicator._icon.show();
    _indicator = null;
}

export function configure() {}

export function enable() {
    // panel.js makes the indicator the first time a session mode lists it.
    _sessionId = Main.sessionMode.connect('updated', _attach);
    _attach();
}

export function disable() {
    if (_sessionId)
        Main.sessionMode.disconnect(_sessionId);
    _sessionId = 0;
    _detach();
}
