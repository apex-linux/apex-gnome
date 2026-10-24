// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 13's authentication dialog, one feature for disabled-features ('polkit'). Every part
// changes what the dialog shows; its session, the answers and the verdict stay upstream's.

import * as Hooks from '../hooks.js';

import * as Details from './details.js';
import * as Fingerprint from './fingerprint.js';
import * as Header from './header.js';

const PARTS = [Header, Fingerprint, Details];

let _enabled = false;

function _setUp(dialog) {
    if (!_enabled)
        return undefined;
    dialog.add_style_class_name('apex-polkit');
    for (const part of PARTS)
        part.setUp(dialog);
    return undefined;
}

export function configure(featureName) {
    Hooks.provide(featureName, 'polkit-dialog', _setUp);
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
