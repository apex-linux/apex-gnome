// SPDX-License-Identifier: GPL-2.0-or-later
//
// ROADMAP S1b: "Press Super+Space to search", once per user, the first time the Apex
// panel runs unlocked. A schema without search-hint-shown means no hint.

import Gio from 'gi://Gio';

import * as Main from '../../main.js';

const SCHEMA_ID = 'io.github.apex_linux.Apex.Desktop';
const SHOWN_KEY = 'search-hint-shown';
const HINT = 'Press Super+Space to search';

let _settings = null;
let _missingKeyLogged = false;

export function configure() {
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(SCHEMA_ID, true);
    if (schema?.has_key(SHOWN_KEY)) {
        _settings = new Gio.Settings({settings_schema: schema});
    } else if (!_missingKeyLogged) {
        _missingKeyLogged = true;
        console.warn(`Apex: ${SCHEMA_ID} has no key ${SHOWN_KEY}: no search hint`);
    }
}

export function enable() {
    if (!_settings || _settings.get_boolean(SHOWN_KEY) || Main.sessionMode.isLocked)
        return;
    _settings.set_boolean(SHOWN_KEY, true);
    Main.notify(HINT);
}

export function disable() {}
