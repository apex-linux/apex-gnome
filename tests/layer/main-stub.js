// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/main.js: the parts of main.js the layer and its features use.

import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

const fact = (key, value) => printerr(`probe: ${key}=${value}`);
const handlers = new Map();
const actions = new Map();
let lastAction = 0;

function flagNames(value, flags) {
    const names = Object.entries(flags)
        .filter(([name, bit]) => name !== 'ALL' && bit !== 0 && (value & bit) === bit)
        .map(([name]) => name);
    return names.length > 0 ? names.join('|') : 'NONE';
}

// The actor calls the glass feature makes, and a theme node with ADR 0014's glass.
export class StubActor {
    constructor(name, {glass = null, extents = [0, 0, 100, 32], parent = null, redirect = 0} = {}) {
        Object.assign(this, {name, glass, box: extents, parent, redirect, mapped: true, redraws: 0});
        this._effects = [];
        this._classes = new Set();
        this._handlers = new Map();
        this._nextHandler = 1;
    }

    connect(signal, fn) {
        this._handlers.set(this._nextHandler, [signal, fn]);
        return this._nextHandler++;
    }

    disconnect(id) {
        this._handlers.delete(id);
    }

    emit(signal, ...args) {
        for (const [s, fn] of [...this._handlers.values()]) {
            if (s === signal)
                fn(this, ...args);
        }
    }

    get_effect(name) {
        return this._effects.find(e => e.name === name) ?? null;
    }

    add_effect(effect) {
        this._effects.push(effect);
    }

    remove_effect(effect) {
        this._effects.splice(this._effects.indexOf(effect), 1);
    }

    peek_theme_node() {
        const {glass} = this;
        return {
            lookup_length: p => glass && p === '-apex-glass-blur' ? [true, glass.blur] : [false, 0],
            lookup_double: p => glass && p === '-apex-glass-saturation' ? [true, glass.saturation] : [false, 0],
            get_border_radius: () => glass?.radius ?? 0,
        };
    }

    get_resource_scale() {
        return 2;
    }

    get_parent() {
        return this.parent;
    }

    get_children() {
        return this.children ?? [];
    }

    get_offscreen_redirect() {
        return this.redirect;
    }

    set_offscreen_redirect(redirect) {
        this.redirect = redirect;
    }

    get_transformed_position() {
        return this.box.slice(0, 2);
    }

    get_transformed_size() {
        return this.box.slice(2);
    }

    queue_redraw() {
        this.redraws++;
    }

    has_style_class_name(name) {
        return this._classes.has(name);
    }

    add_style_class_name(name) {
        this._classes.add(name);
        this.emit('style-changed');
    }

    remove_style_class_name(name) {
        this._classes.delete(name);
        this.emit('style-changed');
    }

    destroy() {
        this.emit('destroy');
    }
}

const PANEL_GLASS = {blur: 24, saturation: 1.6, radius: 0};
const POPOVER_GLASS = {blur: 30, saturation: 1.8, radius: 26};

export const uiGroup = Object.assign(new StubActor('uiGroup', {extents: [0, 0, 1440, 900]}), {
    children: [],
    get_stage: () => null,
    add_child(actor) {
        this.children.push(actor);
        actor._parent = this;
    },
    remove_child(actor) {
        this.children = this.children.filter(a => a !== actor);
    },
});
const boxPointer = new StubActor('boxpointer', {parent: uiGroup, redirect: 2});

export const messageTray = {
    _bannerBin: Object.assign(new StubActor('banner-bin', {parent: uiGroup}), {children: []}),
    showBanner() {
        const banner = new StubActor('banner', {glass: {...POPOVER_GLASS, radius: 16}, extents: [490, 44, 460, 80], parent: this._bannerBin});
        banner._classes.add('notification-banner');
        this._bannerBin.children.push(banner);
        this._bannerBin.emit('child-added', banner);
        return banner;
    },
};

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
    const quickSettings = {
        _indicators: box([]), container: {get_parent: () => rightBox},
        menu: {box: new StubActor('quick-settings', {glass: POPOVER_GLASS, extents: [1056, 40, 376, 420], parent: boxPointer})},
    };
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
    quickSettings.menu._grid = quickSettingsGrid(Object.values(toggles));
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
    panel.emit('style-changed');
}

