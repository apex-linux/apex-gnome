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

const sessionModeHandlers = new Map();
let nextSessionModeHandler = 1;

export const sessionMode = {
    isLocked: false,
    _sync: () => printerr('probe: restyled'),
    connect(signal, fn) {
        sessionModeHandlers.set(nextSessionModeHandler, [signal, fn]);
        return nextSessionModeHandler++;
    },
    disconnect(id) {
        sessionModeHandlers.delete(id);
    },
    lock(locked) {
        this.isLocked = locked;
        for (const [signal, fn] of [...sessionModeHandlers.values()]) {
            if (signal === 'updated')
                fn();
        }
    },
};

export const actionMode = Shell.ActionMode.NORMAL;

function box(children) {
    return {
        children,
        get_children() {
            return [...this.children];
        },
        remove_child(child) {
            this.children.splice(this.children.indexOf(child), 1);
        },
        insert_child_at_index(child, index) {
            this.children.splice(index, 0, child);
        },
    };
}

// QuickSettings' fields for its indicators, in the order panel.js adds them to the pill.
const QUICK_SETTINGS_INDICATORS = ['_remoteAccess', '_camera', '_volumeInput', '_location',
    '_brightness', '_thunderbolt', '_nightLight', '_network', '_darkMode', '_doNotDisturb',
    '_backlight', '_bluetooth', '_rfkill', '_autoRotate', '_volumeOutput', '_unsafeMode',
    '_powerProfiles', '_system'];

const rightBox = box([{name: 'a11y'}, {name: 'keyboard'}]);

// A QuickToggle's checked and subtitle notify, as GObject properties do.
class Toggle {
    constructor(name, {checked = false, subtitle = null} = {}) {
        this.name = name;
        this._checked = checked;
        this._subtitle = subtitle;
        this._handlers = new Map();
        this._nextId = 1;
        this.styleClasses = new Set();
    }

    get checked() {
        return this._checked;
    }

    set checked(value) {
        this._checked = value;
        this._notify('checked');
    }

    get subtitle() {
        return this._subtitle;
    }

    set subtitle(value) {
        this._subtitle = value;
        this._notify('subtitle');
    }

    _notify(property) {
        for (const [signal, fn] of [...this._handlers.values()]) {
            if (signal === `notify::${property}`)
                fn();
        }
    }

    connect(signal, fn) {
        this._handlers.set(this._nextId, [signal, fn]);
        return this._nextId++;
    }

    disconnect(id) {
        this._handlers.delete(id);
    }

    add_style_class_name(name) {
        this.styleClasses.add(name);
    }

    remove_style_class_name(name) {
        this.styleClasses.delete(name);
    }

    get_parent() {
        return this.grid;
    }

    get_next_sibling() {
        return this.grid.children[this.grid.children.indexOf(this) + 1] ?? null;
    }
}

// QuickSettingsMenu's grid lays its items out in child order.
function quickSettingsGrid(toggles) {
    const grid = box(toggles);
    toggles.forEach(t => (t.grid = grid));
    grid.set_child_above_sibling = (child, sibling) => {
        grid.remove_child(child);
        grid.children.splice(grid.children.indexOf(sibling) + 1, 0, child);
    };
    grid.set_child_below_sibling = (child, sibling) => {
        grid.remove_child(child);
        grid.children.splice(grid.children.indexOf(sibling), 0, child);
    };
    return grid;
}

export function newQuickSettings() {
    const quickSettings = {_indicators: box([]), container: {get_parent: () => rightBox}};
    rightBox.children.push(quickSettings.container);
    for (const field of QUICK_SETTINGS_INDICATORS) {
        quickSettings[field] = {name: field.slice(1)};
        quickSettings._indicators.children.push(quickSettings[field]);
    }
    const toggles = {
        wifi: new Toggle('Wi-Fi', {checked: true, subtitle: 'Home'}),
        vpn: new Toggle('VPN'),
        bluetooth: new Toggle('Bluetooth'),
        power: new Toggle('Power Mode', {subtitle: 'Balanced'}),
        nightLight: new Toggle('Night Light'),
        darkMode: new Toggle('Dark Style'),
        doNotDisturb: new Toggle('Do Not Disturb'),
        airplane: new Toggle('Airplane Mode'),
        autoRotate: new Toggle('Auto Rotate'),
    };
    quickSettings.menu = {_grid: quickSettingsGrid(Object.values(toggles))};
    quickSettings._network._vpnToggle = toggles.vpn;
    quickSettings._rfkill.quickSettingsItems = [toggles.airplane];
    quickSettings._powerProfiles.quickSettingsItems = [toggles.power];
    quickSettings.toggles = toggles;
    return quickSettings;
}

const workspaceDot = {
    _updateVisuals: () => fact('workspace-dot', 'restyled'),
    queue_relayout: () => {},
};

const panelStyleClasses = new Set();

function syncPanelStyleClasses(change) {
    change();
    fact('panel.classes', [...panelStyleClasses].join(',') || 'none');
}

export const panel = {
    add_style_class_name: name => syncPanelStyleClasses(() => panelStyleClasses.add(name)),
    remove_style_class_name: name => syncPanelStyleClasses(() => panelStyleClasses.delete(name)),
    addToStatusArea(role, indicator, position, boxName) {
        if (this.statusArea[role])
            throw new Error(`there is already a status indicator for role ${role}`);
        this.statusArea[role] = indicator;
        indicator.connect('destroy', () => delete this.statusArea[role]);
        fact('panel.add', `${role} at ${position} in ${boxName}`);
        return indicator;
    },
    statusArea: {
        activities: {
            get_first_child: () => ({get_children: () => [0, 1].map(() => workspaceDot)}),
        },
        quickSettings: newQuickSettings(),
    },
};

export function notify(title) {
    fact('notify', title);
}

// layout.js's chrome parameters: Params.parse throws on any other.
const CHROME_PARAMS = ['trackFullscreen', 'affectsStruts'];

export const layoutManager = {
    _updateHotCorners: () => fact('hot-corners', 'rebuilt'),
    addChrome(actor, params = {}) {
        const unknown = Object.keys(params).filter(key => !CHROME_PARAMS.includes(key));
        if (unknown.length > 0)
            throw new Error(`Unrecognized parameter "${unknown[0]}"`);
        this.lastChrome = actor;
        fact('chrome.add', `${actor.name ?? actor.text} trackFullscreen=${params.trackFullscreen ?? false}`);
    },
};

const overviewHandlers = new Map();
let nextOverviewHandler = 1;

export const overview = {
    visible: false,
    connect(signal, fn) {
        overviewHandlers.set(nextOverviewHandler, [signal, fn]);
        return nextOverviewHandler++;
    },
    disconnect(id) {
        overviewHandlers.delete(id);
    },
    emit(signal) {
        for (const [s, fn] of [...overviewHandlers.values()]) {
            if (s === signal)
                fn();
        }
    },
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
