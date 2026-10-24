// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the bar is solid while Translucent Top Bar is off, or while a window on the
// primary monitor is maximised and the overview is closed.

import Gio from 'gi://Gio';
import Meta from 'gi://Meta';

import * as Main from '../../main.js';

const SCHEMA_ID = 'io.github.apex_linux.Apex.Desktop';
const TRANSLUCENT_KEY = 'translucent-top-bar';
const SOLID_STYLE_CLASS = 'apex-solid-bar';

let _settings = null;
let _connections = [];

function _maximisedOnPrimary() {
    return global.workspace_manager.get_active_workspace().list_windows().some(w =>
        w.is_on_primary_monitor() && w.showing_on_its_workspace() && w.is_maximized() &&
        w.get_window_type() !== Meta.WindowType.DESKTOP);
}

function _sync() {
    if (!_settings.get_boolean(TRANSLUCENT_KEY) || (!Main.overview.visible && _maximisedOnPrimary()))
        Main.panel.add_style_class_name(SOLID_STYLE_CLASS);
    else
        Main.panel.remove_style_class_name(SOLID_STYLE_CLASS);
}

export function configure() {
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(SCHEMA_ID, true);
    if (!schema?.has_key(TRANSLUCENT_KEY))
        throw new Error(`${SCHEMA_ID} has no key ${TRANSLUCENT_KEY}`);
    _settings = new Gio.Settings({settings_schema: schema});
}

export function enable() {
    _connections = [
        [_settings, `changed::${TRANSLUCENT_KEY}`],
        [global.display, 'restacked'],
        [global.window_manager, 'size-changed'],
        [global.window_manager, 'minimize'],
        [global.window_manager, 'unminimize'],
        [global.workspace_manager, 'active-workspace-changed'],
        [Main.overview, 'showing'],
        [Main.overview, 'hidden'],
    ].map(([emitter, signal]) => [emitter, emitter.connect(signal, _sync)]);
    _sync();
}

export function disable() {
    for (const [emitter, id] of _connections)
        emitter.disconnect(id);
    _connections = [];
    Main.panel.remove_style_class_name(SOLID_STYLE_CLASS);
}