export const panel = Object.assign(new StubActor('panel', {glass: PANEL_GLASS, extents: [0, 0, 1440, 32], parent: uiGroup, redirect: 2}), {
    add_style_class_name: name => syncPanelStyleClasses(() => panelStyleClasses.add(name)),
    remove_style_class_name: name => syncPanelStyleClasses(() => panelStyleClasses.delete(name)),
    has_style_class_name: name => panelStyleClasses.has(name),
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
        dateMenu: {menu: {box: new StubActor('calendar', {glass: POPOVER_GLASS, extents: [354, 40, 732, 468], parent: boxPointer})}},
    },
});

export function notify(title) {
    fact('notify', title);
}

// layout.js's chrome parameters: Params.parse throws on any other.
const CHROME_PARAMS = ['trackFullscreen', 'affectsStruts'];

// The containers the shadows feature scans: the probe registers its own actors.
const emptyContainer = () => ({get_children: () => [], connect: () => 1, disconnect: () => {}});

let modals = 0;

export function pushModal(actor, params) {
    modals++;
    fact('modal.push', `${actor.name} actionMode=${params.actionMode} count=${modals}`);
    return {};
}

export function popModal() {
    modals--;
    fact('modal.pop', `count=${modals}`);
}

export const layoutManager = {
    modalDialogGroup: emptyContainer(),
    overviewGroup: emptyContainer(),
    ...emitter({}),
    primaryMonitor: {x: 0, y: 0, width: 1440, height: 900},
    chrome: [],
    _bgManagers: [new StubActor('background')],
    _updateHotCorners: () => fact('hot-corners', 'rebuilt'),
    addChrome(actor, params = {}) {
        const unknown = Object.keys(params).filter(key => !CHROME_PARAMS.includes(key));
        if (unknown.length > 0)
            throw new Error(`Unrecognized parameter "${unknown[0]}"`);
        this.chrome.push(actor);
        fact('chrome.add', `${actor.name ?? actor.text} trackFullscreen=${params.trackFullscreen ?? false}`);
    },
};

const overviewHandlers = new Map();
let nextOverviewHandler = 1;

// The parts of the overview's controls the overview feature changes, as stock leaves them.
const controls = {
    _thumbnailsBox: {
        _maxThumbnailScale: 0.05,
        _updateShouldShow: () => {},
        queue_relayout: () => {},
    },
    _appDisplay: {
        _grid: {
            _gridModes: 'stock',
            _currentMode: 0,
            layout_manager: {fixed_icon_size: -1, _pageWidth: 1272},
            setGridModes(modes) {
                this._gridModes = modes ?? 'stock';
            },
            queue_relayout: () => {},
        },
    },
    queue_relayout: () => printerr('probe: controls=relayout'),
};

function emitter(props) {
    const signalHandlers = [];
    return {
        ...props,
        connect(signal, fn) {
            signalHandlers.push([signal, fn]);
            return signalHandlers.length;
        },
        disconnect(id) {
            signalHandlers[id - 1] = null;
        },
        emit(signal) {
            for (const handler of [...signalHandlers]) {
                if (handler?.[0] === signal)
                    handler[1](this);
            }
        },
    };
}

export const overview = {
    visible: false,
    _overview: {_controls: controls},
    dash: {
        visible: true,
        height: -1,
        showAppsButton: emitter({checked: false}),
        show() {
            this.visible = true;
        },
        hide() {
            this.visible = false;
        },
    },
    showApps() {
        this.visible = true;
        fact('overview', 'shown, app grid');
        this.dash.showAppsButton.checked = true;
        this.dash.showAppsButton.emit('notify::checked');
    },
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
    show() {
        this.visible = true;
        fact('overview', 'shown');
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
        actions.set(name, ++lastAction);
        fact('keybinding.add', `${name} accelerators=${settings.get_strv(name).join(',')} ` +
            `flags=${flagNames(flags, Meta.KeyBindingFlags)} modes=${flagNames(modes, Shell.ActionMode)}`);
        return actions.get(name);
    },
    actionOf(name) {
        return actions.get(name) ?? 0;
    },
    removeKeybinding(name) {
        actions.delete(name);
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
