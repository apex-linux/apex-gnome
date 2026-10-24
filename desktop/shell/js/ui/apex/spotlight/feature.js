// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's Spotlight behind Super+Space and the bar's search button. With the feature off,
// the button opens the stock overview search.

import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import * as Main from '../../main.js';
import * as Providers from './providers.js';
import {Popup} from './popup.js';

const KEYBINDINGS_SCHEMA = 'io.github.apex_linux.Apex.Desktop.Keybindings';
const TOGGLE_SPOTLIGHT = 'toggle-spotlight';

let _keybindings = null;
let _popup = null;

export function toggleSpotlight() {
    if (_popup)
        _popup.toggle();
    else if (Main.overview.visible)
        Main.overview.hide();
    else
        Main.overview.focusSearch();
}

export function popup() {
    return _popup;
}

export function configure() {
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(KEYBINDINGS_SCHEMA, true);
    if (!schema)
        throw new Error(`schema ${KEYBINDINGS_SCHEMA} is not installed`);
    if (!schema.has_key(TOGGLE_SPOTLIGHT))
        throw new Error(`schema ${KEYBINDINGS_SCHEMA} has no key ${TOGGLE_SPOTLIGHT}`);
    _keybindings = new Gio.Settings({settings_schema: schema});
}

export function enable() {
    const action = Main.wm.addKeybinding(TOGGLE_SPOTLIGHT, _keybindings,
        Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
        Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW,
        toggleSpotlight);
    if (action === Meta.KeyBindingAction.NONE)
        throw new Error(`mutter refused the keybinding ${TOGGLE_SPOTLIGHT}`);
    _popup = new Popup(Providers.load, action);
}

export function disable() {
    _popup?.destroy();
    _popup = null;
    Main.wm.removeKeybinding(TOGGLE_SPOTLIGHT);
}
