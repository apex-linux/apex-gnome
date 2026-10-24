// SPDX-License-Identifier: GPL-3.0-or-later
//
// Facts go to stderr: it is unbuffered, so the facts before an abort survive.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import * as Sni from './sni.js';

const shellDir = GLib.getenv('APEX_SHELL_DIR');
const fact = (key, value) => printerr(`probe: ${key}=${value}`);

const handlers = new Map();
let nextId = 1;
function newEmitter(props = {}) {
    const signalHandlers = new Map();
    let nextSignalId = 1;
    return {
        ...props,
        connect(signal, fn) {
            signalHandlers.set(nextSignalId, [signal, fn]);
            return nextSignalId++;
        },
        disconnect(id) {
            signalHandlers.delete(id);
        },
        emit(signal, ...args) {
            for (const [s, fn] of [...signalHandlers.values()]) {
                if (s === signal)
                    fn(this, ...args);
            }
        },
        connectObject(...args) {
            for (let i = 0; i + 1 < args.length; i += 2)
                this.connect(args[i], args[i + 1]);
        },
    };
}

globalThis._ = text => text;
globalThis.C_ = (_context, text) => text;

// mutter's DisplayConfig as the lock reads it, one cached PowerSaveMode; it answers, never
// answers ('silent') or fails ('error'), as displayConfig.reply says.
const displayConfig = newEmitter({powerSaveMode: 0, reply: 'answer'});
displayConfig.get_cached_property = name =>
    name === 'PowerSaveMode' ? new GLib.Variant('i', displayConfig.powerSaveMode) : null;
displayConfig.connectObject = (signal, fn, owner) => {
    const id = displayConfig.connect(signal, fn);
    owner.connect('destroy', () => displayConfig.disconnect(id));
};
Gio.DBusProxy.new_for_bus = (_bus, _flags, _info, name, _path, _iface, cancellable) => new Promise((resolve, reject) => {
    if (displayConfig.reply === 'silent')
        return;
    if (cancellable.is_cancelled())
        reject(new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED, 'cancelled'));
    else if (displayConfig.reply === 'error' || name !== 'org.gnome.Mutter.DisplayConfig')
        reject(new GLib.Error(Gio.DBusError, Gio.DBusError.SERVICE_UNKNOWN, `no ${name}`));
    else
        resolve(displayConfig);
});
const windows = [];
const windowActors = [];
const TOGGLE_KEYCODE = 65;
let mainModule = null;
globalThis.global = {
    display: newEmitter({
        get_keybinding_action: keycode =>
            keycode === TOGGLE_KEYCODE ? mainModule?.wm.actionOf('toggle-spotlight') ?? 0 : 0,
    }),
    window_group: newEmitter(),
    get_window_actors: () => [...windowActors],
    stage: {width: 1440},
    compositor: {get_laters: () => ({add: (_type, fn) => GLib.idle_add(GLib.PRIORITY_DEFAULT, fn), remove: id => GLib.source_remove(id)})},
    pointer: [0, 0],
    get_pointer() {
        return [...this.pointer, 0];
    },
    window_manager: newEmitter(),
    workspace_manager: newEmitter({get_active_workspace: () => ({list_windows: () => windows})}),
    session_mode: GLib.getenv('PROBE_MODE') ?? 'user',
    connect(signal, fn) {
        handlers.set(nextId, [signal, fn]);
        return nextId++;
    },
    disconnect(id) {
        handlers.delete(id);
    },
};

const schema = Gio.SettingsSchemaSource.get_default()?.lookup(
    'io.github.apex_linux.Apex.Desktop', true);
const settings = schema ? new Gio.Settings({settings_schema: schema}) : null;
if (settings) {
    if (GLib.getenv('PROBE_LAYER_OFF') === '1')
        settings.set_boolean('layer-enabled', false);
    if (GLib.getenv('PROBE_HINT_SHOWN') === '1')
        settings.set_boolean('search-hint-shown', true);
    const disabled = GLib.getenv('PROBE_DISABLED');
    if (disabled) {
        settings.set_strv('disabled-features', disabled.split(','));
        fact('disabled-features', settings.get_strv('disabled-features').join(','));
    }
}

// Another process's watcher, there before the shell starts.
const remoteWatcher = GLib.getenv('PROBE_REMOTE_WATCHER') === '1' ? new Sni.FakeWatcher([]) : null;
if (remoteWatcher)
    fact('fake-watcher.owned', await remoteWatcher.owned);

const Hooks = await import(`file://${shellDir}/js/ui/apex/hooks.js`);
fact('safe', Hooks.safe());
const layerUrl = GLib.getenv('PROBE_BROKEN') === '1'
    ? `file://${shellDir}/js/ui/apex/no-such-layer.js`
    : `file://${shellDir}/js/ui/apex/layer.js`;
const layer = await Hooks.loadLayer(() => import(layerUrl));
fact('layer', layer ? 'loaded' : 'null');

const stock = {colorScheme: 'prefer-dark', hasOverview: true};

// Awaited at the top level, so gjs runs the main loop and the layer's promise jobs between.
function spin(ms) {
    return new Promise(resolve => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
        resolve();
        return GLib.SOURCE_REMOVE;
    }));
}

async function setDisabledLive() {
    const disabled = GLib.getenv('PROBE_DISABLE_LIVE');
    if (disabled === null)
        return;
    for (const list of [disabled.split(','), []]) {
        settings.set_strv('disabled-features', list);
        // eslint-disable-next-line no-await-in-loop
        await spin(200);
        fact(`disabled-live.${list.join(',') || 'none'}`, `witness=${Hooks.value('test-witness', 'stock')} ` +
            `scheme=${Hooks.value('session-mode', {...stock}, 'user').colorScheme}`);
    }
    settings.set_boolean('layer-enabled', false);
    settings.set_strv('disabled-features', disabled.split(','));
    await spin(200);
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    fact('disabled-while-off', `witness=${Hooks.value('test-witness', 'stock')}`);
    settings.set_strv('disabled-features', []);
    await spin(200);
}

async function spotlightPopup() {
    return (await import(`file://${shellDir}/js/ui/apex/spotlight/feature.js`)).popup();
}

function overviewSearchWithoutSpotlight() {
    if (GLib.getenv('PROBE_OVERVIEW_SEARCH') === '1')
        fact('overview-search', Hooks.run('overview-search', 'text', 'disk', () => fact('overview-search.reset', 'yes')) ?? 'stock');
}

async function pressToggleSpotlight() {
    const presses = Number(GLib.getenv('PROBE_PRESS') ?? '0');
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    for (let press = 1; press <= presses; press++) {
        Main.wm.press('toggle-spotlight');
        // eslint-disable-next-line no-await-in-loop
        fact(`press.${press}`, `overview=${Main.overview.visible} spotlight=${(await spotlightPopup())?.isOpen ?? false}`);
    }
}

// What the popup shows: each section's rows, the selected one starred with its verb.
function shown(popup) {
    if (!popup?.isOpen)
        return 'closed';
    const [, results, empty] = popup.panel.get_children();
    if (empty.visible)
        return `empty "${empty.get_children()[0].text}"`;
    if (!results.visible)
        return 'field only';
    const parts = [];
    for (const child of results.get_children()) {
        if (child.has_style_class_name('apex-spotlight-header')) {
            parts.push(`${child.get_children()[0].text}:`);
            continue;
        }
        const [, text, action] = child.get_children();
        const [title, subtitle] = text.get_children();
        const result = title.has_style_class_name('apex-spotlight-result') ? `(${subtitle.text})` : '';
        const selected = child.has_style_pseudo_class('selected') ? `*${action.get_children()[0].text}` : '';
        parts[parts.length - 1] += ` ${title.text}${result}${selected}`;
    }
    return parts.join(' | ');
}

