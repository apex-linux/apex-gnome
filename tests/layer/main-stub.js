// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/main.js: the parts of main.js the layer and its features use.

import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

const fact = (key, value) => printerr(`probe: ${key}=${value}`);
const handlers = new Map();

function flagNames(value, flags) {
    const names = Object.entries(flags)
        .filter(([name, bit]) => name !== 'ALL' && bit !== 0 && (value & bit) === bit)
        .map(([name]) => name);
    return names.length > 0 ? names.join('|') : 'NONE';
}

export const sessionMode = {_sync: () => printerr('probe: restyled')};

export const overview = {
    visible: false,
    focusSearch() {
        this.visible = true;
        fact('overview', 'shown, search focused');
    },
    hide() {
        this.visible = false;
        fact('overview', 'hidden');
    },
};

export const wm = {
    addKeybinding(name, settings, flags, modes, handler) {
        if (handlers.has(name)) {
            fact('keybinding.refused', name);
            return Meta.KeyBindingAction.NONE;
        }
        handlers.set(name, handler);
        fact('keybinding.add', `${name} accelerators=${settings.get_strv(name).join(',')} ` +
            `flags=${flagNames(flags, Meta.KeyBindingFlags)} modes=${flagNames(modes, Shell.ActionMode)}`);
        return handlers.size;
    },
    removeKeybinding(name) {
        if (handlers.delete(name))
            fact('keybinding.remove', name);
    },
    press(name) {
        const handler = handlers.get(name);
        if (handler)
            handler(null, null, null, null);
        else
            fact('unbound-press', name);
    },
};
