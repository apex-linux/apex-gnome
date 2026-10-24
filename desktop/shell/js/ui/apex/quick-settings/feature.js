// SPDX-License-Identifier: GPL-2.0-or-later

import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';

export const LIT_STYLE_CLASS = 'apex-lit';
export const ON = 'On';
export const OFF = 'Off';

let _enabled = false;
let _applied = false;
let _vpnPlace = null;
let _lit = null;
const _subtitles = new Map();

function _grid(quickSettings) {
    return quickSettings.menu._grid;
}

function _moveVpn(quickSettings) {
    const vpn = quickSettings._network?._vpnToggle;
    const airplane = quickSettings._rfkill?.quickSettingsItems[0];
    const grid = _grid(quickSettings);
    if (!vpn || !airplane || vpn.get_parent() !== grid || airplane.get_parent() !== grid)
        return;
    _vpnPlace = {vpn, before: vpn.get_next_sibling()};
    grid.set_child_above_sibling(vpn, airplane);
}

function _restoreVpn() {
    if (!_vpnPlace)
        return;
    const {vpn, before} = _vpnPlace;
    const grid = vpn.get_parent();
    if (grid && before?.get_parent() === grid)
        grid.set_child_below_sibling(vpn, before);
    _vpnPlace = null;
}

function _light(quickSettings) {
    const toggle = quickSettings._powerProfiles?.quickSettingsItems[0];
    if (!toggle)
        return;
    toggle.add_style_class_name(LIT_STYLE_CLASS);
    _lit = toggle;
}

function _stateText(toggle) {
    return toggle.checked ? ON : OFF;
}

// A toggle's own subtitle always wins; ours fills in only while it has none.
function _followSubtitle(toggle) {
    const entry = _subtitles.get(toggle);
    if (toggle.subtitle && toggle.subtitle !== entry.text)
        return;
    entry.text = _stateText(toggle);
    if (toggle.subtitle !== entry.text)
        toggle.subtitle = entry.text;
}

function _addSubtitles(quickSettings) {
    for (const toggle of _grid(quickSettings).get_children()) {
        if (!('subtitle' in toggle) || !('checked' in toggle) || _subtitles.has(toggle))
            continue;
        const entry = {text: null, ids: []};
        _subtitles.set(toggle, entry);
        entry.ids = ['notify::checked', 'notify::subtitle']
            .map(signal => toggle.connect(signal, () => _followSubtitle(toggle)));
        _followSubtitle(toggle);
    }
}

function _removeSubtitles() {
    for (const [toggle, {text, ids}] of _subtitles) {
        ids.forEach(id => toggle.disconnect(id));
        if (text !== null && toggle.subtitle === text)
            toggle.subtitle = null;
    }
    _subtitles.clear();
}

function _apply(quickSettings) {
    if (!_enabled || _applied)
        return;
    _applied = true;
    _moveVpn(quickSettings);
    _light(quickSettings);
    _addSubtitles(quickSettings);
}

export function configure(featureName) {
    Hooks.provide(featureName, 'quick-settings', _apply);
}

export function enable() {
    _enabled = true;
    // panel.js sets up the indicators asynchronously: the hook covers a later setup.
    const {quickSettings} = Main.panel.statusArea;
    if (quickSettings._system)
        _apply(quickSettings);
}

export function disable() {
    _enabled = false;
    _removeSubtitles();
    _lit?.remove_style_class_name(LIT_STYLE_CLASS);
    _lit = null;
    _restoreVpn();
    _applied = false;
}
