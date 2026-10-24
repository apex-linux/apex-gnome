// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's overview and launcher, one feature for disabled-features ('overview'): each part
// provides its own hooks and restores the stock overview when it is disabled.

import * as Launcher from './launcher.js';
import * as Thumbnails from './thumbnails.js';
import * as WindowTitles from './window-titles.js';
import * as Workspaces from './workspaces.js';

const PARTS = [WindowTitles, Workspaces, Thumbnails, Launcher];

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
