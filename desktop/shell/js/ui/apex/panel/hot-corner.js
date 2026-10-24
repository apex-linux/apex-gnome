// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's 4 x 4 hot corner next to the stock pressure barrier: a pointer that reaches the
// corner without pushing, as in a VM, opens the overview too. Both follow enable-hot-corners.

import Clutter from 'gi://Clutter';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';

const ZONE_SIZE = 4;
const ZONE_ACTION_MODES = Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW;

let _enabled = false;

// layout.js never shows the HotCorner actor, so it becomes the zone.
function _addZone(corner, layoutManager) {
    if (!_enabled)
        return;
    const size = ZONE_SIZE * St.ThemeContext.get_for_stage(global.stage).scale_factor;
    const rtl = Clutter.get_default_text_direction() === Clutter.TextDirection.RTL;
    corner.set({
        name: 'hot-corner',
        reactive: true,
        x: rtl ? corner._x - size : corner._x,
        y: corner._y,
        width: size,
        height: size,
    });
    // Triggered through the barrier, so the pressure that follows does not toggle it back.
    const barrier = corner._pressureBarrier;
    corner.connect('enter-event', () => {
        if (!barrier._isTriggered && (Main.actionMode & ZONE_ACTION_MODES))
            barrier._trigger();
        return Clutter.EVENT_PROPAGATE;
    });
    corner.connect('leave-event', () => {
        if (barrier._barriers.every(b => !b._isHit))
            barrier._isTriggered = false;
        return Clutter.EVENT_PROPAGATE;
    });
    layoutManager.addChrome(corner, {trackFullscreen: true});
}

export function configure(featureName) {
    Hooks.provide(featureName, 'hot-corner', _addZone);
}

export function enable() {
    _enabled = true;
    Main.layoutManager._updateHotCorners();
}

export function disable() {
    _enabled = false;
    Main.layoutManager._updateHotCorners();
}
