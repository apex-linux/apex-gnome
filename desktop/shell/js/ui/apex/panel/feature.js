// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's top bar, one feature for disabled-features ('panel'): each part provides its
// own hooks and restores the stock bar when it is disabled.

import * as FocusedApp from './focused-app.js';
import * as HotCorner from './hot-corner.js';
import * as SearchButton from './search-button.js';
import * as SearchHint from './search-hint.js';
import * as SolidBar from './solid-bar.js';
import * as StatusPill from './status-pill.js';
import * as WorkspaceDots from './workspace-dots.js';

const PARTS = [WorkspaceDots, HotCorner, StatusPill, SolidBar, FocusedApp,
    SearchButton, SearchHint];

export function configure(featureName) {
    for (const part of PARTS)
        part.configure(featureName);
}

export function enable() {
    for (const part of PARTS)
        part.enable();
}

export function disable() {
    for (const part of [...PARTS].reverse())
        part.disable();
}
