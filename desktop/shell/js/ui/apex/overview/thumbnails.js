// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: workspace thumbnails 150 x 94 on a 1440 x 900 screen, shown once there are two
// workspaces, which with dynamic workspaces is as soon as one has a window.

import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';

const THUMBNAIL_SCALE = 0.104;
const THUMBNAILS_THRESHOLD = 1;

let _enabled = false;
let _stockScale = null;

// The primary monitor's box lives as long as the overview; the others' come with each opening.
function _primaryBox() {
    return Main.overview._overview._controls._thumbnailsBox;
}

function _sync(box, scale) {
    box._maxThumbnailScale = scale;
    box._updateShouldShow();
    box.queue_relayout();
}

export function configure(featureName) {
    Hooks.provide(featureName, 'thumbnail-scale', stock => _enabled ? THUMBNAIL_SCALE : stock);
    Hooks.provide(featureName, 'thumbnails-threshold', stock => _enabled ? THUMBNAILS_THRESHOLD : stock);
}

export function enable() {
    _enabled = true;
    const box = _primaryBox();
    _stockScale ??= box._maxThumbnailScale;
    _sync(box, THUMBNAIL_SCALE);
}

export function disable() {
    _enabled = false;
    _sync(_primaryBox(), _stockScale);
}
