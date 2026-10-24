// SPDX-License-Identifier: GPL-2.0-or-later
//
// Hide Behind Maximized Windows (dock-intellihide): the dock slides below the screen while a
// window on the primary monitor is maximised, until the bottom edge under it reveals it.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import * as Layout from '../../layout.js';
import * as Main from '../../main.js';
import {connectWindowChanges, disconnectAll, maximisedOnPrimary} from '../windows.js';

const SLIDE_MS = 380;
const REVEAL_THRESHOLD_PX = 0;
const REVEAL_TIMEOUT_MS = 1000;
const REHIDE_DELAY_MS = 300;

export class Intellihide {
    // The box reaches the screen's bottom edge, so a revealed dock keeps the pointer there.
    constructor(box, settings, key) {
        this._box = box;
        this._settings = settings;
        this._key = key;
        this._revealed = false;
        this._rehideId = 0;
        this._barrier = null;
        this._pressure = new Layout.PressureBarrier(REVEAL_THRESHOLD_PX, REVEAL_TIMEOUT_MS,
            Shell.ActionMode.NORMAL);
        this._pressure.connect('trigger', () => this._reveal());

        box.set({reactive: true, track_hover: true});
        this._connections = [
            [settings, settings.connect(`changed::${key}`, () => this._sync())],
            [box, box.connect('notify::hover', () => this._hoverChanged())],
            [box, box.connect('notify::x', () => this._placeBarrier())],
            [box, box.connect('notify::width', () => this._placeBarrier())],
            ...connectWindowChanges(() => this._sync()),
        ];
        this._placeBarrier();
        this._sync();
    }

    get hidden() {
        return this._box.translation_y > 0;
    }

    _placeBarrier() {
        if (this._barrier) {
            this._pressure.removeBarrier(this._barrier);
            this._barrier.destroy();
            this._barrier = null;
        }
        const monitor = Main.layoutManager.primaryMonitor;
        if (!monitor || this._box.width <= 0)
            return;
        const bottom = monitor.y + monitor.height;
        this._barrier = new Meta.Barrier({
            backend: global.backend,
            x1: this._box.x, x2: this._box.x + this._box.width, y1: bottom, y2: bottom,
            directions: Meta.BarrierDirection.NEGATIVE_Y,
        });
        this._pressure.addBarrier(this._barrier);
    }

    _shouldHide() {
        return this._settings.get_boolean(this._key) && !this._revealed &&
            !Main.overview.visible && maximisedOnPrimary();
    }

    // Twice its height, so that the background's shadow leaves the screen too.
    _sync() {
        this._box.ease({
            translation_y: this._shouldHide() ? 2 * this._box.height : 0,
            duration: SLIDE_MS,
            mode: Clutter.AnimationMode.EASE_OUT_CUBIC,
        });
    }

    _reveal() {
        if (!this.hidden)
            return;
        this._revealed = true;
        this._sync();
        this._hoverChanged();
    }

    // Clutter updates hover only on motion, and a dock revealed under a still pointer has
    // none yet: the pointer's position decides. An open menu of the dock's holds it too.
    _pointerOnDock() {
        const [x, y] = global.get_pointer();
        const [boxX, boxY] = this._box.get_transformed_position();
        const [width, height] = this._box.get_transformed_size();
        return x >= boxX && x < boxX + width && y >= boxY && y < boxY + height;
    }

    _hoverChanged() {
        if (this._box.hover || !this._revealed || this._rehideId)
            return;
        this._rehideId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, REHIDE_DELAY_MS, () => {
            if (this._pointerOnDock() || Main.actionMode === Shell.ActionMode.POPUP)
                return GLib.SOURCE_CONTINUE;
            this._rehideId = 0;
            this._revealed = false;
            this._sync();
            return GLib.SOURCE_REMOVE;
        });
    }

    destroy() {
        disconnectAll(this._connections);
        if (this._rehideId)
            GLib.source_remove(this._rehideId);
        if (this._barrier) {
            this._pressure.removeBarrier(this._barrier);
            this._barrier.destroy();
        }
        this._pressure.destroy();
        this._box.remove_all_transitions();
        this._box.translation_y = 0;
    }
}
