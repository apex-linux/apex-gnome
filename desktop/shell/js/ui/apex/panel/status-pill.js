// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the status pill shows network, volume and battery only. The privacy, recording,
// unsafe-mode, input-source and accessibility indicators still show (decision 26).

import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';

const HIDDEN_INDICATORS = ['_brightness', '_thunderbolt', '_nightLight', '_darkMode',
    '_doNotDisturb', '_backlight', '_bluetooth', '_rfkill', '_autoRotate', '_powerProfiles'];

let _enabled = false;
const _removedByBox = new Map();

function _filter(quickSettings) {
    const box = quickSettings._indicators;
    if (!_enabled || _removedByBox.has(box))
        return;
    const children = box.get_children();
    const removed = HIDDEN_INDICATORS
        .map(field => quickSettings[field])
        .filter(indicator => indicator && children.includes(indicator))
        .map(indicator => ({indicator, index: children.indexOf(indicator)}))
        .sort((a, b) => a.index - b.index);
    for (const {indicator} of removed)
        box.remove_child(indicator);
    _removedByBox.set(box, removed);
}

function _restore() {
    for (const [box, removed] of _removedByBox) {
        for (const {indicator, index} of removed)
            box.insert_child_at_index(indicator, index);
    }
    _removedByBox.clear();
}

export function configure(featureName) {
    Hooks.provide(featureName, 'status-indicators', _filter);
}

export function enable() {
    _enabled = true;
    // panel.js sets up the indicators asynchronously: the hook covers a later setup.
    const {quickSettings} = Main.panel.statusArea;
    if (quickSettings._system)
        _filter(quickSettings);
}

export function disable() {
    _enabled = false;
    _restore();
}
