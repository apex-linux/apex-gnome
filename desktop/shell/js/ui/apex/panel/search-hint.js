// SPDX-License-Identifier: GPL-2.0-or-later
//
// ROADMAP S1b: "Press Super+Space to search", once per user, the first time the Apex
// panel runs unlocked with banners on. A schema without search-hint-shown means no hint.

import Gio from 'gi://Gio';

import * as Main from '../../main.js';

const SCHEMA_ID = 'io.github.apex_linux.Apex.Desktop';
const SHOWN_KEY = 'search-hint-shown';
const HINT = 'Press Super+Space to search';
const BANNERS_SCHEMA_ID = 'org.gnome.desktop.notifications';
const BANNERS_KEY = 'show-banners';

let _settings = null;
let _missingKeyLogged = false;
let _banners = null;
let _bannersChangedId = 0;

export function configure() {
    const bannersSchema = Gio.SettingsSchemaSource.get_default()?.lookup(BANNERS_SCHEMA_ID, true);
    _banners = bannersSchema ? new Gio.Settings({settings_schema: bannersSchema}) : null;
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(SCHEMA_ID, true);
    if (schema?.has_key(SHOWN_KEY)) {
        _settings = new Gio.Settings({settings_schema: schema});
    } else if (!_missingKeyLogged) {
        _missingKeyLogged = true;
        console.warn(`Apex: ${SCHEMA_ID} has no key ${SHOWN_KEY}: no search hint`);
    }
}

function _post() {
    _settings.set_boolean(SHOWN_KEY, true);
    Main.notify(HINT);
}

// Do Not Disturb would keep the hint out of sight: it waits for banners, and never shows locked.
function _onBannersChanged() {
    if (!_banners.get_boolean(BANNERS_KEY) || Main.sessionMode.isLocked || _settings.get_boolean(SHOWN_KEY))
        return;
    disable();
    _post();
}

export function enable() {
    if (!_settings || _settings.get_boolean(SHOWN_KEY) || Main.sessionMode.isLocked)
        return;
    if (!_banners || _banners.get_boolean(BANNERS_KEY))
        _post();
    else
        _bannersChangedId = _banners.connect(`changed::${BANNERS_KEY}`, _onBannersChanged);
}

export function disable() {
    if (_bannersChangedId)
        _banners.disconnect(_bannersChangedId);
    _bannersChangedId = 0;
}
