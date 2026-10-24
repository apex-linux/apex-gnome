// SPDX-License-Identifier: GPL-2.0-or-later
//
// Translucent Top Bar off: the bar is $apex_bar_solid over a hairline (_top-bar.scss).

import Gio from 'gi://Gio';

import * as Main from '../../main.js';

const SCHEMA_ID = 'io.github.apex_linux.Apex.Desktop';
const TRANSLUCENT_KEY = 'translucent-top-bar';
const SOLID_STYLE_CLASS = 'apex-solid-bar';

let _settings = null;
let _changedId = 0;

function _sync() {
    if (_settings.get_boolean(TRANSLUCENT_KEY))
        Main.panel.remove_style_class_name(SOLID_STYLE_CLASS);
    else
        Main.panel.add_style_class_name(SOLID_STYLE_CLASS);
}

export function configure() {
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(SCHEMA_ID, true);
    if (!schema?.has_key(TRANSLUCENT_KEY))
        throw new Error(`${SCHEMA_ID} has no key ${TRANSLUCENT_KEY}`);
    _settings = new Gio.Settings({settings_schema: schema});
}

export function enable() {
    _changedId = _settings.connect(`changed::${TRANSLUCENT_KEY}`, _sync);
    _sync();
}

export function disable() {
    _settings.disconnect(_changedId);
    _changedId = 0;
    Main.panel.remove_style_class_name(SOLID_STYLE_CLASS);
}
