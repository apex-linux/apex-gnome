// SPDX-License-Identifier: GPL-2.0-or-later
//
// The Settings tiles' colours by panel id, shared with the Settings sidebar
// (settings-tiles.json mirrors gnome-control-center's copy byte for byte).

import Gio from 'gi://Gio';

// Search-only pages of System take its tile.
const SYSTEM_PAGES = new Set(['about', 'datetime', 'region', 'users', 'software-updates']);

let _colours = null;

function colours() {
    if (_colours)
        return _colours;
    try {
        const file = Gio.File.new_for_uri(import.meta.url).get_parent().get_child('settings-tiles.json');
        const [, bytes] = file.load_contents(null);
        _colours = JSON.parse(new TextDecoder().decode(bytes));
    } catch (e) {
        console.error(`Apex: no Settings tile colours, neutral tiles instead: ${e}`);
        _colours = {};
    }
    return _colours;
}

// A colour, 'accent', or '' for a neutral tile.
export function tileOf(panelId) {
    const table = colours();
    return table[panelId] ?? (SYSTEM_PAGES.has(panelId) ? table.system ?? '' : '');
}
