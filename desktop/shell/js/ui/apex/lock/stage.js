// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's single stage: the clock, date above time, over the prompt and its hint. The
// prompt exists only while the screen is on, so PAM and the fingerprint reader stop at blank.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';

import * as LoginManager from '../../../misc/loginManager.js';
import * as Hooks from '../hooks.js';

import * as ErrorRing from './error.js';
import * as Fingerprint from './fingerprint.js';

Gio._promisify(Gio.DBusProxy, 'new_for_bus');

const CLOCK_ALWAYS_SHOWN = 0;
// 51.0's unlockDialog.js layout starts a stack this tall a tenth of the way down, so the stage's own
// layout alone places the clock; unlock-stack-box keeps that layout where upstream's changed it.
const STAGE_HEIGHT_FRACTION = 0.9;
const STOCK_PROMPT_HEIGHT = 550;

// mutter's own D-Bus API, which gsd-power sets to blank: MetaPowerSave is not introspected.
const DISPLAY_CONFIG = 'org.gnome.Mutter.DisplayConfig';
const DISPLAY_CONFIG_PATH = '/org/gnome/Mutter/DisplayConfig';
const POWER_SAVE_MODE = 'PowerSaveMode';
// Standby, suspend and off; -1, a display without power saving, never blanks.
const BLANK_POWER_SAVE_MODES = [1, 2, 3];

let _enabled = false;
const _screens = new WeakMap();
const _stages = new WeakMap();

function _clockProgress(stock) {
    return _enabled ? CLOCK_ALWAYS_SHOWN : stock;
}

// The dialog layout's stack box as 51.0 computes it: 51.1 centres the stack on its clock and prompt.
function _stackBox(stock, layout, box) {
    const stage = _stages.get(layout._stack);
    if (!_enabled || !stage?.natural_height)
        return stock;
    const height = box.get_height();
    const stageHeight = stage.natural_height;
    const [, , , notificationsHeight] = layout._notifications.get_preferred_size();
    const notifications = Math.min(notificationsHeight, height - height / 10 - stageHeight);
    stock.y1 = Math.min(Math.floor(height / 2 - STOCK_PROMPT_HEIGHT / 2), height - stageHeight - notifications);
    stock.y2 = stock.y1 + stageHeight;
    return stock;
}

function _screenIsBlank(displayConfig) {
    return BLANK_POWER_SAVE_MODES.includes(displayConfig.get_cached_property(POWER_SAVE_MODE)?.unpack());
}

// Locking makes the session idle, and upstream's idle cancel would end the prompt before blank could tear it down.
function _idleCancel(stock, dialog) {
    return _enabled && _screens.has(dialog) ? false : stock;
}

// _showClock() alone destroys the prompt only after its fade; blanking must not wait.
export function tearDownPrompt(dialog) {
    dialog._showClock();
    dialog._maybeDestroyAuthPrompt();
}

// The lines are for the VM tests (apex-image's qualify.sh). Only a prompt torn down here comes back.
function _owe(dialog, why) {
    if (!dialog._authPrompt)
        return;
    tearDownPrompt(dialog);
    _screens.get(dialog).tornDown = true;
    console.log(`Apex: lock: ${why}, prompt torn down`);
}

function _asleep() {
    return LoginManager.getLoginManager().preparingForSleep;
}

// Built without a key, it takes keys only once PAM asks: else the key that woke the screen answers it.
function _buildPrompt(dialog) {
    dialog._showPrompt();
    dialog._authPrompt.updateSensitivity({sensitive: false});
}

// Whether after blank or resume, the screen is on: qualify.sh waits for this one line.
function _repay(dialog) {
    const screen = _screens.get(dialog);
    if (!screen.tornDown || _asleep() || (screen.displayConfig && _screenIsBlank(screen.displayConfig)))
        return;
    screen.tornDown = false;
    if (dialog._authPrompt)
        return;
    _buildPrompt(dialog);
    console.log('Apex: lock: screen on, prompt rebuilt');
}

// Upstream cancels the conversation before sleep; taking the prompt down instead ends it as well, and owes it.
function _sleepCancel(stock, dialog) {
    if (!_enabled || !_screens.has(dialog))
        return stock;
    _owe(dialog, 'suspend');
    return false;
}

export function followScreen(dialog) {
    if (_screenIsBlank(_screens.get(dialog).displayConfig))
        _owe(dialog, 'screen blank');
    else
        _repay(dialog);
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
    _stages.set(dialog._stack, stage);
    const fill = () => {
        if (dialog.height <= 0)
            return;
        stage.natural_height = Math.floor(dialog.height * STAGE_HEIGHT_FRACTION);
        dialog._stack.natural_height = stage.natural_height;
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
        ErrorRing.followPrompt(dialog, child);
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
    _screens.get(dialog).displayConfig = displayConfig;
    displayConfig.connectObject('g-properties-changed', (_proxy, changed, invalidated) => {
        if (changed.lookup_value(POWER_SAVE_MODE, null) || invalidated.includes(POWER_SAVE_MODE))
            followScreen(dialog);
    }, dialog);
    followScreen(dialog);
}

function _setUp(dialog) {
    if (!_enabled)
        return undefined;
    dialog.add_style_class_name('apex-lock');
    _restack(dialog);
    _addOverlay(dialog);
    _addHint(dialog);
    _screens.set(dialog, {displayConfig: null, tornDown: _asleep()});
    LoginManager.getLoginManager().connectObject('prepare-for-sleep', (_manager, aboutToSuspend) => {
        if (!aboutToSuspend)
            _repay(dialog);
    }, dialog);

    // Until DisplayConfig answers, and if it never does, as on a screen that is on; a lock taken for sleep owes it.
    if (!_asleep())
        _buildPrompt(dialog);
    _followDisplayConfig(dialog).catch(logError);
    return undefined;
}

export function configure(featureName) {
    Hooks.provide(featureName, 'unlock-clock-progress', _clockProgress);
    Hooks.provide(featureName, 'unlock-dialog', _setUp);
    Hooks.provide(featureName, 'unlock-idle-cancel', _idleCancel);
    Hooks.provide(featureName, 'unlock-stack-box', _stackBox);
    Hooks.provide(featureName, 'unlock-sleep-cancel', _sleepCancel);
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
