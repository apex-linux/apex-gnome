// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's single stage: the clock, date above time, over the prompt and its hint. The
// prompt exists only while the screen is on, so PAM and the fingerprint reader stop at blank.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';

import * as Hooks from '../hooks.js';

import * as Fingerprint from './fingerprint.js';

Gio._promisify(Gio.DBusProxy, 'new_for_bus');

const CLOCK_ALWAYS_SHOWN = 0;
// unlockDialog.js's layout starts the stack a tenth of the way down and ends it at the bottom
// when it asks for the rest, so the stage's own layout alone places the clock.
const STAGE_HEIGHT_FRACTION = 0.9;

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

// Built without a key, it takes keys only once PAM asks: else the key that woke the screen answers it.
function _buildPrompt(dialog) {
    dialog._showPrompt();
    dialog._authPrompt.updateSensitivity({sensitive: false});
}

// The lines are for the VM tests (apex-image's qualify.sh). Only a prompt torn down here comes back.
export function followScreen(dialog, screen) {
    if (_screenIsBlank(screen.displayConfig)) {
        if (!dialog._authPrompt)
            return;
        tearDownPrompt(dialog);
        screen.tornDown = true;
        console.log('Apex: lock: screen blank, prompt torn down');
    } else if (screen.tornDown) {
        screen.tornDown = false;
        if (dialog._authPrompt)
            return;
        _buildPrompt(dialog);
        console.log('Apex: lock: screen on, prompt rebuilt');
    }
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
    dialog._promptBox.y_align = Clutter.ActorAlign.START;
    dialog._stack.add_child(stage);
    const fill = () => {
        if (dialog.height > 0)
            stage.natural_height = Math.floor(dialog.height * STAGE_HEIGHT_FRACTION);
    };
    dialog.connect('notify::height', fill);
    fill();

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

const FINGERPRINT_GLYPH = 'auth-fingerprint-symbolic';

function _addHint(dialog) {
    const hint = {
        line: new St.BoxLayout({style_class: 'apex-lock-hint-line', x_align: Clutter.ActorAlign.CENTER}),
        glyph: new St.Icon({style_class: 'apex-lock-hint-glyph', icon_name: FINGERPRINT_GLYPH, visible: false}),
        label: new St.Label({style_class: 'apex-lock-hint', text: Fingerprint.hintText(Fingerprint.State.PASSWORD)}),
    };
    hint.line.add_child(hint.glyph);
    hint.line.add_child(hint.label);
    const promptBox = dialog._promptBox;
    promptBox.add_child(hint.line);
    promptBox.connect('child-added', (_box, child) => {
        promptBox.set_child_above_sibling(hint.line, null);
        if (child !== dialog._authPrompt)
            return;
        // A fault here keeps the password's hint; the lock itself is not the fingerprint's.
        try {
            Fingerprint.followPrompt(dialog, child, hint);
        } catch (e) {
            console.error(`Apex: lock: no fingerprint states for this prompt: ${e}`);
        }
    });
}

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
    const screen = {displayConfig, tornDown: false};
    displayConfig.connectObject('g-properties-changed', (_proxy, changed, invalidated) => {
        if (changed.lookup_value(POWER_SAVE_MODE, null) || invalidated.includes(POWER_SAVE_MODE))
            followScreen(dialog, screen);
    }, dialog);
    followScreen(dialog, screen);
}

function _setUp(dialog) {
    if (!_enabled)
        return undefined;
    dialog.add_style_class_name('apex-lock');
    _restack(dialog);
    _addOverlay(dialog);
    _addHint(dialog);

    // Until DisplayConfig answers, and if it never does, as on a screen that is on.
    _buildPrompt(dialog);
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
