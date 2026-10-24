// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: every window in the overview shows its title; hovering brings only the close button.
// The overview builds its previews each time it opens, so a change shows from the next opening.

import * as Hooks from '../hooks.js';

let _enabled = false;

export function configure(featureName) {
    Hooks.provide(featureName, 'window-title-visible', stock => _enabled || stock);
    Hooks.provide(featureName, 'window-overlay', (actors, preview) =>
        _enabled ? actors.filter(actor => actor !== preview._title) : actors);
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
