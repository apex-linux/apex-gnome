// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's single stage: the clock, date above time, over the prompt and its hint. The
// prompt exists only while the screen is on, so PAM and the fingerprint reader stop at blank.

import Clutter from 'gi://Clutter';
import Meta from 'gi://Meta';
import St from 'gi://St';

import * as Hooks from '../hooks.js';

const CLOCK_ALWAYS_SHOWN = 0;

let _enabled = false;

function _clockProgress(stock) {
    return _enabled ? CLOCK_ALWAYS_SHOWN : stock;
}

function _screenIsOn(monitorManager) {
    return monitorManager.power_save_mode === Meta.PowerSaveMode.ON;
}

// _showClock() alone destroys the prompt only after its fade; blanking must not wait.
export function tearDownPrompt(dialog) {
    dialog._showClock();
    dialog._maybeDestroyAuthPrompt();
}

export function followScreen(dialog, monitorManager) {
    if (_screenIsOn(monitorManager))
        dialog._showPrompt();
    else
        tearDownPrompt(dialog);
}

function _restack(dialog) {
    const stage = new St.BoxLayout({
        style_class: 'apex-lock-stage',
        orientation: Clutter.Orientation.VERTICAL,
    });
    dialog._stack.remove_child(dialog._clock);
    dialog._stack.remove_child(dialog._promptBox);
    stage.add_child(dialog._clock);
    stage.add_child(dialog._promptBox);
    dialog._stack.add_child(stage);

    const clock = dialog._clock;
    clock.add_style_class_name('apex-lock-clock');
    clock.set_child_below_sibling(clock._date, clock._time);
    clock._hint.hide();
}

function _addOverlay(dialog) {
    const overlay = new St.Widget({style_class: 'apex-lock-overlay'});
    overlay.add_constraint(new Clutter.BindConstraint({
        source: dialog,
        coordinate: Clutter.BindCoordinate.SIZE,
    }));
    dialog.insert_child_above(overlay, dialog._backgroundGroup);
}

function _addHint(dialog) {
    const hint = new St.Label({
        style_class: 'apex-lock-hint',
        text: _('Press Enter to unlock'),
        x_align: Clutter.ActorAlign.CENTER,
    });
    const promptBox = dialog._promptBox;
    promptBox.add_child(hint);
    promptBox.connect('child-added', () => promptBox.set_child_above_sibling(hint, null));
}

function _setUp(dialog) {
    if (!_enabled)
        return undefined;
    dialog.add_style_class_name('apex-lock');
    _restack(dialog);
    _addOverlay(dialog);
    _addHint(dialog);

    const monitorManager = global.backend.get_monitor_manager();
    const id = monitorManager.connect('power-save-mode-changed',
        () => followScreen(dialog, monitorManager));
    dialog.connect('destroy', () => monitorManager.disconnect(id));
    followScreen(dialog, monitorManager);
    return undefined;
}

export function configure(featureName) {
    Hooks.provide(featureName, 'unlock-clock-progress', _clockProgress);
    Hooks.provide(featureName, 'unlock-dialog', _setUp);
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
