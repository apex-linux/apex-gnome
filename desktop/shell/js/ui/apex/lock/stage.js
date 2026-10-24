// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's single stage: the clock, date above time, over the prompt and its hint. The
// prompt exists only while the screen is on, so PAM and the fingerprint reader stop at blank.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';

import * as Hooks from '../hooks.js';

Gio._promisify(Gio.DBusProxy, 'new_for_bus');

const CLOCK_ALWAYS_SHOWN = 0;

// mutter's own D-Bus API, which gsd-power sets to blank: MetaPowerSave is not introspected.
const DISPLAY_CONFIG = 'org.gnome.Mutter.DisplayConfig';
const DISPLAY_CONFIG_PATH = '/org/gnome/Mutter/DisplayConfig';
const POWER_SAVE_MODE = 'PowerSaveMode';
// Standby, suspend and off; -1, a display without power saving, never blanks.
const BLANK_POWER_SAVE_MODES = [1, 2, 3];

let _enabled = false;

function _clockProgress(stock) {
    return _enabled ? CLOCK_ALWAYS_SHOWN : stock;
}

function _screenIsBlank(displayConfig) {
    return BLANK_POWER_SAVE_MODES.includes(displayConfig.get_cached_property(POWER_SAVE_MODE)?.unpack());
}

// _showClock() alone destroys the prompt only after its fade; blanking must not wait.
export function tearDownPrompt(dialog) {
    dialog._showClock();
    dialog._maybeDestroyAuthPrompt();
}

export function followScreen(dialog, displayConfig) {
    if (_screenIsBlank(displayConfig))
        tearDownPrompt(dialog);
    else
        dialog._showPrompt();
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

// connectObject() disconnects when the dialog is destroyed.
async function _followDisplayConfig(dialog) {
    const cancellable = new Gio.Cancellable();
    dialog.connect('destroy', () => cancellable.cancel());
    let displayConfig;
    try {
        displayConfig = await Gio.DBusProxy.new_for_bus(Gio.BusType.SESSION,
            Gio.DBusProxyFlags.DO_NOT_AUTO_START, null,
            DISPLAY_CONFIG, DISPLAY_CONFIG_PATH, DISPLAY_CONFIG, cancellable);
    } catch (e) {
        if (!e.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
            console.warn(`Apex: lock: no ${DISPLAY_CONFIG}, so the prompt stays at blank: ${e.message}`);
        return;
    }
    displayConfig.connectObject('g-properties-changed', () => followScreen(dialog, displayConfig), dialog);
    followScreen(dialog, displayConfig);
}

function _setUp(dialog) {
    if (!_enabled)
        return undefined;
    dialog.add_style_class_name('apex-lock');
    _restack(dialog);
    _addOverlay(dialog);
    _addHint(dialog);

    // Until DisplayConfig answers, and if it never does, as on a screen that is on.
    dialog._showPrompt();
    _followDisplayConfig(dialog).catch(logError);
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