// Each Settings row's tile: its colour, the accent, or neutral.
function tiles(popup) {
    const [, results] = popup.panel.get_children();
    return results.get_children()
        .filter(row => row.get_children?.()[0]?.has_style_class_name('apex-spotlight-tile'))
        .map(row => {
            const [tile, text] = row.get_children();
            const colour = tile.has_style_class_name('apex-spotlight-tile-accent') ? 'accent'
                : tile.style?.match(/#[0-9a-f]{6}/)?.[0] ?? 'neutral';
            return `${text.get_children()[0].text}=${colour}`;
        }).join(' ');
}

const SEARCH_SETTLE_MS = 300;

async function exerciseSpotlight() {
    const mode = GLib.getenv('PROBE_SPOTLIGHT');
    if (mode === null)
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const Toast = await import(`file://${shellDir}/js/ui/apex/spotlight/toast.js`);
    const popup = await spotlightPopup();
    const entry = () => popup.panel.get_children()[0].get_children()[1];
    const key = (symbol, keycode) => entry().actions[0].press(symbol, keycode);
    const report = label => fact(`spotlight.${label}`, shown(popup));
    const type = async (label, text) => {
        entry().set_text(text);
        await spin(SEARCH_SETTLE_MS);
        report(label);
    };
    const open = () => {
        Main.overview.visible = false;
        Main.wm.press('toggle-spotlight');
    };
    const {default: Clutter} = await import(`file://${GLib.path_get_dirname(shellDir)}/Clutter.js`);

    if (mode === 'slow') {
        open();
        entry().set_text('disk');
        await spin(700);
        report('slow.at-700ms');
        await spin(600);
        report('slow.at-1300ms');
        return;
    }
    if (mode === 'late') {
        open();
        entry().set_text('disk');
        await spin(300);
        report('late.at-300ms');
        for (let i = 0; i < 5; i++)
            key(Clutter.KEY_Down);
        report('late.down-5');
        await spin(600);
        report('late.at-900ms');
        return;
    }
    // A popup whose toggle action is NONE, the action every unbound key maps to.
    if (mode === 'no-action') {
        const {Popup} = await import(`file://${shellDir}/js/ui/apex/spotlight/popup.js`);
        const {default: Meta} = await import('gi://Meta');
        const bare = new Popup(popup._loadProviders, Meta.KeyBindingAction.NONE);
        bare.open();
        const bareEntry = bare.panel.get_children()[0].get_children()[1];
        bareEntry.set_text('disk');
        await spin(SEARCH_SETTLE_MS);
        bareEntry.actions[0].press(Clutter.KEY_Down);
        fact('spotlight.no-action.down', shown(bare));
        bareEntry.actions[0].press(Clutter.KEY_Escape);
        fact('spotlight.no-action.escape', shown(bare));
        bare.destroy();
        return;
    }
    if (mode === 'late-sum') {
        open();
        entry().set_text('2880 / 1.5');
        await spin(300);
        report('late-sum.at-300ms');
        await spin(600);
        report('late-sum.at-900ms');
        return;
    }

    const Glass = await import(`file://${shellDir}/js/ui/apex/glass/registry.js`);
    const spotlightGlass = () => Glass.surfaces().map(surface => surface.name)
        .filter(name => ['spotlight', 'toast'].includes(name)).join(',') || 'none';
    open();
    report('opened');
    fact('spotlight.glass-open', spotlightGlass());
    fact('spotlight.focus', entry().focused === true);
    await type('disk', 'disk');
    fact('spotlight.tiles', tiles(popup));
    for (let i = 0; i < 4; i++)
        key(Clutter.KEY_Down);
    report('down-4');
    key(Clutter.KEY_Up);
    report('up-1');
    for (let i = 0; i < 20; i++)
        key(Clutter.KEY_Down);
    report('down-20');
    for (let i = 0; i < 20; i++)
        key(Clutter.KEY_Up);
    report('up-20');
    for (let i = 0; i < 4; i++)
        key(Clutter.KEY_Down);
    key(Clutter.KEY_Return);
    report('enter-on-a-setting');

    open();
    await type('app', 'disk');
    key(Clutter.KEY_KP_Enter);
    report('enter-on-an-app');

    open();
    await type('sum', '2880 / 1.5');
    key(Clutter.KEY_Return);
    report('enter-on-the-sum');
    const toast = Toast.current();
    fact('spotlight.toast', toast ? `${toast.get_children()[0].accessible_name} in-ui-group=${Main.uiGroup.children.includes(toast)}` : 'none');
    fact('spotlight.glass-copied', spotlightGlass());
    await spin(2300);
    fact('spotlight.toast-later', Toast.current() ? 'shown' : 'gone');
    fact('spotlight.glass-later', spotlightGlass());

    open();
    await type('apex', 'apex');
    fact('spotlight.tiles-apex', tiles(popup));
    key(Clutter.KEY_Escape);

    open();
    await type('none', 'zzz');
    key(Clutter.KEY_Escape);
    report('escape');

    open();
    await type('cleared-before', 'disk');
    await type('cleared', '');
    entry().set_text('disk');
    await type('superseded', 'zzz');
    key(0, TOGGLE_KEYCODE);
    report('toggle-key');

    open();
    global.display.emit('overlay-key');
    fact('spotlight.overlay-key', `${shown(popup)} overview=${Main.overview.visible}`);

    open();
    Main.uiGroup.children.find(a => a.name === 'apexSpotlight').get_children()[0].actions[0].recognize();
    report('click-outside');

    open();
    await type('hover-before', 'disk');
    const row = popup.panel.get_children()[1].get_children()[2];
    row.hover = true;
    row.emit('notify::hover');
    report('hover');
    row.actions[0].recognize();
    report('click-row');
    fact('spotlight.stage', Main.uiGroup.children.filter(a => a.name === 'apexSpotlight').length);

    Main.overview.visible = true;
    const handled = Hooks.run('overview-search', 'text', 'disk', () => fact('spotlight.overview-reset', 'yes'));
    await spin(SEARCH_SETTLE_MS);
    fact('spotlight.from-overview', `${handled} ${shown(popup)}`);
    fact('spotlight.from-overview-again', Hooks.run('overview-search', 'text', 'd', () => fact('spotlight.overview-reset', 'again')));
    key(Clutter.KEY_Return);
    fact('spotlight.from-overview-enter', `${shown(popup)} overview=${Main.overview.visible}`);
    Main.overview.visible = true;
    fact('spotlight.from-overview-focus', `${Hooks.run('overview-search', 'focus', '', () => {})} ${shown(popup)}`);
    key(Clutter.KEY_Escape);

    open();
    await type('live-before', 'disk');
    settings.set_strv('disabled-features', ['spotlight']);
    await spin(200);
    const gone = await spotlightPopup() === null;
    fact('spotlight.live-disabled', `${Main.uiGroup.children.filter(a => a.name === 'apexSpotlight').length} popup=${gone}`);
    settings.set_strv('disabled-features', []);
    await spin(200);
    Main.wm.press('toggle-spotlight');
    fact('spotlight.live-enabled', shown(await spotlightPopup()));
    Main.wm.press('toggle-spotlight');
}

// The launcher's pill and what the app display shows: the grid, or its results.
function launcherState(Main) {
    const controls = Main.overview._overview._controls;
    const {_searchEntry: entry, _appDisplay: appDisplay} = controls;
    const results = appDisplay.children.find(a => a.name === 'apexLauncherResults' && !a.destroyed);
    let display = 'grid';
    if (!appDisplay._box.visible) {
        const [grid, empty] = results.get_children();
        display = empty.visible
            ? empty.get_children().map(label => label.text).join(' / ')
            : grid.items.map(icon => `${icon.app.get_name()}${icon.pseudoClasses.has('selected') ? '*' : ''}`).join(', ');
    }
    return `hint=${entry.hint_text} pill=${entry.has_style_class_name('apex-launcher-search')} ${display}`;
}

async function exerciseLauncher() {
    if (GLib.getenv('PROBE_LAUNCHER') !== '1')
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const entry = Main.overview._overview._controls._searchEntry;
    const button = Main.overview.dash.showAppsButton;
    const report = label => fact(`launcher.${label}`, launcherState(Main));
    report('desktop');
    Main.overview.showApps();
    report('app-grid');
    fact('launcher.hook-text', Hooks.run('overview-search', 'text', 'dis', () => fact('launcher.reset', 'yes')));
    fact('launcher.hook-focus', Hooks.run('overview-search', 'focus', 'dis', () => fact('launcher.reset', 'yes')));
    entry.set_text('dis');
    report('dis');
    fact('launcher.spotlight', (await spotlightPopup())?.isOpen ?? false);
    entry.clutter_text.emit('activate');
    entry.set_text('zzz');
    report('zzz');
    entry.set_text('');
    report('cleared');
    entry.set_text('char');
    report('folder-app');
    button.checked = false;
    button.emit('notify::checked');
    report('left');
    fact('launcher.left-text', JSON.stringify(entry.get_text()));
    Main.overview.showApps();
    settings.set_strv('disabled-features', ['spotlight']);
    await spin(200);
    report('disabled');
    settings.set_strv('disabled-features', []);
    await spin(200);
    report('enabled-again');
}

function pillNames(quickSettings) {
    return quickSettings._indicators.get_children().map(i => i.name === 'apexPrivacyGroup'
        ? `privacy(${i.get_children().map(c => c.name).join(' ')})` : i.name).join(',');
}

function privacyState(quickSettings) {
    const box = quickSettings._indicators;
    const group = box.get_children().find(i => i.name === 'apexPrivacyGroup');
    return `group=${group ? group.visible : 'none'} in-use=${box.has_style_class_name('apex-privacy-in-use')}`;
}

function showIndicator(indicator, visible) {
    indicator.visible = visible;
    indicator.emit('notify::visible');
}

function screenParts(button) {
    const children = button.get_first_child().get_children();
    const part = c => c.has_style_class_name('apex-screen-stop') ? 'square' : c.text ?? c.icon_name;
    const hidden = children.filter(c => !c.visible).map(part).join(',') || 'none';
    return `${children.filter(c => c.visible).map(part).join(',')} hidden=${hidden} name=${button.accessible_name}`;
}

function inputChipTexts({_container: container}) {
    return container.get_children().map(label => label.text).join(',');
}

function newHotCorner() {
    const signalHandlers = {};
    let triggers = 0;
    const barrier = {
        _isTriggered: false,
        _barriers: [{_isHit: false}],
        _trigger() {
            this._isTriggered = true;
            fact('hot-corner.trigger', ++triggers);
        },
    };
    return {
        _x: 0, _y: 0, _pressureBarrier: barrier, handlers: signalHandlers,
        set(props) {
            Object.assign(this, props);
        },
        connect(signal, fn) {
            signalHandlers[signal] = fn;
        },
    };
}

// The ease hook's mode for each kind of target, the eased hook's curve, and the durations by role.
async function exerciseMotion() {
    const Clutter = (await import(`file://${shellDir}/../Clutter.js`)).default;
    const M = Clutter.AnimationMode;
    const modeName = mode => Object.keys(M).find(k => M[k] === mode) ?? 'none';
    const actor = new Clutter.Actor();
    const adjustment = {get_actor: () => actor};
    const cases = [
        ['quad', actor, {mode: M.EASE_OUT_QUAD, duration: 250}],
        ['expo', actor, {mode: M.EASE_OUT_EXPO, duration: 400}],
        ['actor-default', actor, {duration: 100}],
        ['linear', actor, {mode: M.LINEAR, duration: 100}],
        ['steps', actor, {mode: M.STEPS, duration: 100}],
        ['adjustment', adjustment, {mode: M.EASE_OUT_QUAD, duration: 250}],
        ['adjustment-default', adjustment, {duration: 100}],
    ];
    for (const [label, target, params] of cases) {
        const eased = Hooks.value('ease', params, target);
        fact(`motion.${label}`, `${modeName(eased.mode)} ${eased.duration}`);
    }
    fact('motion.no-params', Hooks.value('ease', undefined, actor));
    const transition = {
        get_progress_mode: () => M.CUBIC_BEZIER,
        set_cubic_bezier_progress(c1, c2) {
            this.points = [c1, c2];
        },
    };
    Hooks.run('eased', [transition]);
    fact('motion.curve', transition.points?.map(p => `${p.x},${p.y}`).join(' ') ?? 'stock');
    const roles = ['window', 'overview', 'popover', 'unknown'];
    fact('motion.durations', roles.map(r => `${r}=${Hooks.value('motion-duration', 250, r)}`).join(' '));
}

function topBarHooks(label) {
    const dot = {get_theme_node: () => ({get_length: p => p === '-apex-active-width' ? 22 : 0})};
    const widths = [0, 0.5, 1].map(e => Hooks.value('workspace-dot-width', [99, 99], [7, 7], dot, e)[0]);
    fact(`${label}.dots`, `${widths.join(' ')} inactive=${JSON.stringify(Hooks.value('workspace-dot-inactive', 'stock'))}`);
}

function quickSettingsState(label, quickSettings) {
    const grid = quickSettings.menu._grid;
    fact(`${label}.order`, grid.get_children().map(t => t.name).join(','));
    fact(`${label}.subtitles`, grid.get_children().map(t => `${t.name}=${t.subtitle ?? '-'}`).join(','));
    fact(`${label}.power`, `checked=${quickSettings.toggles.power.checked} ` +
        `classes=${[...quickSettings.toggles.power.styleClasses].join(',') || 'none'}`);
}

// NMWirelessNetworkItem's and QuickToggleMenu's actors, as their constructors leave them.
function networkRow(St, Clutter, active) {
    const row = new St.Widget({name: 'row'});
    row.network = new St.Widget({is_active: active});
    const icons = new St.BoxLayout({name: 'icons'});
    row._secureIcon = new St.Icon({name: 'lock', y_align: Clutter.ActorAlign.END});
    [new St.Icon({name: 'signal'}), row._secureIcon].forEach(i => icons.add_child(i));
    row._label = new St.Label({name: 'label'});
    [icons, row._label, new St.Icon({name: 'check'})].forEach(c => row.add_child(c));
    return row;
}

function toggleMenu(St, Clutter) {
    const header = new St.Widget();
    const cells = new Map();
    const {LEFT, RIGHT, TOP, BOTTOM} = Clutter.GridPosition;
    const steps = {[LEFT]: [-1, 0], [RIGHT]: [1, 0], [TOP]: [0, -1], [BOTTOM]: [0, 1]};
    header.layout_manager = {
        attach(child, column, row) {
            header.add_child(child);
            cells.set(child, [column, row]);
        },
        attach_next_to(child, sibling, side) {
            const [column, row] = cells.get(sibling);
            this.attach(child, column + steps[side][0], row + steps[side][1]);
        },
    };
    const menu = new St.Widget();
    menu.actor = new St.Widget({_delegate: menu, text_direction: Clutter.TextDirection.LTR});
    menu.actor.add_child(header);
    menu._header = header;
    menu._headerIcon = new St.Icon();
    menu._headerTitle = new St.Label();
    menu._headerSubtitle = new St.Label({x_align: Clutter.ActorAlign.FILL});
    menu._headerSpacer = new St.Widget();
    header.layout_manager.attach(menu._headerIcon, 0, 0);
    header.layout_manager.attach_next_to(menu._headerTitle, menu._headerIcon, Clutter.GridPosition.RIGHT);
    header.layout_manager.attach_next_to(menu._headerSpacer, menu._headerTitle, Clutter.GridPosition.RIGHT);
    header.layout_manager.attach_next_to(menu._headerSubtitle, menu._headerTitle, Clutter.GridPosition.BOTTOM);
    menu.subtitleAt = () => `${cells.get(menu._headerSubtitle)} x_align=${menu._headerSubtitle.x_align}`;
    return menu;
}

function rowState(row) {
    const names = actor => actor.get_children().map(c => c.name).join(',');
    const lock = row._secureIcon;
    return `children=${names(row)} icons=${names(row.get_children()[0])} checked=${row.has_style_pseudo_class('checked')} ` +
        `lock=${lock.y_align}/${lock.styleClasses.join(',') || 'none'}`;
}

async function exerciseSubmenus(Main) {
    const {default: St} = await import(`file://${GLib.path_get_dirname(shellDir)}/St.js`);
    const {default: Clutter} = await import(`file://${GLib.path_get_dirname(shellDir)}/Clutter.js`);
    const {quickSettings} = Main.panel.statusArea;
    const [active, other, menu] = [networkRow(St, Clutter, true), networkRow(St, Clutter, false), toggleMenu(St, Clutter)];
    quickSettings.menu.actor.children.push(active, other, menu.actor);
    Hooks.run('quick-settings-network-item', active);
    Hooks.run('quick-settings-network-item', other);
    Hooks.run('quick-settings-toggle-menu', menu);
    fact('qs.row.active', rowState(active));
    fact('qs.row.other', rowState(other));
    fact('qs.menu', menu.subtitleAt());
    active.network.is_active = false;
    active.network.emit('notify::is-active');
    other.network.is_active = true;
    other.network.emit('notify::is-active');
    fact('qs.row.switched', `${rowState(active)} | ${rowState(other)}`);
    const gone = networkRow(St, Clutter, true);
    Hooks.run('quick-settings-network-item', gone);
    gone.destroy();
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    fact('qs.off.row', rowState(other));
    fact('qs.off.menu', menu.subtitleAt());
    other.network.emit('notify::is-active');
    fact('qs.off.row-unfollowed', `checked=${other.has_style_pseudo_class('checked')}`);
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    fact('qs.on.row', rowState(other));
    fact('qs.on.menu', menu.subtitleAt());
}

async function exerciseQuickSettings() {
    if (GLib.getenv('PROBE_QUICK_SETTINGS') !== '1')
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const {quickSettings} = Main.panel.statusArea;
    const {toggles} = quickSettings;
    quickSettingsState('qs', quickSettings);
    toggles.doNotDisturb.checked = true;
    toggles.bluetooth.subtitle = 'Headphones';
    fact('qs.live', `dnd=${toggles.doNotDisturb.subtitle} bluetooth=${toggles.bluetooth.subtitle}`);
    toggles.bluetooth.subtitle = null;
    toggles.bluetooth.checked = true;
    fact('qs.own-subtitle-gone', `bluetooth=${toggles.bluetooth.subtitle}`);
    await exerciseSubmenus(Main);
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    quickSettingsState('qs.off', quickSettings);
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    quickSettingsState('qs.on', quickSettings);
}

function notificationsState(label, list, groups) {
    fact(`${label}.groups`, groups.map(g => `${g.name}:expanded=${g.expanded} layout=${g.layout_manager.name ?? 'box'} ` +
        `cover=${g.cover.visible} header=${g.header.visible} ` +
        `stacked=${g.get_children().some(c => c.child?.has_style_pseudo_class('second-in-stack'))}`).join(' | '));
    const header = groups[0].get_children()[0].child.header;
    fact(`${label}.header`, `icon=${header.sourceIcon.visible} line=${header.content.get_children().map(c => c.text).join(' ')}`);
    const {clear} = list;
    fact(`${label}.footer`, `${list.footer.get_children().map(c => c.name ?? c.style_class).join(',')} ` +
        `clear=align:${clear.x_align} visible:${clear.visible}`);
}

// A card's tree to two levels below its box, the header as one node.
function cardTree(actor) {
    if (actor.has_style_class_name?.('message-header'))
        return 'header';
    const children = actor.get_children();
    const name = actor.name ?? actor.style_class ?? 'box';
    return children.length ? `${name}[${children.map(cardTree).join(',')}]` : name;
}

function cardsState(label, group) {
    const cards = group.get_children().map(c => c.child).filter(Boolean);
    fact(`${label}.cards`, cards.map(c => cardTree(c.get_child())).join(' | '));
}

async function exerciseNotifications() {
    if (GLib.getenv('PROBE_NOTIFICATIONS') !== '1')
        return;
    const MessageList = await import(`file://${shellDir}/js/ui/messageList.js`);
    const mail = {title: 'Mail', icon: 'mail-icon'};
    const list = MessageList.newCalendarMessageList();
    const groups = [new MessageList.NotificationMessageGroup(mail, 3)];
    notificationsState('nf', list, groups);
    cardsState('nf', groups[0]);
    const [card] = groups[0].get_children().map(c => c.child);
    card.addAction('Reply');
    card.expand();
    fact('nf.expanded', `${cardTree(card.get_child())} actions=${card._actionBin.visible}`);
    card.unexpand();
    fact('nf.unexpanded', `${cardTree(card.get_child())} actions=${card._actionBin.visible}`);
    groups[0].addNotification(mail);
    cardsState('nf.added', groups[0]);
    const own = new MessageList.Message(mail, 'photo-icon');
    fact('nf.icons', `fallback=${groups[0].get_children()[0].child.icon} own=${own.icon}`);
    list.placeholder.visible = true;
    list.clear.visible = false;
    list.clear.emit('notify::visible');
    const notifications = new Gio.Settings({schema_id: 'org.gnome.desktop.notifications'});
    const dnd = list.footer.get_children()[0];
    notifications.set_boolean('show-banners', false);
    fact('nf.dnd-from-settings', `checked=${dnd.checked} switch=${dnd.child.get_children()[1].state} clear=${list.clear.visible}`);
    dnd.emit('clicked', 1);
    fact('nf.dnd-click', `show-banners=${notifications.get_boolean('show-banners')} checked=${dnd.checked}`);
    const month = MessageList.newCalendar();
    const calendarState = label => {
        fact(`${label}.calendar`, `header=${month.topBox.get_children().map(c => c.name).join(',')} ` +
            `align=${month.topBox.get_children().find(c => c.name === 'month').x_align} ` +
            `class=${month.calendar.has_style_class_name('apex-calendar')}`);
        const day = child => child.get_children().map(c => c.text ?? c.style_class).join('/') || child.text;
        fact(`${label}.days`, month.days.map(b => day(b.get_child())).join(' '));
    };
    calendarState('nf');
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    calendarState('nf.off');
    groups.push(new MessageList.NotificationMessageGroup({title: 'Chat', icon: 'chat-icon'}, 2));
    notificationsState('nf.off', list, groups);
    cardsState('nf.off', groups[0]);
    fact('nf.off.icons', `fallback=${groups[0].get_children()[0].child.icon} own=${own.icon}`);
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    notificationsState('nf.on', list, groups);
    cardsState('nf.on', groups[0]);
    calendarState('nf.on');
}

// endSessionDialog.js as patch 0018's hook sees it: a stock row of Cancel and the confirm
// button, a theme spacing of 10 once the row is styled.
function endSessionDialog(St) {
    const buttonLayout = new St.BoxLayout({style_class: 'modal-dialog-button-box'});
    buttonLayout.layout_manager = {spacing: 12, homogeneous: true};
    buttonLayout.peek_theme_node = () => ({lookup_length: p => p === 'spacing' ? [true, 10] : [false, 0]});
    const message = new St.BoxLayout({style_class: 'message-dialog-content'});
    const dialog = newEmitter({
        contentLayout: new St.BoxLayout({child: message}),
        _messageDialogContent: message,
        buttonLayout,
        addButton({label, action}) {
            const button = new St.Button({style_class: 'modal-dialog-button', label});
            button.action = action;
            buttonLayout.add_child(button);
            return button;
        },
        close() {
            this.emit('closed');
        },
        _confirm(signal) {
            fact('end-session.confirmed', signal);
            (globalThis.endSessionCalls ??= []).push(`confirmed:${signal}`);
            return Promise.resolve();
        },
        _stopTimer() {
            (globalThis.endSessionCalls ??= []).push('timer:stopped');
        },
        // loginManager.js's, its logind proxy a stub that records each call.
        _loginManager: {
            _proxy: {
                call(method, params) {
                    (globalThis.endSessionCalls ??= []).push(`logind:${method}${params.print(false)}`);
                },
            },
            setRebootToBootLoaderMenu() {
                this._proxy.call('SetRebootToBootLoaderMenu', new GLib.Variant('(t)', [60000000]));
            },
        },
    });
    dialog.stockMethods = {close: dialog.close, _confirm: dialog._confirm};
    // As stock's confirm buttons: close the dialog, then confirm once it has closed.
    dialog.open = content => {
        buttonLayout.destroy_all_children();
        dialog.addButton({label: 'Cancel', action: () => dialog.close()});
        for (const {label, signal} of content.confirmButtons) {
            dialog.addButton({
                label, action: () => {
                    const id = dialog.connect('closed', () => {
                        dialog.disconnect(id);
                        dialog._confirm(signal);
                    });
                    dialog.close(true);
                },
            });
            // Stock's Alt-held Boot Options closes first, then asks logind for the menu.
            if (signal === 'ConfirmedReboot') {
                dialog._rebootButtonAlt = dialog.addButton({
                    label: 'Boot Options', action: () => {
                        dialog.close(true);
                        const id = dialog.connect('closed', () => {
                            dialog.disconnect(id);
                            dialog._loginManager.setRebootToBootLoaderMenu();
                            dialog._confirm('ConfirmedReboot');
                        });
                    },
                });
                dialog._rebootButtonAlt.visible = false;
            }
        }
        Hooks.run('end-session-buttons', dialog, content);
    };
    return dialog;
}

function endSessionState(label, dialog) {
    const row = dialog.buttonLayout;
    const [first] = dialog.contentLayout.get_children();
    const icon = first.has_style_class_name('apex-end-session-icon') ? first.child.icon_name : 'none';
    fact(label, `buttons=${row.get_children().filter(b => b.visible).map(b => b.label).join(',')} icon=${icon} ` +
        `spacing=${row.layout_manager.spacing} homogeneous=${row.layout_manager.homogeneous} ` +
        `row=${row.has_style_class_name('apex-end-session-row')}`);
}

function updateCardState(label, dialog) {
    const card = dialog.contentLayout.get_children().find(c => c.has_style_class_name('apex-update-card'));
    const described = card ? `card=${card.update.state} on=${card.on} subtitle=${card.subtitle}` : 'card=none';
    fact(label, `buttons=${dialog.buttonLayout.get_children().filter(b => b.visible).map(b => b.label).join(',')} ${described}`);
    return card;
}

// Board 14's update card, against update.js's stub: which dialogs show it, and what each
// button does with Update1's Apply.
async function exerciseUpdateCard(dialog, contents) {
    const {powerOff, restart, logout} = contents;
    const {stockMethods} = dialog;
    const restored = label => fact(label,
        `close=${dialog.close === stockMethods.close} confirm=${dialog._confirm === stockMethods._confirm}`);
    const staged = {state: 'staged', digest: 'sha256:9e41aa07', version: '45.20261010.133'};
    const open = async (content, update) => {
        globalThis.update1 = update;
        dialog.open(content);
        await spin(50);
    };
    const calls = label => fact(`${label}.calls`, (globalThis.endSessionCalls ?? []).splice(0).join(' ') || 'none');
    const press = async (label, name) => {
        globalThis.endSessionCalls = [];
        dialog.buttonLayout.get_children().find(b => b.label === name).action();
        await spin(50);
        calls(label);
    };
    await open(powerOff, {read: null});
    updateCardState('update.none', dialog);
    await open(logout, {read: staged});
    updateCardState('update.logout', dialog);
    await open(restart, {read: staged});
    updateCardState('update.staged', dialog);
    await press('update.staged', 'Restart & Update');
    restored('update.staged.restored');
    await open(powerOff, {read: staged});
    updateCardState('update.staged-power-off', dialog).setOn(false);
    updateCardState('update.switched-off', dialog);
    await press('update.switched-off', 'Power Off');
    await open(restart, {read: {...staged, state: 'ready-for-reboot'}});
    updateCardState('update.ready', dialog).setOn(false);
    updateCardState('update.ready-switched', dialog);
    await press('update.ready', 'Restart & Update');
    await open(powerOff, {read: staged, applyError: 'Plug in the charger to install the update.'});
    await press('update.apply-failed', 'Power Off');
    updateCardState('update.apply-failed', dialog);
    await press('update.after-failure', 'Power Off');
    const failing = {read: staged, applyError: 'Plug in the charger to install the update.'};
    await open(powerOff, failing);
    await press('update.failed-then', 'Power Off');
    await press('update.failed-then-cancel', 'Cancel');
    await open(powerOff, failing);
    await press('update.failed-before-off', 'Power Off');
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    await press('update.failed-off-cancel', 'Cancel');
    restored('update.failed-off.restored');
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    await open(restart, failing);
    dialog._rebootButtonAlt.visible = true;
    await press('update.boot-options-failed', 'Boot Options');
    await press('update.boot-options-cancel', 'Cancel');
    await open(restart, failing);
    globalThis.endSessionCalls = [];
    await dialog._confirm('ConfirmedReboot');
    await spin(50);
    calls('update.countdown-failed');
    await open(restart, {read: staged});
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    updateCardState('update.off', dialog);
    await press('update.off', 'Restart');
    settings.set_boolean('layer-enabled', true);
    await spin(200);
}

async function exerciseEndSession() {
    if (GLib.getenv('PROBE_END_SESSION') !== '1')
        return;
    const {default: St} = await import(`file://${GLib.path_get_dirname(shellDir)}/St.js`);
    const dialog = endSessionDialog(St);
    const powerOff = {confirmButtons: [{signal: 'ConfirmedShutdown', label: 'Power Off'}], iconName: 'system-shutdown-symbolic'};
    const restart = {confirmButtons: [{signal: 'ConfirmedReboot', label: 'Restart'}], iconName: 'view-refresh-symbolic'};
    const logout = {confirmButtons: [{signal: 'ConfirmedLogout', label: 'Log Out'}]};
    dialog.open(powerOff);
    endSessionState('end-session.power-off', dialog);
    dialog.buttonLayout.get_children()[1].action();
    dialog.open(restart);
    endSessionState('end-session.restart', dialog);
    dialog.open(logout);
    endSessionState('end-session.logout', dialog);
    dialog.open(powerOff);
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    endSessionState('end-session.off', dialog);
    dialog.open(powerOff);
    endSessionState('end-session.off.reopened', dialog);
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    dialog.open(powerOff);
    endSessionState('end-session.on', dialog);
    await exerciseUpdateCard(dialog, {powerOff, restart, logout});
}

// A surface two actors below the stage's child, its sheet naming one further layer.
async function exerciseShadows() {
    if (GLib.getenv('PROBE_SHADOWS') !== '1')
        return;
    const St = (await import(`file://${shellDir}/../St.js`)).default;
    const Registry = await import(`file://${shellDir}/js/ui/apex/shadows/registry.js`);
    const root = new St.Widget({name: 'root'});
    root._stage = {};
    const bin = new St.Widget({name: 'bin', x: 100, y: 40});
    const surface = new St.Widget({name: 'surface', x: 6, y: 6, width: 300, height: 200, mapped: true});
    surface._themeNode = {
        get_shadow: p => p === '-apex-shadow-layer'
            ? {color: {red: 20, green: 30, blue: 60, alpha: 51}, xoffset: 0, yoffset: 2, blur: 8, spread: 0} : null,
        get_border_radius: () => 14,
    };
    root.add_child(bin);
    bin.add_child(surface);
    const layers = label => {
        const found = Registry.layersOf(surface);
        fact(`shadows.${label}`, found.map(l => `${l.style} at ${l.x},${l.y} ${l.width}x${l.height} ` +
            `above=${root.get_children().indexOf(l) === root.get_children().indexOf(bin) + 1} cutout=${l.cutout}`).join(' | ') || 'none');
    };
    Registry.register(surface, {name: 'probe', container: root});
    fact('shadows.before-the-frame', Registry.layersOf(surface).length);
    await spin(50);
    layers('registered');
    Registry.register(surface, {name: 'probe', container: root});
    await spin(50);
    fact('shadows.registered-twice', Registry.layersOf(surface).length);
    surface.mapped = false;
    surface.emit('notify::mapped');
    await spin(50);
    layers('unmapped');
    surface.mapped = true;
    surface.emit('notify::mapped');
    await spin(50);
    layers('mapped-again');
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    layers('off');
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    layers('on');
    surface.destroy();
    fact('shadows.destroyed', `${Registry.layersOf(surface).length} layers, root=${root.get_children().map(c => c.name).join(',')}`);
}

async function exerciseTopBar() {
    if (GLib.getenv('PROBE_TOP_BAR') !== '1')
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const {quickSettings} = Main.panel.statusArea;
    topBarHooks('top-bar');
    fact('pill', pillNames(quickSettings));
    fact('privacy.idle', privacyState(quickSettings));
    showIndicator(quickSettings._camera, true);
    fact('privacy.camera', privacyState(quickSettings));
    showIndicator(quickSettings._camera, false);
    fact('privacy.camera-off', privacyState(quickSettings));
    const later = Main.newQuickSettings();
    Hooks.run('status-indicators', later);
    fact('pill.set-up-after-enable', pillNames(later));

    const {default: St} = await import(`file://${GLib.path_get_dirname(shellDir)}/St.js`);
    const {screenRecording, screenSharing, keyboard} = Main.panel.statusArea;
    fact('recording', screenParts(screenRecording));
    fact('sharing', screenParts(screenSharing));
    fact('right-box', rightBoxOrder(Main));
    // panel.js puts its own items back in stock order at each session-mode change.
    Main.panel.rightBox.set_child_above_sibling(screenSharing.container, screenRecording.container);
    Main.sessionMode.lock(false);
    fact('right-box.after-session-update', rightBoxOrder(Main));
    fact('input-chip', inputChipTexts(keyboard));
    // keyboard.js renames a label for an IBus input mode, and adds one for a new source.
    const [, vietnamese] = keyboard._container.get_children();
    vietnamese.text = 'vi₂';
    vietnamese.emit('notify::text');
    const french = new St.Label({text: 'fr'});
    keyboard._container.add_child(french);
    keyboard._container.emit('child-added', french);
    fact('input-chip.changed', inputChipTexts(keyboard));

    const corner = newHotCorner();
    Hooks.run('hot-corner', corner, Main.layoutManager);
    fact('hot-corner.zone', `${corner.name ?? 'none'} reactive=${corner.reactive ?? false} ` +
        `x=${corner.x} y=${corner.y} ${corner.width}x${corner.height}`);
    if (corner.handlers['enter-event']) {
        corner.handlers['enter-event']();
        corner.handlers['enter-event']();
        corner._pressureBarrier._barriers[0]._isHit = true;
        corner.handlers['leave-event']();
        fact('hot-corner.after-leave-on-the-barrier', corner._pressureBarrier._isTriggered);
        corner._pressureBarrier._barriers[0]._isHit = false;
        corner.handlers['leave-event']();
        corner.handlers['enter-event']();
    }

    settings.set_boolean('layer-enabled', false);
    await spin(200);
    topBarHooks('top-bar.off');
    fact('pill.off', pillNames(quickSettings));
    fact('privacy.off', privacyState(quickSettings));
    fact('recording.off', screenParts(screenRecording));
    fact('sharing.off', screenParts(screenSharing));
    fact('right-box.off', rightBoxOrder(Main));
    fact('input-chip.off', inputChipTexts(keyboard));
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    fact('pill.on', pillNames(quickSettings));
    fact('recording.on', screenParts(screenRecording));
    fact('sharing.on', screenParts(screenSharing));
    fact('input-chip.on', inputChipTexts(keyboard));
}

async function exerciseSolidBar() {
    if (GLib.getenv('PROBE_SOLID_BAR') !== '1')
        return;
    for (const [key, value] of [['translucent-top-bar', false], ['translucent-top-bar', true],
        ['translucent-top-bar', false], ['layer-enabled', false], ['layer-enabled', true]]) {
        printerr(`probe: set ${key}=${value}`);
        settings.set_boolean(key, value);
        // eslint-disable-next-line no-await-in-loop
        await spin(200);
    }
}

async function exerciseFocusedApp() {
    if (GLib.getenv('PROBE_FOCUSED_APP') !== '1')
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const {default: Shell} = await import(`file://${GLib.path_get_dirname(shellDir)}/Shell.js`);
    const tracker = Shell.WindowTracker.get_default();
    const report = label => {
        const item = Main.panel.statusArea['apex-focused-app'];
        fact(`focused-app.${label}`, item
            ? `${item.children[0].text} name=${item.accessible_name} visible=${item.container.visible} reactive=${item.reactive}`
            : 'none');
    };
    report('none');
    tracker.focus({get_name: () => 'Files'});
    report('files');
    tracker.focus(null);
    report('unfocused');
    settings.set_boolean('show-focused-app-name', false);
    await spin(100);
    report('hidden');
    settings.reset('show-focused-app-name');
    Main.sessionMode.lock(true);
    report('locked');
    Main.sessionMode.lock(false);
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    report('off');
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    report('on');
}

async function exerciseSearchButton() {
    if (GLib.getenv('PROBE_SEARCH_BUTTON') !== '1')
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const report = label => {
        const item = Main.panel.statusArea['apex-search'];
        if (!item) {
            fact(`search.${label}`, 'none');
            return;
        }
        const [pill] = item.children;
        fact(`search.${label}`, `${item.accessible_name} pill=${pill.style_class} icon=${pill.child.icon_name} ` +
            `visible=${item.container.visible}`);
    };
    report('enabled');
    const button = Main.panel.statusArea['apex-search'];
    if (button) {
        const tooltip = () => {
            const label = Main.layoutManager.chrome.find(actor => actor.text === 'Search (Super+Space)' && !actor.destroyed);
            return label ? `${label.visible} at ${label.x},${label.y}` : 'none';
        };
        button.hover = true;
        button.emit('notify::hover');
        fact('search.tooltip.hover', tooltip());
        button.hover = false;
        button.emit('notify::hover');
        fact('search.tooltip.unhover', tooltip());
    }
    Main.panel.statusArea['apex-search']?.actions[0].recognize();
    fact('search.click.1', `overview=${Main.overview.visible} spotlight=${(await spotlightPopup())?.isOpen ?? false}`);
    Main.panel.statusArea['apex-search']?.actions[0].recognize();
    fact('search.click.2', `overview=${Main.overview.visible} spotlight=${(await spotlightPopup())?.isOpen ?? false}`);
    Main.sessionMode.lock(true);
    report('locked');
    Main.sessionMode.lock(false);
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    report('off');
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    report('on');
}

function newWindow() {
    return {
        primary: true, showing: true, maximized: true, type: 0,
        is_on_primary_monitor() {
            return this.primary;
        },
        showing_on_its_workspace() {
            return this.showing;
        },
        is_maximized() {
            return this.maximized;
        },
        get_window_type() {
            return this.type;
        },
    };
}

async function exerciseMaximisedWindow() {
    if (GLib.getenv('PROBE_MAXIMISED') !== '1')
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const win = newWindow();
    const steps = [
        ['maximised', () => windows.push(win), global.window_manager, 'size-changed'],
        ['overview', () => (Main.overview.visible = true), Main.overview, 'showing'],
        ['no-overview', () => (Main.overview.visible = false), Main.overview, 'hidden'],
        ['minimised', () => (win.showing = false), global.window_manager, 'minimize'],
        ['unminimised', () => (win.showing = true), global.window_manager, 'unminimize'],
        ['unmaximised', () => (win.maximized = false), global.window_manager, 'size-changed'],
        ['other-monitor', () => Object.assign(win, {maximized: true, primary: false}), global.display, 'restacked'],
        ['desktop-window', () => Object.assign(win, {primary: true, type: 1}), global.display, 'restacked'],
        ['workspace', () => Object.assign(win, {type: 0}), global.workspace_manager, 'active-workspace-changed'],
        ['closed', () => windows.pop(), global.display, 'restacked'],
    ];
    for (const [label, change, emitter, signal] of steps) {
        printerr(`probe: set ${label}`);
        change();
        emitter.emit(signal);
    }
    windows.push(win);
    printerr('probe: set translucent-top-bar=false');
    settings.set_boolean('translucent-top-bar', false);
    await spin(100);
    printerr('probe: set layer-enabled=false');
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    printerr('probe: set restacked');
    global.display.emit('restacked');
}

// The parts of upstream's UnlockDialog the lock feature touches, with its prompt lifecycle:
// destroying an AuthPrompt destroys its verifier, which cancels the PAM conversation.
function newUnlockDialog(St) {
    const clock = new St.BoxLayout({style_class: 'unlock-dialog-clock'});
    for (const part of ['time', 'date', 'hint']) {
        clock[`_${part}`] = new St.Label({name: part});
        clock.add_child(clock[`_${part}`]);
    }
    const promptBox = new St.BoxLayout({name: 'prompt-box'});
    const stack = new St.Widget({name: 'stack'});
    stack.add_child(promptBox);
    stack.add_child(clock);
    const dialog = new St.Widget({style_class: 'unlock-dialog'});
    dialog._authIndicatorButton = new St.Widget({name: 'auth-indicator', visible: true});
    Object.assign(dialog, {
        _clock: clock, _promptBox: promptBox, _stack: stack, _authPrompt: null,
        _backgroundGroup: new St.Widget({name: 'backgrounds'}), conversations: 0, cancelled: [],
        _ensureAuthPrompt() {
            if (this._authPrompt)
                return;
            const prompt = new St.Widget({name: `conversation-${++this.conversations}`});
            prompt._message = new St.Label({name: 'message', text: ''});
            prompt._userVerifier = Object.assign(new St.Widget({name: 'verifier'}), {
                currentMessage: null,
                destroy() {
                    this.cancel();
                },
                cancel: () => this.cancelled.push(prompt.name),
            });
            prompt.connect('destroy', () => prompt._userVerifier.destroy());
            this._authPrompt = prompt;
            promptBox.add_child(prompt);
            promptBox.emit('child-added', prompt);
        },
        _showPrompt() {
            this._ensureAuthPrompt();
            this.page = 'prompt';
        },
        _showClock() {
            this.page = 'clock';
        },
        _maybeDestroyAuthPrompt() {
            if (!this._authPrompt)
                return;
            promptBox.remove_child(this._authPrompt);
            this._authPrompt.destroy();
            this._authPrompt = null;
        },
    });
    dialog.add_child(dialog._backgroundGroup);
    dialog.add_child(stack);
    return dialog;
}

const names = actors => actors.map(a => a.name ?? a.styleClasses?.[0] ?? '?').join(',');

// What upstream's AuthPrompt does with a queued message, before the lock hears it.
function say(dialog, serviceName, text, error = false) {
    const prompt = dialog._authPrompt;
    if (!prompt)
        return;
    if (error)
        prompt._message.add_style_class_name('login-dialog-message-warning');
    else
        prompt._message.remove_style_class_name('login-dialog-message-warning');
    prompt._message.text = text ?? '';
    prompt._userVerifier.currentMessage = text ? {serviceName, text} : null;
    prompt._userVerifier.emit('show-message');
}

function hintState(dialog) {
    const line = dialog._promptBox.children.find(c => c.has_style_class_name('apex-lock-hint-line'));
    if (!line)
        return 'none';
    const [glyph, label] = line.children;
    return `"${label.text}" glyph=${glyph.visible ? glyph.icon_name : 'none'} failed=${line.has_style_class_name('apex-lock-hint-failed')} ` +
        `message=${dialog._authPrompt?._message.visible ?? 'none'} indicator=${dialog._authIndicatorButton.visible}`;
}

function lockState(dialog) {
    return `page=${dialog.page ?? 'none'} prompt=${dialog._authPrompt?.name ?? 'none'} cancelled=${dialog.cancelled.join(',') || 'none'}`;
}

function setScreen(mode) {
    displayConfig.powerSaveMode = mode;
    displayConfig.emit('g-properties-changed');
}

async function exerciseLock() {
    if (GLib.getenv('PROBE_LOCK') !== '1')
        return;
    const {default: St} = await import(`file://${GLib.path_get_dirname(shellDir)}/St.js`);
    const PowerSave = {UNSUPPORTED: -1, ON: 0, STANDBY: 1, SUSPEND: 2, OFF: 3};

    setScreen(PowerSave.ON);
    const dialog = newUnlockDialog(St);
    fact('lock.run', `${Hooks.run('unlock-dialog', dialog)}`);
    await spin(50);
    const stage = dialog._stack.children[0];
    fact('lock.layout', `dialog=${dialog.styleClasses.join(' ')} stack=${names(dialog._stack.children)} ` +
        `stage=${names(stage.children ?? [])} clock=${names(dialog._clock.children)} ` +
        `hint=${dialog._clock._hint.visible} children=${names(dialog.children)}`);
    fact('lock.open', lockState(dialog));
    const promptBoxChildren = () => dialog._promptBox.children
        .map(c => c.text ?? c.name ?? c.children.map(part => part.text ?? '').join('')).join(',');
    fact('lock.prompt-box', promptBoxChildren());
    fact('lock.hint.password', hintState(dialog));
    for (const [label, service, text, error] of [
        ['fingerprint-scan', 'gdm-fingerprint', '(or place finger on reader)', false],
        ['fingerprint-failed', 'gdm-fingerprint', 'Failed to match fingerprint', true],
        ['queue-done', null, null, false],
        ['password-problem', 'gdm-password', "Sorry, that didn't work. Please try again.", true],
        ['fingerprint-again', 'gdm-fingerprint', '(or place finger on reader)', false],
    ]) {
        say(dialog, service, text, error);
        fact(`lock.hint.${label}`, hintState(dialog));
    }
    for (const [label, mode] of [['blank', PowerSave.OFF], ['wake', PowerSave.ON],
        ['standby', PowerSave.STANDBY], ['wake-again', PowerSave.ON],
        ['suspend', PowerSave.SUSPEND], ['unsupported', PowerSave.UNSUPPORTED]]) {
        setScreen(mode);
        fact(`lock.${label}`, lockState(dialog));
    }
    fact('lock.prompt-box.after-wake', promptBoxChildren());
    fact('lock.hint.after-wake', hintState(dialog));
    dialog.emit('destroy');

    setScreen(PowerSave.OFF);
    const lockedWhileBlank = newUnlockDialog(St);
    Hooks.run('unlock-dialog', lockedWhileBlank);
    await spin(50);
    fact('lock.open-blank', lockState(lockedWhileBlank));
    setScreen(PowerSave.ON);
    fact('lock.open-blank.wake', lockState(lockedWhileBlank));
    lockedWhileBlank.emit('destroy');

    for (const reply of ['silent', 'error']) {
        displayConfig.reply = reply;
        setScreen(PowerSave.OFF);
        const unanswered = newUnlockDialog(St);
        Hooks.run('unlock-dialog', unanswered);
        // eslint-disable-next-line no-await-in-loop
        await spin(50);
        fact(`lock.display-config-${reply}`, lockState(unanswered));
        unanswered.emit('destroy');
    }
    displayConfig.reply = 'answer';
    setScreen(PowerSave.ON);

    fact('lock.clock-progress', [0, 0.5, 1].map(p => Hooks.value('unlock-clock-progress', p)).join(' '));
    fact('lock.blur', JSON.stringify(Hooks.value('unlock-blur', {brightness: 0.65, radius: 90})));
    for (const question of ['Password:', 'Password: ', 'Verification code:', 'PIN', 'password:']) {
        const stockText = question.startsWith('Password:') ? 'Password' : question.replace(/[:：] *$/, '').trim();
        fact(`lock.question.${JSON.stringify(question)}`, JSON.stringify(Hooks.value('auth-prompt-question', stockText, question)));
    }
    const icon = new St.Icon({icon_name: 'avatar-default-symbolic'});
    const user = (realName, userName) => ({get_real_name: () => realName, get_user_name: () => userName});
    for (const [label, who] of [['real-name', user('Apex', 'apex')], ['user-name', user('', 'đức')],
        ['spaces', user('  zoë', 'z')], ['nobody', user('', '')]]) {
        const avatar = Hooks.value('avatar-fallback', icon, who, 96);
        fact(`lock.avatar.${label}`, avatar === icon ? 'stock' : `${avatar.text} ${avatar.style_class} ${avatar.style}`);
    }
}

// The parts of upstream's AuthenticationDialog the polkit feature touches, as _init() leaves them.
function newAuthenticationDialog(St, {
    userName = 'apex', accountType = 1, loaded = true, actionId = 'io.github.apex-linux.apex.update.rollback',
} = {}) {
    const root = userName === 'root';
    const userBox = new St.BoxLayout({style_class: 'polkit-dialog-user-layout', orientation: 1});
    const avatar = new St.Bin({style_class: 'user-icon', name: 'avatar'});
    const userLabel = new St.Label({
        style_class: root ? 'polkit-dialog-user-root-label' : 'polkit-dialog-user-label',
        text: root ? 'Administrator' : 'Apex',
    });
    userBox.add_child(avatar);
    userBox.add_child(userLabel);
    const info = new St.Label({style_class: 'prompt-dialog-info-label', visible: false, text: ''});
    const warnings = new St.BoxLayout({name: 'warnings'});
    for (const label of [new St.Label({name: 'caps-lock'}), new St.Label({name: 'error', visible: false}),
        info, new St.Label({name: 'null'})])
        warnings.add_child(label);
    const body = new St.BoxLayout({name: 'body'});
    for (const part of [userBox, new St.Entry({name: 'password'}), warnings])
        body.add_child(part);
    const contentLayout = new St.BoxLayout({name: 'content'});
    contentLayout.add_child(new St.BoxLayout({name: 'header'}));
    contentLayout.add_child(body);
    const user = new St.Widget({name: 'user'});
    Object.assign(user, {is_loaded: loaded, get_user_name: () => userName, get_account_type: () => accountType});
    const dialog = new St.Widget({style_class: 'prompt-dialog'});
    Object.assign(dialog, {
        actionId, contentLayout, _userAvatar: avatar, _userLabel: userLabel, _user: user, _infoMessageLabel: info, warnings,
    });
    return dialog;
}

function polkitLayout(dialog) {
    const row = dialog._userAvatar.get_parent();
    const column = row.children.find(c => c.has_style_class_name('apex-polkit-names'));
    return `dialog=${dialog.styleClasses.join(' ')} content=${names(dialog.contentLayout.children)} ` +
        `user=${row.orientation === 0 ? 'row' : 'column'}:${names(row.children)} ` +
        `names=${column?.children?.map(c => `${c.text}${c.visible ? '' : '(hidden)'}`).join('/') ?? 'none'}`;
}

function polkitInfo(dialog) {
    const line = dialog._infoMessageLabel.get_parent();
    if (line === dialog.warnings)
        return `stock visible=${dialog._infoMessageLabel.visible}`;
    const glyph = line.children[0];
    return `${line.styleClasses.join(' ')} visible=${line.visible} glyph=${glyph.visible ? glyph.icon_name : 'none'}`;
}

function polkitDetails(dialog) {
    const details = dialog.contentLayout.children.find(c => c.has_style_class_name?.('apex-polkit-details'));
    if (!details)
        return 'none';
    const [toggle, grid] = details.children;
    const rows = !grid.visible ? '' : grid.children.filter(r => r.visible).map(r => r.children.map(c => c.text).join('=')).join(' ');
    const chevron = toggle.child.children[0].icon_name;
    return `open=${grid.visible} checked=${toggle.has_style_pseudo_class('checked')} chevron=${chevron} rows=${rows}`;
}

async function exercisePolkit() {
    if (GLib.getenv('PROBE_POLKIT') !== '1')
        return;
    const dir = GLib.path_get_dirname(shellDir);
    const {default: St} = await import(`file://${dir}/St.js`);
    const {default: Polkit} = await import(`file://${dir}/Polkit.js`);

    const dialog = newAuthenticationDialog(St);
    fact('polkit.run', `${Hooks.run('polkit-dialog', dialog)}`);
    fact('polkit.layout', polkitLayout(dialog));
    fact('polkit.details.open', polkitDetails(dialog));
    await spin(50);
    fact('polkit.details.vendor', polkitDetails(dialog));
    const toggle = dialog.contentLayout.children.find(c => c.has_style_class_name('apex-polkit-details'))?.children[0];
    toggle?.emit('clicked');
    fact('polkit.details.closed', polkitDetails(dialog));
    toggle?.emit('clicked');
    fact('polkit.details.reopened', polkitDetails(dialog));

    const info = dialog._infoMessageLabel;
    const {PROMPT_MSGIDS} = await import(`file://${shellDir}/js/ui/apex/polkit/fingerprint.js`);
    fact('polkit.prompt-msgids', `${PROMPT_MSGIDS.length} ${PROMPT_MSGIDS[1]} | ${PROMPT_MSGIDS.at(-1)}`);
    fact('polkit.info.none', polkitInfo(dialog));
    for (const [label, text] of [['generic', 'Place your finger on the fingerprint reader'],
        ['swipe-reader', 'Swipe your right index finger across Goodix MOC Fingerprint Sensor'],
        ['timed-out', 'Verification timed out'], ['other-module', 'Place your coffee on the table']]) {
        info.text = text;
        info.visible = true;
        fact(`polkit.info.${label}`, polkitInfo(dialog));
    }
    info.text = 'Place your left thumb on the fingerprint reader';
    info.visible = false;
    fact('polkit.info.hidden', polkitInfo(dialog));

    for (const [label, who] of [['standard', {accountType: 0}], ['root', {userName: 'root', accountType: 1}]]) {
        const other = newAuthenticationDialog(St, who);
        Hooks.run('polkit-dialog', other);
        fact(`polkit.role.${label}`, polkitLayout(other));
    }
    const loading = newAuthenticationDialog(St, {loaded: false});
    Hooks.run('polkit-dialog', loading);
    fact('polkit.role.loading', polkitLayout(loading));
    loading._user.is_loaded = true;
    loading._user.emit('notify::is-loaded');
    fact('polkit.role.loaded', polkitLayout(loading));

    const unknown = newAuthenticationDialog(St, {actionId: 'org.example.unregistered'});
    Hooks.run('polkit-dialog', unknown);
    await spin(50);
    fact('polkit.details.unknown-action', polkitDetails(unknown));
    for (const reply of ['error', 'cancel']) {
        Polkit.stub.reply = reply;
        const failed = newAuthenticationDialog(St);
        Hooks.run('polkit-dialog', failed);
        // eslint-disable-next-line no-await-in-loop
        await spin(50);
        fact(`polkit.details.${reply}`, polkitDetails(failed));
    }
    Polkit.stub.reply = 'answer';
    fact('polkit.authority-calls', Polkit.stub.calls);
}

function glassOf(actor) {
    const effect = actor.get_effect('apex-glass');
    if (!effect)
        return `${actor.name}:none`;
    const mode = effect.mode === 1 ? 'background' : 'actor';
    return `${actor.name}:r${effect.radius}/s${effect.saturation}/c${effect.corner_radius}/${effect.enabled ? 'on' : 'paused'}` +
        `${effect.fine && effect.follow_opacity ? '' : '/stock'}/${mode}`;
}

async function exerciseGlass() {
    if (GLib.getenv('PROBE_GLASS') !== '1')
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const Registry = await import(`file://${shellDir}/js/ui/apex/glass/registry.js`);
    const {default: St} = await import(`file://${GLib.path_get_dirname(shellDir)}/St.js`);
    const {panel} = Main;
    const {quickSettings, dateMenu} = panel.statusArea;
    const surfaces = () => [panel, quickSettings.menu.box, dateMenu.menu.box, ...Main.messageTray._bannerBin.children];
    const report = label => fact(`glass.${label}`, `${surfaces().map(glassOf).join(' ')} ` +
        `solid=${Main.uiGroup.has_style_class_name('apex-solid')} redirects=${panel.redirect},${quickSettings.menu.box.parent.redirect}`);
    report('enabled');
    const scrim = Main.uiGroup.get_children().find(actor => actor.name === 'apexGlassScrim');
    const {overviewGroup} = Main.layoutManager;
    const adjustment = Main.overview._overview._controls._stateAdjustment;
    const scrimFact = label => fact(`glass.scrim.${label}`, scrim ? `${glassOf(scrim)} visible=${scrim.visible}` : 'none');
    scrimFact('closed');
    overviewGroup.visible = true;
    overviewGroup.emit('notify::visible');
    scrimFact('overview');
    adjustment.value = 2;
    adjustment.emit('notify::value');
    scrimFact('launcher');
    adjustment.value = 1;
    adjustment.emit('notify::value');
    overviewGroup.visible = false;
    overviewGroup.emit('notify::visible');
    Main.messageTray.showBanner();
    report('banner');

    panel.add_style_class_name('apex-solid-bar');
    report('solid-bar');
    panel.remove_style_class_name('apex-solid-bar');
    Main.sessionMode.lock(true);
    report('locked');
    Main.sessionMode.lock(false);
    report('unlocked');
    quickSettings.menu.box.mapped = false;
    quickSettings.menu.box.emit('notify::mapped');
    report('menu-closed');
    quickSettings.menu.box.mapped = true;
    quickSettings.menu.box.emit('notify::mapped');

    const dock = new Main.StubActor('dock', {glass: {blur: 28, saturation: 1.8, radius: 22}, extents: [420, 820, 600, 62]});
    Registry.register(dock, {name: 'dock'});
    Registry.register(dock, {name: 'dock', paused: () => true});
    fact('glass.registered-twice', `${glassOf(dock)} ${Registry.surfaces().filter(r => r.actor === dock).length}`);
    Registry.register(dock, {name: 'dock'});
    fact('glass.registered', glassOf(dock));
    const window = Object.assign(new Main.StubActor('window', {extents: [100, 100, 400, 300]}), {get_meta_window: () => ({})});
    windowActors.push(window);
    global.window_group.emit('child-added', window);
    const redraws = () => [panel, quickSettings.menu.box, dock].map(a => `${a.name}=${a.redraws}`).join(' ');
    const before = redraws();
    window.emit('damaged');
    fact('glass.damage-elsewhere', `${before} -> ${redraws()}`);
    window.box = [400, 0, 400, 300];
    window.emit('notify::allocation');
    fact('glass.moved-under-the-bar', redraws());
    window.box = [400, 600, 400, 300];
    window.emit('notify::allocation');
    window.emit('damaged');
    fact('glass.damage-under-the-dock', redraws());
    global.display.emit('restacked');
    fact('glass.restacked', redraws());

    for (const [label, key, on, off] of [
        ['reduce-transparency', 'reduce-transparency', true, false],
        ['disabled', 'disabled-features', ['glass'], []],
    ]) {
        const set = value => Array.isArray(value) ? settings.set_strv(key, value) : settings.set_boolean(key, value);
        set(on);
        // eslint-disable-next-line no-await-in-loop
        await spin(200);
        report(label);
        fact(`glass.${label}.dock`, glassOf(dock));
        set(off);
        // eslint-disable-next-line no-await-in-loop
        await spin(200);
    }
    St.Settings.get().setHighContrast(true);
    report('high-contrast');
    St.Settings.get().setHighContrast(false);

    settings.set_strv('disabled-features', ['glass']);
    await spin(200);
    const later = new Main.StubActor('later', {glass: {blur: 34, saturation: 1.8, radius: 26}});
    Registry.register(later, {name: 'later'});
    fact('glass.registered-while-disabled', glassOf(later));
    settings.set_strv('disabled-features', []);
    await spin(200);
    fact('glass.registered-while-disabled.enabled', glassOf(later));

    Registry.unregister(dock);
    Registry.unregister(dock);
    fact('glass.unregistered', glassOf(dock));
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    report('off');
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    report('on');
}

function newWorkspace(nWindows) {
    return {
        _background: {
            visible: true,
            hide() {
                this.visible = false;
            },
        },
        _container: newEmitter({
            nWindows,
            get_n_children() {
                return this.nWindows;
            },
        }),
        children: [],
        add_child(child) {
            this.children.push(child);
        },
    };
}

function workspaceFacts(label, workspace) {
    const [empty] = workspace.children;
    fact(`workspace.${label}`, `background=${workspace._background.visible} ` +
        `${empty ? `"${empty.text}" .${empty.style_class} visible=${empty.visible} opacity=${empty.opacity}` : 'no label'}`);
}

function buildWorkspaces(label) {
    const layout = {stateAdjustment: newEmitter({value: 1})};
    const empty = newWorkspace(0);
    Hooks.run('workspace', empty, layout);
    workspaceFacts(`${label}.empty`, empty);
    empty._container.nWindows = 1;
    empty._container.emit('child-added');
    workspaceFacts(`${label}.window-added`, empty);
    empty._container.nWindows = 0;
    empty._container.emit('child-removed');
    layout.stateAdjustment.value = 0.5;
    layout.stateAdjustment.emit('notify::value');
    workspaceFacts(`${label}.half-open`, empty);
    const busy = newWorkspace(2);
    Hooks.run('workspace', busy, {stateAdjustment: newEmitter({value: 1})});
    workspaceFacts(`${label}.with-windows`, busy);
}

async function overviewFacts(label) {
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const {_thumbnailsBox: box, _appDisplay: {_grid: grid}} = Main.overview._overview._controls;
    const preview = {_title: 'title', _closeButton: 'close'};
    fact(`overview.${label}`, `title-visible=${Hooks.value('window-title-visible', false)} ` +
        `overlay=${Hooks.value('window-overlay', ['title', 'close'], preview).join('+')} ` +
        `scale=${Hooks.value('thumbnail-scale', 0.05)} threshold=${Hooks.value('thumbnails-threshold', 2)} ` +
        `box=${box._maxThumbnailScale} grid=${JSON.stringify(grid._gridModes)} ` +
        `icon=${grid.layout_manager.fixed_icon_size} strip=${Hooks.value('app-grid-workspaces-height', 130)}`);
    fact(`overview.${label}.relayout`, `mode=${grid._currentMode} page-width=${grid.layout_manager._pageWidth}`);
    buildWorkspaces(label);
}

async function exerciseOverview() {
    if (GLib.getenv('PROBE_OVERVIEW') !== '1')
        return;
    await overviewFacts('enabled');
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    await overviewFacts('off');
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    await overviewFacts('on');
}

function dockState(Main) {
    const box = Main.layoutManager.chrome.find(actor => actor.name === 'apexDockBox' && !actor.destroyed);
    const dock = box?.get_children()[0] ?? null;
    if (!dock)
        return `none dash=${Main.overview.dash.visible} dash-height=${Main.overview.dash.height}`;
    const {separator, showApps, trash} = dock.tailItems;
    const apps = dock._box.get_children().map(item => `${item.name}:${item.child.icon.iconSize}`);
    return `${[...apps, separator.has_style_class_name('apex-dock-separator') ? 'separator' : '?',
        `show-apps:${showApps.icon.iconSize}`, `trash:${trash.icon.iconSize}${trash.visible ? '' : '(hidden)'}`].join(' ')} ` +
        `indicators=${!dock.has_style_class_name('apex-dock-no-indicators')} visible=${dock.visible} ` +
        `dash=${Main.overview.dash.visible} dash-height=${Main.overview.dash.height}`;
}

async function until(condition, ms = 3000) {
    for (let waited = 0; !condition() && waited < ms; waited += 50)
        // eslint-disable-next-line no-await-in-loop
        await spin(50);
    return condition();
}

function indicatorBox(Main) {
    return Main.panel.rightBox.children.find(c => c.name === 'apexIndicators') ?? null;
}

// The box holds each PanelMenu.Button's container, the overflow button's last.
function indicatorButton(Main, name) {
    return indicatorBox(Main)?.get_children().map(c => c.child).find(b => b.accessible_name === name) ?? null;
}

function overflowButton(Main) {
    return indicatorBox(Main).get_children().at(-1).child;
}

function clickGesture(button) {
    return button.actions.find(a => a.click);
}

function indicatorBar(Main) {
    const box = indicatorBox(Main);
    if (!box)
        return 'none';
    const containers = box.get_children();
    const overflow = containers.at(-1);
    const inBar = containers.slice(0, -1).filter(c => c.visible).map(({child: b}) => {
        const [glyph, dot] = b.children[0].get_children();
        return `${b.accessible_name}:${glyph.kind}${dot.visible ? '+dot' : ''}`;
    });
    const divider = Main.panel.rightBox.children.find(c => c.has_style_class_name?.('apex-indicators-divider'));
    const count = overflow.visible ? overflow.child.children[0].get_children()[1].text : 'none';
    return `${box.visible ? inBar.join(',') : 'hidden'} overflow=${count} divider=${divider.visible}`;
}

function rightBoxOrder(Main) {
    const {quickSettings} = Main.panel.statusArea;
    return Main.panel.rightBox.children.map(c => {
        if (c.name === 'apexIndicators')
            return 'indicators';
        if (c.has_style_class_name?.('apex-indicators-divider'))
            return 'divider';
        return c === quickSettings.container ? 'quickSettings' : c.name;
    }).join(',');
}

function menuItem(item) {
    const kind = item.constructor.name;
    const label = item.label?.text ?? '';
    const flags = `${item.visible ? '' : '(hidden)'}${item.sensitive === false ? '(off)' : ''}`;
    if (item.has_style_class_name('apex-indicator-menu-header'))
        return `[${label}]`;
    if (kind === 'PopupSeparatorMenuItem')
        return '|';
    if (kind === 'PopupSubMenuMenuItem')
        return `${label}>(${item.menu.items.map(menuItem).join(' ')})`;
    if (kind === 'PopupSwitchMenuItem')
        return `${label}=switch:${item.state}${flags}`;
    const shortcut = item.get_children()[1]?.text;
    const radio = {1: '=radio:on', 4: '=radio:off'}[item.ornament] ?? '';
    return `${label}${radio}${shortcut ? `<${shortcut}>` : ''}${flags}`;
}

function openMenus(Main) {
    return Main.panel.menuManager.menus.filter(m => m.isOpen);
}

const STATUS_SUBMENU = [
    {id: 5, props: {label: 'Online', 'toggle-type': 'radio', 'toggle-state': 1}},
    {id: 6, props: {label: 'Away', 'toggle-type': 'radio', 'toggle-state': 0}},
];
const CHAT_MENU = {
    id: 0,
    props: {},
    children: [
        {id: 1, props: {label: '_Show Chat', shortcut: [['Control', 'Shift', 'c']]}},
        {id: 2, props: {label: 'Do Not Disturb', 'toggle-type': 'checkmark', 'toggle-state': 0}},
        {id: 3, props: {type: 'separator'}},
        {id: 4, props: {label: 'Status', 'children-display': 'submenu'}, children: STATUS_SUBMENU},
        {id: 7, props: {label: 'Hidden', visible: false}},
        {id: 8, props: {label: 'Quit Chat', enabled: false}},
    ],
};
const GAMES_MENU = {id: 0, props: {}, children: [{id: 1, props: {label: 'Library'}}]};
// 16 x 16 pixels of ARGB 255,10,20,30, as an item sends a pixmap.
const PIXMAP = [[16, 16, new Uint8Array(16 * 16 * 4).map((_, i) => [255, 10, 20, 30][i % 4])]];

async function clickIndicator(Main, name, mouseButton) {
    clickGesture(indicatorButton(Main, name)).click(mouseButton);
    await spin(100);
}

async function exerciseIndicatorMenus(Main, chat) {
    await clickIndicator(Main, 'Chat', 3);
    await until(() => openMenus(Main).length > 0 && openMenus(Main)[0].items.length > 1);
    const [menu] = openMenus(Main);
    fact('indicators.menu', menu.items.map(menuItem).join(' '));
    fact('indicators.menu.button-checked', indicatorButton(Main, 'Chat').pseudoClasses.has('checked'));
    chat.updateMenuProperties([[2, {'toggle-state': 1}], [1, {label: 'Show _Chat Window'}]]);
    await spin(200);
    fact('indicators.menu.updated', menu.items.map(menuItem).join(' '));
    menu.items.find(i => i.label?.text === 'Do Not Disturb').activate();
    menu.items.find(i => i.label?.text === 'Status').menu.open();
    await spin(200);
    menu.close();
    await spin(200);
    fact('indicators.menu.closed',
        `open=${menu.isOpen} button-checked=${indicatorButton(Main, 'Chat').pseudoClasses.has('checked')}`);
    await clickIndicator(Main, 'Game launcher', 1);
    fact('indicators.item-is-menu', openMenus(Main).map(m => m.items.map(menuItem).join(' ')).join(';'));
    openMenus(Main).forEach(m => m.close());
}

async function exerciseIndicatorOverflow(Main) {
    const overflow = overflowButton(Main);
    clickGesture(overflow).click(1);
    await spin(100);
    const [menu] = openMenus(Main);
    fact('indicators.overflow.rows', menu.items.map(row => {
        const [glyph, label, chevron] = row.get_children();
        return `${glyph.kind}:${label.text}:${chevron.icon_name}`;
    }).join(' '));
    menu.items[0].activate();
    await spin(200);
    fact('indicators.overflow.after-row', `open=${menu.isOpen} ` +
        `item-menu-under=${openMenus(Main).map(m => m.sourceActor === overflow ? 'overflow' : 'other').join(',')}`);
    openMenus(Main).forEach(m => m.close());
}

async function exerciseIndicators() {
    if (GLib.getenv('PROBE_INDICATORS') !== '1')
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const bus = Gio.DBus.session;
    const watcher = () => Sni.watcherOwner(bus) === bus.get_unique_name() ? 'shell' : Sni.watcherOwner(bus);
    fact('indicators.watcher', watcher());
    fact('indicators.empty', `${indicatorBar(Main)} order=${rightBoxOrder(Main)}`);
    const sync = new Sni.FakeItem('File sync', {IconName: 'apex-sync'});
    const chat = new Sni.FakeItem('Chat', {IconName: 'apex-chat-symbolic'}, CHAT_MENU, {byName: true});
    const games = new Sni.FakeItem('Game launcher', {IconName: 'apex-games', ItemIsMenu: true}, GAMES_MENU);
    const keys = new Sni.FakeItem('Password manager', {IconPixmap: PIXMAP});
    await until(() => indicatorBar(Main).split(':').length === 5);
    fact('indicators.four', `${indicatorBar(Main)} order=${rightBoxOrder(Main)}`);
    const music = new Sni.FakeItem('Media player', {IconName: 'apex-missing'});
    await until(() => indicatorBar(Main).includes('overflow=+'));
    fact('indicators.five', indicatorBar(Main));
    const {gicon} = indicatorButton(Main, 'Password manager').children[0].get_children()[0];
    fact('indicators.pixmap', `${gicon.pixmap} alpha=${gicon.hasAlpha} first-pixel-rgba=${gicon.firstPixel}`);
    await exerciseIndicatorOverflow(Main);

    music.set({Status: 'Passive'});
    await until(() => indicatorBar(Main).includes('overflow=none'));
    fact('indicators.passive', indicatorBar(Main));
    chat.set({Status: 'NeedsAttention'});
    await until(() => indicatorBar(Main).includes('+dot'));
    fact('indicators.attention', indicatorBar(Main));

    await clickIndicator(Main, 'File sync', 1);
    await clickIndicator(Main, 'File sync', 2);
    await clickIndicator(Main, 'File sync', 3);
    const scroll = indicatorButton(Main, 'File sync').actions.find(a => a.scroll);
    scroll.scroll(0, 1);
    scroll.scroll(1, 0);
    await clickIndicator(Main, 'Chat', 1);
    await exerciseIndicatorMenus(Main, chat);

    sync.quit();
    await until(() => !indicatorBar(Main).includes('File sync'));
    fact('indicators.vanished', indicatorBar(Main));

    settings.set_strv('disabled-features', ['indicators']);
    await spin(300);
    fact('indicators.disabled', `${indicatorBar(Main)} watcher=${watcher()} order=${rightBoxOrder(Main)}`);
    settings.set_strv('disabled-features', []);
    await until(() => indicatorBar(Main).split(':').length === 4);
    fact('indicators.re-enabled', `${indicatorBar(Main)} watcher=${watcher()}`);
    settings.set_boolean('layer-enabled', false);
    await spin(300);
    fact('indicators.layer-off', `${indicatorBar(Main)} watcher=${watcher()}`);
    settings.set_boolean('layer-enabled', true);
    await until(() => indicatorBar(Main).split(':').length === 4);
    fact('indicators.layer-on', indicatorBar(Main));
    [chat, games, keys, music].forEach(item => item.quit());
}

async function exerciseRemoteWatcher() {
    if (!remoteWatcher)
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const bus = Gio.DBus.session;
    const early = new Sni.FakeItem('Early', {IconName: 'apex-sync'});
    remoteWatcher.items.push(`${early.conn.get_unique_name()}/StatusNotifierItem`);
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    settings.set_boolean('layer-enabled', true);
    await until(() => indicatorBar(Main).includes('Early'));
    fact('remote.listed', indicatorBar(Main));
    const late = new Sni.FakeItem('Late', {IconName: 'apex-sync'});
    remoteWatcher.announce(`${late.conn.get_unique_name()}/StatusNotifierItem`);
    await until(() => indicatorBar(Main).includes('Late'));
    fact('remote.announced', indicatorBar(Main));
    remoteWatcher.quit();
    await until(() => Sni.watcherOwner(bus) === bus.get_unique_name());
    await until(() => indicatorBar(Main).split(':').length === 3);
    fact('remote.gone', `${indicatorBar(Main)} watcher=${Sni.watcherOwner(bus) === bus.get_unique_name() ? 'shell' : 'other'}`);
    [early, late].forEach(item => item.quit());
}

async function exerciseDock() {
    if (GLib.getenv('PROBE_DOCK') !== '1')
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const report = label => fact(`dock.${label}`, dockState(Main));
    report('enabled');
    for (const [key, value] of [['dock-icon-size', 'small'], ['dock-icon-size', 'large'], ['dock-show-trash', false],
        ['dock-running-indicators', false]]) {
        if (typeof value === 'string')
            settings.set_string(key, value);
        else
            settings.set_boolean(key, value);
        // eslint-disable-next-line no-await-in-loop
        await spin(50);
        report(`${key}=${value}`);
    }
    ['dock-icon-size', 'dock-show-trash', 'dock-running-indicators'].forEach(key => settings.reset(key));
    await spin(50);
    Main.sessionMode.lock(true);
    report('locked');
    Main.sessionMode.lock(false);

    const dock = Main.layoutManager.chrome.find(actor => actor.name === 'apexDockBox' && !actor.destroyed)
        ?.get_children()[0];
    if (dock?.tailItems) {
        const Registry = await import(`file://${shellDir}/js/ui/apex/glass/registry.js`);
        fact('dock.glass', Registry.surfaces().filter(s => s.actor === dock._background).map(s => s.name).join(','));
        const {showAppsButton} = dock;
        const overviewButton = Main.overview.dash.showAppsButton;
        showAppsButton.checked = true;
        showAppsButton.emit('notify::checked');
        fact('dock.show-apps', `overview=${Main.overview.visible} overview-button=${overviewButton.checked}`);
        overviewButton.checked = false;
        overviewButton.emit('notify::checked');
        fact('dock.overview-show-apps-off', `dock-button=${showAppsButton.checked}`);
        fact('dock.hooks', `separator=${Hooks.value('dash-favorites-separator', true, dock)} ` +
            `stock-separator=${Hooks.value('dash-favorites-separator', true, {})} ` +
            `show-apps=${Hooks.value('show-apps-icon-name', 'view-app-grid-symbolic', dock.tailItems.showApps)}`);
    }
    settings.set_boolean('layer-enabled', false);
    await spin(200);
    report('off');
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    report('on');
}

async function exerciseIntellihide() {
    if (GLib.getenv('PROBE_INTELLIHIDE') !== '1')
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const box = Main.layoutManager.chrome.find(actor => actor.name === 'apexDockBox' && !actor.destroyed);
    const pressure = globalThis.PROBE_PRESSURE;
    if (!box || !pressure)
        return;
    const [barrier] = pressure.barriers;
    fact('intellihide.barrier', `x=${barrier.x1}..${barrier.x2} y=${barrier.y1}..${barrier.y2} directions=${barrier.directions}`);
    box.height = 80;
    const win = newWindow();
    const step = async (label, change) => {
        printerr(`probe: set ${label}`);
        await change();
        fact('intellihide.hidden', box.translation_y > 0);
    };
    await step('initial', () => {});
    await step('maximised', () => {
        windows.push(win);
        global.window_manager.emit('size-changed');
    });
    await step('edge', () => pressure.trigger());
    await step('pointer-elsewhere', () => spin(450));
    await step('edge-again', () => pressure.trigger());
    await step('pointer-on-dock', async () => {
        global.pointer = [box.x + 10, box.y + 10];
        await spin(450);
    });
    await step('left', async () => {
        global.pointer = [0, 0];
        box.hover = false;
        box.emit('notify::hover');
        await spin(450);
    });
    await step('overview', () => {
        Main.overview.visible = true;
        Main.overview.emit('showing');
    });
    await step('no-overview', () => {
        Main.overview.visible = false;
        Main.overview.emit('hidden');
    });
    await step('intellihide=false', async () => {
        settings.set_boolean('dock-intellihide', false);
        await spin(50);
    });
    await step('intellihide=true', async () => {
        settings.reset('dock-intellihide');
        await spin(50);
    });
    await step('closed', () => {
        windows.pop();
        global.display.emit('restacked');
    });
    windows.push(win);
    global.display.emit('restacked');
    await step('layer-enabled=false', async () => {
        settings.set_boolean('layer-enabled', false);
        await spin(200);
    });
    fact('intellihide.after-off', `pressure-destroyed=${pressure.destroyed} barrier-destroyed=${barrier.destroyed ?? false}`);
    windows.pop();
}

async function switchLayer() {
    const cycles = Number(GLib.getenv('PROBE_SWITCH') ?? '0');
    for (let cycle = 1; cycle <= cycles; cycle++) {
        for (const on of [false, true]) {
            settings.set_boolean('layer-enabled', on);
            // eslint-disable-next-line no-await-in-loop
            await spin(200);
            fact(`switch.${cycle}.${on}`, `safe=${Hooks.safe()} ` +
                `scheme=${Hooks.value('session-mode', {...stock}, 'user').colorScheme} ` +
                `witness=${Hooks.value('test-witness', 'stock')}`);
        }
    }
}
for (const mode of ['user', 'unlock-dialog', 'gdm', 'initial-setup']) {
    const params = Hooks.value('session-mode', {...stock}, mode);
    fact(`scheme.${mode}`, `${params.colorScheme}${params.hasOverview ? '' : ' (params lost)'}`);
}
fact('test-fault', Hooks.value('test-fault', 'stock'));
fact('test-witness', Hooks.value('test-witness', 'stock'));

Hooks.provide('probe', 'boom', () => {
    throw new Error('boom');
});
fact('boom', `${Hooks.value('boom', 'stock')},${Hooks.value('boom', 'stock')}`);
fact('run-without-provider', Hooks.run('nothing'));

globalThis.PROBE_FAVOURITES = ['Files', 'Web'];
if (layer && GLib.getenv('PROBE_ENABLE') === '1') {
    if (GLib.getenv('PROBE_LOCKED') === '1')
        (await import(`file://${shellDir}/js/ui/main.js`)).sessionMode.isLocked = true;
    layer.enable();
    const marker = GLib.build_filenamev([GLib.get_user_runtime_dir(), 'apex-shell-starting']);
    fact('starting-file', GLib.file_test(marker, GLib.FileTest.EXISTS));
    fact('test-fault.after-enable', Hooks.value('test-fault', 'stock'));
    fact('test-witness.after-enable', Hooks.value('test-witness', 'stock'));
    fact('scheme.user.after-enable', Hooks.value('session-mode', {...stock}, 'user').colorScheme);
    const waitSeconds = Number(GLib.getenv('PROBE_WAIT') ?? '0');
    if (waitSeconds > 0) {
        const loop = new GLib.MainLoop(null, false);
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, waitSeconds, () => {
            loop.quit();
            return GLib.SOURCE_REMOVE;
        });
        loop.run();
        fact('survived', `${waitSeconds}s`);
    }
    mainModule = await import(`file://${shellDir}/js/ui/main.js`);
    await pressToggleSpotlight();
    overviewSearchWithoutSpotlight();
    await exerciseLock();
    await exercisePolkit();
    await exerciseMotion();
    await exerciseQuickSettings();
    await exerciseNotifications();
    await exerciseEndSession();
    await exerciseShadows();
    await exerciseSpotlight();
    await exerciseLauncher();
    await exerciseTopBar();
    await exerciseSolidBar();
    await exerciseFocusedApp();
    await exerciseSearchButton();
    await exerciseMaximisedWindow();
    await exerciseOverview();
    await exerciseDock();
    await exerciseIntellihide();
    await exerciseGlass();
    await exerciseIndicators();
    await exerciseRemoteWatcher();
    await setDisabledLive();
    await switchLayer();
    for (const [signal, fn] of [...handlers.values()]) {
        if (signal === 'shutdown')
            fn();
    }
    fact('starting-file.after-shutdown', GLib.file_test(marker, GLib.FileTest.EXISTS));
    if (settings.settings_schema.has_key('search-hint-shown'))
        fact('search-hint-shown', settings.get_boolean('search-hint-shown'));
}
if (!layer && settings)
    await switchLayer();
if (!layer) {
    await exerciseLock();
    await exercisePolkit();
}
if (GLib.getenv('PROBE_WATCHER_OWNER') === '1') {
    const bus = Gio.DBus.session;
    fact('watcher-owner', Sni.watcherOwner(bus) === bus.get_unique_name() ? 'shell' : Sni.watcherOwner(bus));
}
fact('done', 'yes');
