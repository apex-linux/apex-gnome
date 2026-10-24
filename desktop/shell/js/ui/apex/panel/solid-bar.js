// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the bar is solid while Translucent Top Bar is off, or while a window on the
// primary monitor is maximised and the overview is closed.

import Gio from 'gi://Gio';

import * as Main from '../../main.js';
import {connectWindowChanges, disconnectAll, maximisedOnPrimary} from '../windows.js';

const SCHEMA_ID = 'io.github.apex_linux.Apex.Desktop';
const TRANSLUCENT_KEY = 'translucent-top-bar';
const SOLID_STYLE_CLASS = 'apex-solid-bar';

let _settings = null;
let _connections = [];

function _sync() {
    if (!_settings.get_boolean(TRANSLUCENT_KEY) || (!Main.overview.visible && maximisedOnPrimary()))
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
        [_settings, _settings.connect(`changed::${TRANSLUCENT_KEY}`, _sync)],
        ...connectWindowChanges(_sync),
    ];
    _sync();
}

export function disable() {
    disconnectAll(_connections);
    _connections = [];
    Main.panel.remove_style_class_name(SOLID_STYLE_CLASS);
}
