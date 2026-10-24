// SPDX-License-Identifier: GPL-3.0-or-later
//
// Facts go to stderr: it is unbuffered, so the facts before an abort survive.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

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
    if (disabled)
        settings.set_strv('disabled-features', disabled.split(','));
}

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
    if (mode === 'late-sum') {
        open();
        entry().set_text('2880 / 1.5');
        await spin(300);
        report('late-sum.at-300ms');
        await spin(600);
        report('late-sum.at-900ms');
        return;
    }

    open();
    report('opened');
    fact('spotlight.focus', entry().focused === true);
    await type('disk', 'disk');
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
    await spin(2300);
    fact('spotlight.toast-later', Toast.current() ? 'shown' : 'gone');

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

function pillNames(quickSettings) {
    return quickSettings._indicators.get_children().map(i => i.name).join(',');
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

async function exerciseTopBar() {
    if (GLib.getenv('PROBE_TOP_BAR') !== '1')
        return;
    const Main = await import(`file://${shellDir}/js/ui/main.js`);
    const {quickSettings} = Main.panel.statusArea;
    topBarHooks('top-bar');
    fact('pill', pillNames(quickSettings));
    const later = Main.newQuickSettings();
    Hooks.run('status-indicators', later);
    fact('pill.set-up-after-enable', pillNames(later));

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
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    fact('pill.on', pillNames(quickSettings));
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
    Object.assign(dialog, {
        _clock: clock, _promptBox: promptBox, _stack: stack, _authPrompt: null,
        _backgroundGroup: new St.Widget({name: 'backgrounds'}), conversations: 0, cancelled: [],
        _ensureAuthPrompt() {
            if (this._authPrompt)
                return;
            const prompt = new St.Widget({name: `conversation-${++this.conversations}`});
            prompt._userVerifier = {
                destroy() {
                    this.cancel();
                },
                cancel: () => this.cancelled.push(prompt.name),
            };
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
    const promptBoxChildren = () => dialog._promptBox.children.map(c => c.text ?? c.name).join(',');
    fact('lock.prompt-box', promptBoxChildren());
    for (const [label, mode] of [['blank', PowerSave.OFF], ['wake', PowerSave.ON],
        ['standby', PowerSave.STANDBY], ['wake-again', PowerSave.ON],
        ['suspend', PowerSave.SUSPEND], ['unsupported', PowerSave.UNSUPPORTED]]) {
        setScreen(mode);
        fact(`lock.${label}`, lockState(dialog));
    }
    fact('lock.prompt-box.after-wake', promptBoxChildren());
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
        `icon=${grid.layout_manager.fixed_icon_size}`);
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
    await exerciseLock();
    await exerciseMotion();
    await exerciseSpotlight();
    await exerciseTopBar();
    await exerciseSolidBar();
    await exerciseFocusedApp();
    await exerciseSearchButton();
    await exerciseMaximisedWindow();
    await exerciseOverview();
    await exerciseDock();
    await exerciseIntellihide();
    await exerciseGlass();
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
if (!layer)
    await exerciseLock();
fact('done', 'yes');
