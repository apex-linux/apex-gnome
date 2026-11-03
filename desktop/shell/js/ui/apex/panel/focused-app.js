// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the focused app's name follows the Activities pill, or "Desktop" while nothing
// has focus; show-focused-app-name hides it, and so does the lock screen.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from '../../main.js';
import * as PanelMenu from '../../panelMenu.js';

const SCHEMA_ID = 'io.github.apex_linux.Apex.Desktop';
const SHOW_KEY = 'show-focused-app-name';
const ROLE = 'apex-focused-app';
const NO_FOCUS_NAME = 'Desktop';
const AFTER_ACTIVITIES = 1;

let _settings = null;
let _button = null;
let _label = null;
let _connections = [];

// panel.js puts its own items back at the box's end at each session-mode change.
function _placeAfterActivities() {
    const activities = Main.panel.statusArea.activities?.container;
    const box = activities?.get_parent();
    if (box?.get_children().includes(_button.container))
        box.set_child_above_sibling(_button.container, activities);
}

function _sync() {
    _placeAfterActivities();
    const name = Shell.WindowTracker.get_default().focus_app?.get_name() ?? NO_FOCUS_NAME;
    _label.text = name;
    _button.accessible_name = name;
    _button.container.visible = _settings.get_boolean(SHOW_KEY) && !Main.sessionMode.isLocked;
}

export function configure() {
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(SCHEMA_ID, true);
    if (!schema?.has_key(SHOW_KEY))
        throw new Error(`${SCHEMA_ID} has no key ${SHOW_KEY}`);
    _settings = new Gio.Settings({settings_schema: schema});
}

export function enable() {
    _button = new PanelMenu.Button(0.0, NO_FOCUS_NAME, true);
    _button.setSensitive(false);
    _button.add_style_class_name('apex-focused-app');
    _label = new St.Label({style_class: 'apex-focused-app-label', y_align: Clutter.ActorAlign.CENTER});
    _button.add_child(_label);
    Main.panel.addToStatusArea(ROLE, _button, AFTER_ACTIVITIES, 'left');
    _connections = [
        [Shell.WindowTracker.get_default(), 'notify::focus-app'],
        [_settings, `changed::${SHOW_KEY}`],
        [Main.sessionMode, 'updated'],
    ].map(([emitter, signal]) => [emitter, emitter.connect(signal, _sync)]);
    _sync();
}

export function disable() {
    for (const [emitter, id] of _connections)
        emitter.disconnect(id);
    _connections = [];
    _button?.destroy();
    _button = null;
    _label = null;
}
