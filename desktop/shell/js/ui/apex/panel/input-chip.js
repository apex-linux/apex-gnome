// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the input source is a text chip before the status pill, "EN" or "VI" (board 39).
// keyboard.js writes each source's short name, in lower case, from several places.

import * as Main from '../../main.js';

const ROLE = 'keyboard';

let _indicator = null;
let _childAddedId = 0;
let _sessionId = 0;
const _labels = new Map();

function _raise(label) {
    const text = label.text ?? '';
    const upper = text.toLocaleUpperCase();
    if (upper === text)
        return;
    _labels.get(label).stockText = text;
    label.text = upper;
}

function _track(label) {
    if (_labels.has(label))
        return;
    const entry = {stockText: label.text, textId: 0, destroyId: 0};
    _labels.set(label, entry);
    entry.textId = label.connect('notify::text', () => _raise(label));
    entry.destroyId = label.connect('destroy', () => _labels.delete(label));
    _raise(label);
}

function _attach() {
    const indicator = Main.panel.statusArea[ROLE];
    if (!indicator || indicator === _indicator)
        return;
    _detach();
    _indicator = indicator;
    _childAddedId = indicator._container.connect('child-added', (_container, label) => _track(label));
    indicator._container.get_children().forEach(_track);
}

function _detach() {
    if (!_indicator)
        return;
    _indicator._container.disconnect(_childAddedId);
    for (const [label, {stockText, textId, destroyId}] of _labels) {
        label.disconnect(textId);
        label.disconnect(destroyId);
        label.text = stockText;
    }
    _labels.clear();
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
