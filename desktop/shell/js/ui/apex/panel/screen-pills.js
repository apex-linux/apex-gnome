// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: recording and screen sharing are pills of their own, each with a white stop square
// (board 39). remoteAccess.js's buttons keep their clicks; their stop glyphs give way.

import Clutter from 'gi://Clutter';
import St from 'gi://St';

import * as Main from '../../main.js';

const STOP_ICON = 'screencast-stop-symbolic';
const SHARING_NAME = 'Stop screen sharing';
// The square leads the recording's timer and follows the sharing glyph.
const PILLS = [{role: 'screenRecording', squareFirst: true}, {role: 'screenSharing', squareFirst: false}];

const _attached = new Map();
let _sessionId = 0;

function _attach(role, squareFirst) {
    const button = Main.panel.statusArea[role];
    if (!button || _attached.get(role)?.button === button)
        return;
    _detach(role);
    const box = button.get_first_child();
    const stop = box.get_children().find(c => c.icon_name === STOP_ICON);
    const square = new St.Widget({style_class: 'apex-screen-stop', y_align: Clutter.ActorAlign.CENTER});
    if (squareFirst)
        box.insert_child_at_index(square, 0);
    else
        box.add_child(square);
    stop?.hide();
    _attached.set(role, {button, square, stop, accessibleName: button.accessible_name});
}

function _detach(role) {
    const entry = _attached.get(role);
    if (!entry)
        return;
    entry.square.destroy();
    entry.stop?.show();
    entry.button.accessible_name = entry.accessibleName;
    _attached.delete(role);
}

// panel.js re-adds its own items in stock order whenever the session mode changes.
function _placeSharing() {
    const sharing = _attached.get('screenSharing');
    const {quickSettings} = Main.panel.statusArea;
    if (!sharing || !quickSettings)
        return;
    sharing.button.accessible_name = SHARING_NAME;
    const parent = quickSettings.container.get_parent();
    if (sharing.button.container.get_parent() === parent)
        parent.set_child_below_sibling(sharing.button.container, quickSettings.container);
}

function _sync() {
    for (const {role, squareFirst} of PILLS)
        _attach(role, squareFirst);
    _placeSharing();
}

export function configure() {}

export function enable() {
    _sessionId = Main.sessionMode.connect('updated', _sync);
    _sync();
}

export function disable() {
    if (_sessionId)
        Main.sessionMode.disconnect(_sessionId);
    _sessionId = 0;
    const sharing = _attached.get('screenSharing');
    const recording = Main.panel.statusArea.screenRecording;
    if (sharing && recording?.container.get_parent() === sharing.button.container.get_parent())
        recording.container.get_parent().set_child_above_sibling(sharing.button.container, recording.container);
    for (const {role} of PILLS)
        _detach(role);
}
