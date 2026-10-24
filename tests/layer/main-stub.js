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

export function newQuickSettings() {
    const quickSettings = {_indicators: box([]), container: {get_parent: () => rightBox}};
    rightBox.children.push(quickSettings.container);
    for (const field of QUICK_SETTINGS_INDICATORS) {
        quickSettings[field] = {name: field.slice(1)};
        quickSettings._indicators.children.push(quickSettings[field]);
    }
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

export const uiGroup = {
    children: [],
    add_child(actor) {
        this.children.push(actor);
        actor._parent = this;
    },
    remove_child(actor) {
        this.children = this.children.filter(a => a !== actor);
    },
};

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
    ...emitter({}),
    primaryMonitor: {x: 0, y: 0, width: 1440, height: 900},
    chrome: [],
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

function searchEntry() {
    const classes = new Set();
    return {
        hint_text: 'Type to search',
        _text: '',
        clutter_text: emitter({}),
        get_text() {
            return this._text;
        },
        set_text(text) {
            this._text = text;
            this.clutter_text.emit('text-changed');
        },
        add_style_class_name: name => classes.add(name),
        remove_style_class_name: name => classes.delete(name),
        has_style_class_name: name => classes.has(name),
    };
}

// The parts of the overview's controls the overview feature changes, as stock leaves them.
const controls = {
    _thumbnailsBox: {
        _maxThumbnailScale: 0.05,
        _updateShouldShow: () => {},
        queue_relayout: () => {},
    },
    _searchEntry: searchEntry(),
    _appDisplay: {
        _box: {
            visible: true,
            show() {
                this.visible = true;
            },
            hide() {
                this.visible = false;
            },
        },
        children: [],
        add_child(actor) {
            this.children.push(actor);
            actor._parent = this;
        },
        remove_child(actor) {
            this.children = this.children.filter(a => a !== actor);
        },
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
