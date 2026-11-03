// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the input source is a text chip before the status pill, "EN" or "VI" (board 39).
// keyboard.js writes each source's short name from several places: lower case, or an IBus symbol.

import Pango from 'gi://Pango';

import * as Main from '../../main.js';

const ROLE = 'keyboard';

let _indicator = null;
let _childAddedId = 0;
let _sessionId = 0;
const _labels = new Map();

const SUBSCRIPTS = /[\u2080-\u2089]*$/;

function _sourceOf(label) {
    return _indicator._inputSources?.find(is =>
        _indicator._indicatorLabels?.[_indicator._calculateSourceIndicatorIndex(is)] === label);
}

function _languageOf(is) {
    const engine = _indicator._inputSourceManager?._ibusManager?.getEngineDesc(is.id);
    const [code = ''] = engine?.get_language()?.split('_', 1) ?? [];
    return code.length === 2 || code.length === 3 ? code : null;
}

// An IBus engine's symbol ("Ắ" for Telex) says how it types, not which language: the chip says that.
function _chipText(label, text) {
    const is = _sourceOf(label);
    const language = is?.type === 'ibus' ? _languageOf(is) : null;
    return language ? `${language}${text.match(SUBSCRIPTS)[0]}`.toLocaleUpperCase() : text.toLocaleUpperCase();
}

function _raise(label) {
    const text = label.text ?? '';
    const chip = _chipText(label, text);
    if (chip === text)
        return;
    _labels.get(label).stockText = text;
    label.text = chip;
}

// The chip is sized to its label, yet with Large Text the bold, tracked short name can ellipsize
// at exactly its own natural width: a short name is never meant to be cut, so it is drawn whole.
function _track(label) {
    if (_labels.has(label))
        return;
    const entry = {stockText: label.text, stockEllipsize: label.clutter_text.ellipsize, textId: 0, destroyId: 0};
    _labels.set(label, entry);
    label.clutter_text.ellipsize = Pango.EllipsizeMode.NONE;
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
    for (const [label, {stockText, stockEllipsize, textId, destroyId}] of _labels) {
        label.disconnect(textId);
        label.disconnect(destroyId);
        label.text = stockText;
        label.clutter_text.ellipsize = stockEllipsize;
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
