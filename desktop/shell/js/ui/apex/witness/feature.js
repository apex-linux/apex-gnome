// SPDX-License-Identifier: GPL-2.0-or-later
//
// Test only: layer.js loads it after the fault feature, so a test sees that a feature
// after a failing one still configures and enables.

import * as Hooks from '../hooks.js';

let _enabled = false;

export function configure(featureName) {
    Hooks.provide(featureName, 'test-witness', () => _enabled ? 'enabled' : 'configured');
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
