// SPDX-License-Identifier: GPL-2.0-or-later
//
// Super+Space: the stock overview search until S3a's Spotlight replaces it.

import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import * as Main from '../../main.js';

const KEYBINDINGS_SCHEMA = 'io.github.apex_linux.Apex.Desktop.Keybindings';
const TOGGLE_SPOTLIGHT = 'toggle-spotlight';

let _keybindings = null;

function _toggle() {
    if (Main.overview.visible)
        Main.overview.hide();
    else
        Main.overview.focusSearch();
}

export function configure() {
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(KEYBINDINGS_SCHEMA, true);
    if (!schema)
        throw new Error(`schema ${KEYBINDINGS_SCHEMA} is not installed`);
    _keybindings = new Gio.Settings({settings_schema: schema});
}

export function enable() {
    const action = Main.wm.addKeybinding(TOGGLE_SPOTLIGHT, _keybindings,
        Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
        Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW,
        _toggle);
    if (action === Meta.KeyBindingAction.NONE)
        throw new Error(`mutter refused the keybinding ${TOGGLE_SPOTLIGHT}`);
}

export function disable() {
    Main.wm.removeKeybinding(TOGGLE_SPOTLIGHT);
}
