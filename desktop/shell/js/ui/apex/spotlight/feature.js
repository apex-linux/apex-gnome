// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's one engine behind Super+Space, the bar's search button and the overview's search.
// With the feature off, the button opens the stock overview search.

import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';
import * as Providers from './providers.js';
import {Popup} from './popup.js';

const KEYBINDINGS_SCHEMA = 'io.github.apex_linux.Apex.Desktop.Keybindings';
const TOGGLE_SPOTLIGHT = 'toggle-spotlight';

let _featureName = null;
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

// Patch 0013's hook: text typed in the overview, or its focused search pill, opens Spotlight.
function _overviewSearch(text, resetOverviewSearch) {
    if (!_popup || _popup.isOpen)
        return false;
    resetOverviewSearch();
    _popup.open(text);
    return true;
}

export function configure(featureName) {
    _featureName = featureName;
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
    Hooks.provide(_featureName, 'overview-search', _overviewSearch);
}

export function disable() {
    Hooks.withdraw(_featureName);
    _popup?.destroy();
    _popup = null;
    Main.wm.removeKeybinding(TOGGLE_SPOTLIGHT);
}
