// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for shoot.sh: the lock screen, the greeter, the date menu or the
// end-session dialog's update card, captured and described.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import PolkitAgent from 'gi://PolkitAgent';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');
Gio._promisify(Gio.DBusConnection.prototype, 'call');
Gio._promisify(Gio.DBusProxy, 'new_for_bus');

const SETTLE_MS = 4000;
const STEP_MS = 1500;
const KEY_MS = 15;
const WRONG_ANSWER = 'not-the-password';
const POWER_SAVE_ON = 0;
const POWER_SAVE_OFF = 3;
// gnome-session's PresenceStatus.IDLE.
const PRESENCE_IDLE = 3;

const POINTER_NUDGE = 4;

// Board 13's request; tests/shell/apex-test.policy describes the action for polkitd.
const POLKIT_ACTION = 'io.github.apex-linux.apex.update.rollback';
const POLKIT_MESSAGE = 'Booting the previous version of Apex at the next restart needs an administrator password.';
const PAM_FPRINTD_PROMPT = 'Place your finger on the fingerprint reader';

let keyboard;
let pointer;

function fact(name, value) {
    console.log(`APEXLOCK ${JSON.stringify({[name]: value})}`);
    // gdm-mock.py's log then shows its calls and signals between the probe's steps.
    Gio.DBus.system.call('org.gnome.DisplayManager', '/org/gnome/DisplayManager/Manager', 'io.github.apex_linux.GdmMock',
        'Mark', new GLib.Variant('(s)', [name]), null, Gio.DBusCallFlags.NONE, -1, null, null);
}

function tap(keyval) {
    const now = () => GLib.get_monotonic_time();
    keyboard.notify_keyval(now(), keyval, Clutter.KeyState.PRESSED);
    keyboard.notify_keyval(now(), keyval, Clutter.KeyState.RELEASED);
}

async function type(text) {
    for (const ch of text) {
        tap(Clutter.unicode_to_keysym(ch.codePointAt(0)));
        await Scripting.sleep(KEY_MS);
    }
    tap(Clutter.KEY_Return);
}

// A banner over a scene is a race; signoff.sh fails the board that caught one.
function bannerShown() {
    const tray = Main.messageTray;
    return tray._banner?.mapped ? {source: tray._notification?.source?.title ?? null, title: tray._notification?.title ?? null} : null;
}

function bluetoothShown() {
    return Main.panel.statusArea.quickSettings?._bluetooth?._indicator?.visible ?? false;
}

async function capture(name) {
    const path = GLib.build_filenamev([GLib.getenv('APEX_SHOTS'), `${GLib.getenv('APEX_SHOT')}-${name}.png`]);
    const stream = Gio.File.new_for_path(path).replace(null, false, Gio.FileCreateFlags.NONE, null);
    try {
        await new Shell.Screenshot().screenshot_area(0, 0, global.stage.width, global.stage.height, stream);
    } finally {
        stream.close(null);
    }
    fact(`capture.${name}`, path);
    fact(`banner.${name}`, bannerShown());
    fact(`bluetooth.${name}`, bluetoothShown());
}

// What gnome-settings-daemon's power plugin sets on idle. Not call_sync: the shell is DisplayConfig.
function setPowerSaveMode(mode) {
    return Gio.DBus.session.call('org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig',
        'org.freedesktop.DBus.Properties', 'Set',
        new GLib.Variant('(ssv)', ['org.gnome.Mutter.DisplayConfig', 'PowerSaveMode', new GLib.Variant('i', mode)]),
        null, Gio.DBusCallFlags.NONE, -1, null);
}

function describePrompt(prompt) {
    if (!prompt)
        return null;
    const user = prompt._userWell.get_child();
    const avatar = user?._avatar?.child;
    return {
        question: prompt._entry?.hint_text ?? null,
        message: prompt._message?.text ?? null,
        messageShown: Boolean(prompt._message?.visible && prompt._message.opacity > 0 && prompt._message.text),
        name: user?._label?._currentLabel?.text ?? user?._label?.text ?? null,
        avatar: avatar instanceof St.Label ? `initial ${avatar.text}` : avatar?.icon_name ?? null,
    };
}

function describeLock(dialog) {
    const clock = dialog._clock;
    const line = dialog._promptBox?.get_children().find(c => c.has_style_class_name?.('apex-lock-hint-line'));
    const hint = line?.get_children().find(c => c.has_style_class_name?.('apex-lock-hint'));
    const glyph = line?.get_children().find(c => c.has_style_class_name?.('apex-lock-hint-glyph'));
    return {
        locked: Main.screenShield.locked,
        classes: dialog.style_class,
        clock: clock.get_children().filter(c => c.visible).map(c => c.style_class).join(' '),
        date: clock._date.text,
        time: clock._time.text,
        hint: hint?.text ?? null,
        hintGlyph: glyph?.visible ? glyph.icon_name : null,
        hintFailed: line?.has_style_class_name('apex-lock-hint-failed') ?? null,
        indicator: dialog._authIndicatorButton?.visible ?? null,
        blur: dialog._backgroundGroup.get_children().map(b => b.get_effect('blur'))
            .map(e => e && `radius=${e.radius} brightness=${e.brightness.toFixed(2)} saturation=${e.saturation.toFixed(2)}`)[0] ?? null,
        prompt: describePrompt(dialog._authPrompt),
        layout: describeLayout(dialog, hint),
    };
}

// What the eye reads, top to bottom, in logical pixels; only what is on screen.
function describeLayout(dialog, hint) {
    const prompt = dialog._authPrompt;
    const parts = {
        date: dialog._clock._date, time: dialog._clock._time, avatar: prompt?._userWell,
        field: prompt?._entry, message: prompt?._message?.text ? prompt._message : null, hint,
    };
    const overlay = dialog.get_children().find(c => c.has_style_class_name?.('apex-lock-overlay'));
    const layout = {screen: box(dialog), overlay: overlay ? color(overlay.get_theme_node().get_background_color()) : null};
    for (const [name, actor] of Object.entries(parts)) {
        if (actor?.mapped && actor.opacity > 0)
            layout[name] = box(actor);
    }
    layout.reveal = describeReveal(prompt?._entry);
    return layout;
}

// Board 20's show-password eye: the glyph, inside the icon's own padding, against the entry's border and end padding.
function describeReveal(entry) {
    const icon = entry?.get_secondary_icon?.();
    if (!icon?.mapped)
        return null;
    const node = entry.get_theme_node();
    const end = entry.get_text_direction() === Clutter.TextDirection.RTL ? St.Side.LEFT : St.Side.RIGHT;
    return {
        entry: box(entry), icon: box(icon), iconPadding: icon.get_theme_node().get_padding(end) / scale(),
        border: node.get_border_width(end) / scale(), padding: node.get_padding(end) / scale(),
    };
}

// gdm-mock.py's test method: pam_fprintd's "no match" in every live fingerprint conversation.
function failScan() {
    return Gio.DBus.system.call('org.gnome.DisplayManager', '/org/gnome/DisplayManager/Manager',
        'io.github.apex_linux.GdmMock', 'FailScan', null, null, Gio.DBusCallFlags.NONE, -1, null);
}

async function shootFingerprint(dialog) {
    fact('opened', describeLock(dialog));
    await capture('open');
    await failScan();
    await Scripting.sleep(STEP_MS * 2);
    fact('scan-failed', describeLock(dialog));
    await capture('scan-failed');
    await setPowerSaveMode(POWER_SAVE_OFF);
    await Scripting.sleep(STEP_MS);
    fact('blank', describeLock(dialog));
    await Scripting.sleep(STEP_MS * 2);
    fact('still-blank', describeLock(dialog));
    await setPowerSaveMode(POWER_SAVE_ON);
    await Scripting.sleep(STEP_MS * 2);
    fact('wake', describeLock(dialog));
    await Scripting.sleep(SETTLE_MS);
    fact('end', {locked: Main.screenShield.locked});
}

// logind's PrepareForSleep, from its mock: upstream cancels the dialog's conversation before sleep,
// and the lock's prompt has to come back at resume with no key.
function prepareForSleep(aboutToSuspend) {
    return Gio.DBus.system.call('org.freedesktop.login1', '/org/freedesktop/login1', 'org.freedesktop.DBus.Mock',
        'EmitSignal', new GLib.Variant('(sssav)', ['org.freedesktop.login1.Manager', 'PrepareForSleep', 'b',
            [new GLib.Variant('b', aboutToSuspend)]]), null, Gio.DBusCallFlags.NONE, -1, null);
}

async function shootSuspend() {
    Main.screenShield.lock(false);
    await Scripting.sleep(STEP_MS);
    const dialog = Main.screenShield._dialog;
    const describe = () => ({...describeLock(dialog), status: dialog._authPrompt?.verificationStatus ?? null});
    fact('locked', describe());
    await prepareForSleep(true);
    await Scripting.sleep(STEP_MS);
    fact('asleep', describe());
    await Scripting.sleep(STEP_MS);
    fact('still-asleep', describe());
    await prepareForSleep(false);
    await Scripting.sleep(STEP_MS * 2);
    fact('resumed', describe());
    await Scripting.sleep(SETTLE_MS);
    fact('end', {locked: Main.screenShield.locked});
}

// apex-image's local-lock-blank-wake: gnome-session goes idle at every real lock, and upstream's
// ScreenShield answers that by cancelling the dialog; then the screen blanks and wakes, no key.
async function shootIdleLock() {
    Gio.bus_own_name_on_connection(Gio.DBus.session, 'org.gnome.SessionManager', Gio.BusNameOwnerFlags.NONE, null, null);
    Main.screenShield.lock(false);
    await Scripting.sleep(STEP_MS);
    const dialog = Main.screenShield._dialog;
    const describe = () => ({...describeLock(dialog), status: dialog._authPrompt?.verificationStatus ?? null});
    fact('locked', describe());
    Gio.DBus.session.emit_signal(null, '/org/gnome/SessionManager/Presence', 'org.gnome.SessionManager.Presence',
        'StatusChanged', new GLib.Variant('(u)', [PRESENCE_IDLE]));
    await Scripting.sleep(STEP_MS);
    fact('idle', describe());
    await setPowerSaveMode(POWER_SAVE_OFF);
    await Scripting.sleep(STEP_MS);
    fact('blank', describe());
    await setPowerSaveMode(POWER_SAVE_ON);
    await Scripting.sleep(STEP_MS * 2);
    fact('woken', describe());
    await Scripting.sleep(SETTLE_MS);
    fact('end', {locked: Main.screenShield.locked});
}

// apex-image's local-lock-esc on a guest that blanks at lock, and the key that wakes it arriving
// after the wake's notify, as it did there: on upstream's clock page after Esc, or locked while blank.
async function shootWakeKey(lockedBlank) {
    if (lockedBlank)
        await setPowerSaveMode(POWER_SAVE_OFF);
    Main.screenShield.lock(false);
    await Scripting.sleep(STEP_MS);
    const dialog = Main.screenShield._dialog;
    const describe = () => ({...describeLock(dialog), status: dialog._authPrompt?.verificationStatus ?? null});
    if (!lockedBlank) {
        tap(Clutter.KEY_Escape);
        await Scripting.sleep(STEP_MS);
        await setPowerSaveMode(POWER_SAVE_OFF);
        await Scripting.sleep(STEP_MS);
    }
    fact('blank', describe());
    const displayConfig = await Gio.DBusProxy.new_for_bus(Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, null,
        'org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig', 'org.gnome.Mutter.DisplayConfig', null);
    const id = displayConfig.connect('g-properties-changed', (_proxy, changed) => {
        if (changed.lookup_value('PowerSaveMode', null)?.unpack() !== POWER_SAVE_ON)
            return;
        displayConfig.disconnect(id);
        tap(Clutter.KEY_Return);
    });
    await setPowerSaveMode(POWER_SAVE_ON);
    await Scripting.sleep(STEP_MS * 2);
    fact('woken', describe());
    await Scripting.sleep(SETTLE_MS);
    fact('end', {locked: Main.screenShield.locked});
}

// Locking fades to black, as before the screen blanks; activity lifts it. A move does not
// open upstream's prompt, so its lock keeps two stages.
async function shootLock() {
    Main.screenShield.lock(false);
    await Scripting.sleep(STEP_MS);
    pointer.notify_relative_motion(GLib.get_monotonic_time(), POINTER_NUDGE, POINTER_NUDGE);
    await Scripting.sleep(SETTLE_MS);
    if (GLib.getenv('APEX_FINGERPRINT') === '1') {
        await shootFingerprint(Main.screenShield._dialog);
        return;
    }
    const dialog = Main.screenShield._dialog;
    fact('opened', describeLock(dialog));
    await capture('open');

    await type(WRONG_ANSWER);
    await Scripting.sleep(STEP_MS * 2);
    fact('wrong-answer', describeLock(dialog));

    await setPowerSaveMode(POWER_SAVE_OFF);
    await Scripting.sleep(STEP_MS);
    fact('blank', describeLock(dialog));
    await setPowerSaveMode(POWER_SAVE_ON);
    await Scripting.sleep(STEP_MS * 2);
    fact('wake', describeLock(dialog));

    tap(Clutter.KEY_Escape);
    await Scripting.sleep(STEP_MS * 2);
    fact('escape', describeLock(dialog));
    tap(Clutter.KEY_Return);
    await Scripting.sleep(STEP_MS * 2);
    fact('key-after-escape', describeLock(dialog));
    await Scripting.sleep(SETTLE_MS);
    fact('end', {locked: Main.screenShield.locked});
}

// What polkit-agent-helper-1 would send, without the helper: PAM never runs, so nothing the
// dialog does can authorise. Its answers are only counted.
function stubSession(sessions, info) {
    return GObject.registerClass({
        Properties: {
            'identity': GObject.ParamSpec.object('identity', null, null,
                GObject.ParamFlags.READWRITE | GObject.ParamFlags.CONSTRUCT_ONLY, GObject.Object),
            'cookie': GObject.ParamSpec.string('cookie', null, null,
                GObject.ParamFlags.READWRITE | GObject.ParamFlags.CONSTRUCT_ONLY, null),
        },
        Signals: {
            'completed': {param_types: [GObject.TYPE_BOOLEAN]},
            'request': {param_types: [GObject.TYPE_STRING, GObject.TYPE_BOOLEAN]},
            'show-error': {param_types: [GObject.TYPE_STRING]},
            'show-info': {param_types: [GObject.TYPE_STRING]},
        },
    }, class StubSession extends GObject.Object {
        initiate() {
            sessions.push({responses: 0, cancelled: false});
            GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                if (info)
                    this.emit('show-info', info);
                this.emit('request', 'Password:', false);
                return GLib.SOURCE_REMOVE;
            });
        }

        response() {
            sessions.at(-1).responses++;
        }

        cancel() {
            sessions.at(-1).cancelled = true;
        }
    });
}

function visibleText(actor) {
    return actor?.mapped && actor.opacity > 0 ? actor.text : null;
}

function describePolkit(dialog) {
    const content = dialog.contentLayout;
    const find = name => content.get_children().find(c => c.has_style_class_name?.(name));
    const shield = find('apex-polkit-icon');
    const header = content.get_children().find(c => c.has_style_class_name?.('message-dialog-content'));
    const role = dialog._userLabel.get_parent()?.get_children().find(c => c.has_style_class_name?.('apex-polkit-role'));
    const info = dialog._infoMessageLabel;
    const line = info.get_parent();
    const details = find('apex-polkit-details');
    const grid = details?.get_children()[1];
    return {
        opened: dialog.state === ModalDialog.State.OPENED,
        classes: dialog.style_class,
        box: box(dialog.dialogLayout._dialog),
        shield: shield ? {...box(shield), icon: shield.child.icon_name, background: color(shield.get_theme_node().get_background_color())} : null,
        title: header?.title ?? null,
        description: header?.description ?? null,
        avatar: box(dialog._userAvatar),
        initial: dialog._userAvatar.child instanceof St.Label ? dialog._userAvatar.child.text : null,
        name: {...box(dialog._userLabel), text: visibleText(dialog._userLabel)},
        role: role ? {...box(role), text: visibleText(role)} : null,
        field: {
            ...box(dialog._passwordEntry), hint: dialog._passwordEntry.hint_text,
            focused: [dialog._passwordEntry, dialog._passwordEntry.clutter_text].includes(global.stage.key_focus),
            focus: global.stage.key_focus?.constructor.name ?? null,
        },
        info: {text: visibleText(info), line: line.style_class, glyph: line.get_children().find(c => c instanceof St.Icon && c.visible)?.icon_name ?? null},
        details: details ? {
            ...box(details),
            open: grid.visible,
            rows: grid.get_children().filter(r => r.visible).map(r => r.get_children().map(c => c.text)),
        } : null,
        buttons: [dialog._cancelButton, dialog._okButton].map(b => ({...button(b), label: b.label})),
    };
}

async function openPolkit() {
    await Scripting.sleep(SETTLE_MS);
    Main.overview.hide();
    await Scripting.sleep(STEP_MS);
    const sessions = [];
    PolkitAgent.Session = stubSession(sessions, GLib.getenv('APEX_POLKIT_INFO') === 'fingerprint' ? PAM_FPRINTD_PROMPT : null);
    const agent = Main.componentManager._allComponents.polkitAgent;
    agent._onInitiate(agent, POLKIT_ACTION, POLKIT_MESSAGE, '', 'apex-shell-test', [GLib.getenv('APEX_USER')]);
    await Scripting.sleep(SETTLE_MS);
    return {agent, dialog: agent._currentDialog, sessions};
}

async function shootPolkit() {
    const {dialog, sessions} = await openPolkit();
    fact('polkit', describePolkit(dialog));
    await capture('open');
    fact('polkit-sessions', sessions);
}

// Board 13's dialog with the screen locking, or the machine sleeping, under it: upstream hides it
// while locked and keeps its request. deactivate() stands in for GDM's success, which gdm-mock never gives.
async function shootPolkitLocked(sleeps) {
    const {agent, dialog, sessions} = await openPolkit();
    const describe = () => ({
        polkit: {...describePolkit(dialog), visible: dialog.visible, mapped: dialog.mapped, current: agent._currentDialog === dialog},
        sessions, locked: Main.screenShield.locked,
    });
    fact('polkit', describe());
    if (sleeps) {
        await prepareForSleep(true);
        await Scripting.sleep(STEP_MS);
        fact('asleep', describe());
        await prepareForSleep(false);
        await Scripting.sleep(STEP_MS * 2);
    } else {
        Main.screenShield.lock(false);
        await Scripting.sleep(STEP_MS * 2);
    }
    const lock = () => Main.screenShield._dialog;
    fact('locked', {...describe(), lock: describeLock(lock())});
    await type(WRONG_ANSWER);
    await Scripting.sleep(STEP_MS * 2);
    fact('typed', {...describe(), lock: describeLock(lock())});
    Main.screenShield.deactivate(false);
    await Scripting.sleep(SETTLE_MS);
    fact('unlocked', describe());
}

function scale() {
    return St.ThemeContext.get_for_stage(global.stage).scale_factor;
}

function box(actor) {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    return {x: x / scale(), y: y / scale(), width: width / scale(), height: height / scale()};
}

function color(c) {
    return `#${[c.red, c.green, c.blue, c.alpha].map(v => v.toString(16).padStart(2, '0')).join('')}`;
}

// Board 12's background, footer and bottom buttons, as the theme and the dialog give them.
function describeGreeterStyle(dialog) {
    const node = dialog.get_theme_node();
    const buttons = dialog._bottomButtonGroup.get_children();
    return {
        screen: box(dialog),
        background: {color: color(node.get_background_color()), image: node.get_background_image()?.get_uri() ?? null},
        logo: dialog._logoBin.visible && dialog._logoBin.get_n_children() > 0
            ? {file: dialog._logoFile?.get_path() ?? null, ...box(dialog._logoBin.get_first_child())} : null,
        buttons: buttons.filter(b => b.visible).map(button),
        back: dialog._authPrompt?.cancelButton.mapped ? button(dialog._authPrompt.cancelButton) : null,
    };
}

function button(b) {
    const n = b.get_theme_node();
    return {
        ...box(b), radius: n.get_border_radius(St.Corner.TOPLEFT) / scale(), background: color(n.get_background_color()),
        border: n.get_border_width(St.Side.TOP) / scale(), borderColor: color(n.get_border_color(St.Side.TOP)),
    };
}

function describeGreeter(dialog) {
    const items = [...dialog._userList._items.values()];
    return {
        users: items.map(i => i.user.get_user_name()).join(' '),
        prompt: describePrompt(dialog._authPrompt?.visible ? dialog._authPrompt : null),
        style: describeGreeterStyle(dialog),
    };
}

async function shootGreeter() {
    await Scripting.sleep(SETTLE_MS);
    const dialog = Main.screenShield._dialog;
    // The dialog shows its list on startup-complete, which the automation script can precede.
    const missedStartup = dialog._disableUserList === undefined;
    fact('missed-startup-complete', missedStartup);
    if (missedStartup) {
        dialog._updateDisableUserList();
        await Scripting.sleep(SETTLE_MS);
    }
    fact('list', describeGreeter(dialog));
    await capture('list');
    dialog._userList.getItemFromUserName(GLib.getenv('APEX_USER')).emit('activate');
    await Scripting.sleep(SETTLE_MS);
    fact('prompt', describeGreeter(dialog));
    await capture('prompt');
}

const UPDATE1 = ['io.github.apex_linux.Apex.Update1', '/io/github/apex_linux/Apex/Update1'];
const END_SESSION = ['/org/gnome/SessionManager/EndSessionDialog', 'org.gnome.SessionManager.EndSessionDialog'];
const DIALOG_TYPE = {logout: 0, powerOff: 1, restart: 2};
const STAGED_DIGEST = 'sha256:9e41aa07c3b2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c80c2b';
const STAGED = {
    digest: new GLib.Variant('s', STAGED_DIGEST),
    version: new GLib.Variant('s', '45.20261010.133'),
    'download-only': new GLib.Variant('b', true),
};
const POLICY_DENIED = 'Plug in the charger to install the update.';
const COUNTDOWN_SECONDS = 3;
// gnome-shell-perf-helper exits after 30 s idle, and the end-session run is longer.
const PERF_HELPER_PING_S = 10;

// update1-mock.py through python-dbusmock's own interface.
function mock(method, params) {
    return Gio.DBus.system.call(...UPDATE1, 'org.freedesktop.DBus.Mock', method, params, null,
        Gio.DBusCallFlags.NONE, -1, null);
}

function setUpdate(state, staged = {}) {
    return mock('UpdateProperties', new GLib.Variant('(sa{sv})', [UPDATE1[0], {
        State: new GLib.Variant('s', state), Staged: new GLib.Variant('a{sv}', staged),
    }]));
}

function setApply(code) {
    return mock('AddMethod', new GLib.Variant('(sssss)', [UPDATE1[0], 'Apply', 's', '', code]));
}

async function applyCalls() {
    const [calls] = (await mock('GetMethodCalls', new GLib.Variant('(s)', ['Apply']))).deepUnpack();
    await mock('ClearCalls', null);
    return calls.map(([, args]) => args.map(a => a.unpack()).join(','));
}

function endSessionDialog() {
    return Main.layoutManager.modalDialogGroup.get_children().find(d => d.constructor.name === 'EndSessionDialog');
}

function describeEndSession(dialog) {
    const card = dialog?.contentLayout.get_children().find(c => c.has_style_class_name?.('apex-update-card'));
    const labels = card?.get_children()[1].get_children();
    return {
        open: dialog?.state === 0,
        buttons: dialog?.buttonLayout.get_children().filter(b => b.visible).map(b => b.label) ?? [],
        otherSessions: dialog?._sessionSection.visible ? dialog._sessionSection.list.get_n_children() : 0,
        card: card ? {
            title: labels[0].text, subtitle: labels[1].text, on: card.switch.state,
            sensitive: card.get_children()[2].reactive, icon: card.get_children()[0].icon_name,
        } : null,
    };
}

// Opens the dialog as gnome-session does, then records what it confirms.
async function openEndSession(type, seconds = 60) {
    await Gio.DBus.session.call('org.gnome.Shell', ...END_SESSION, 'Open',
        new GLib.Variant('(uuuao)', [type, 0, seconds, []]), null, Gio.DBusCallFlags.NONE, -1, null);
    await Scripting.sleep(STEP_MS);
    const dialog = endSessionDialog();
    dialog.confirmed = [];
    // The dialog is the shell's one EndSessionDialog: its signals are recorded once.
    if (!dialog.recording) {
        const emit = dialog._dbusImpl.emit_signal;
        dialog._dbusImpl.emit_signal = (signal, params) => {
            dialog.confirmed.push(signal);
            emit.call(dialog._dbusImpl, signal, params);
        };
        dialog.recording = true;
    }
    return dialog;
}

async function press(dialog, label) {
    dialog.buttonLayout.get_children().find(b => b.label === label).emit('clicked', Clutter.BUTTON_PRIMARY);
    await Scripting.sleep(STEP_MS * 2);
}

async function endSessionStep(name, dialog) {
    fact(name, {...describeEndSession(dialog), signals: dialog.confirmed.splice(0), apply: await applyCalls()});
}

function keepPerfHelperAwake() {
    return GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, PERF_HELPER_PING_S, () => {
        Scripting._getPerfHelper().then(helper => helper.DestroyWindowsAsync()).catch(() => {});
        return GLib.SOURCE_CONTINUE;
    });
}

async function shootEndSession() {
    const pingId = keepPerfHelperAwake();
    try {
        await shootEndSessionCases();
    } finally {
        GLib.source_remove(pingId);
    }
}

async function shootEndSessionCases() {
    await Scripting.sleep(SETTLE_MS);
    let dialog = await openEndSession(DIALOG_TYPE.powerOff);
    await endSessionStep('up-to-date', dialog);
    await press(dialog, 'Cancel');

    await setUpdate('staged', STAGED);
    dialog = await openEndSession(DIALOG_TYPE.logout);
    await endSessionStep('logout', dialog);
    await press(dialog, 'Cancel');

    dialog = await openEndSession(DIALOG_TYPE.restart);
    await endSessionStep('staged', dialog);
    await capture('staged');
    await press(dialog, 'Restart & Update');
    await endSessionStep('staged-pressed', dialog);

    dialog = await openEndSession(DIALOG_TYPE.powerOff);
    // Board 14 for the owner's sign-off (tests/shots/signoff.sh): power off, an update staged.
    await capture('power-off');
    dialog.contentLayout.get_children().find(c => c.has_style_class_name?.('apex-update-card'))
        .get_children()[2].emit('clicked', Clutter.BUTTON_PRIMARY);
    await Scripting.sleep(STEP_MS);
    await endSessionStep('switched-off', dialog);
    await press(dialog, 'Power Off');
    await endSessionStep('switched-off-pressed', dialog);

    await setUpdate('ready-for-reboot', STAGED);
    dialog = await openEndSession(DIALOG_TYPE.restart);
    await endSessionStep('ready', dialog);
    await capture('ready');
    await press(dialog, 'Restart & Update');
    await endSessionStep('ready-pressed', dialog);

    await setUpdate('staged', STAGED);
    await setApply(`raise dbus.exceptions.DBusException(${JSON.stringify(POLICY_DENIED)}, ` +
        "name='io.github.apex_linux.Apex.Update1.Error.PolicyDenied')");
    dialog = await openEndSession(DIALOG_TYPE.powerOff);
    await press(dialog, 'Power Off');
    await endSessionStep('apply-failed', dialog);
    await capture('apply-failed');
    await press(dialog, 'Cancel');
    await endSessionStep('apply-failed-cancelled', dialog);

    dialog = await openEndSession(DIALOG_TYPE.restart, COUNTDOWN_SECONDS);
    await Scripting.sleep((COUNTDOWN_SECONDS + 3) * 1000);
    await endSessionStep('countdown-failed', dialog);
}

// Board 34's notification list, from fdo Notify calls to the shell's own notification daemon.
const NOTIFICATIONS = [
    ['Settings', 'preferences-system-symbolic', 'Update ready', 'Apex 45.20261024.141 starts after the next restart.'],
    ['Calendar', 'x-office-calendar-symbolic', 'Design review at 14:00', 'Canvas boards 34 to 36, in 15 minutes.'],
    ['Terminal', 'utilities-terminal-symbolic', 'Command finished', 'just vm-image exited 0 after 18 min in apex-image.'],
    ['Terminal', 'utilities-terminal-symbolic', 'Command failed', 'just lint exited 1 in apex-gnome.'],
    ['Files', 'folder-symbolic', 'Copied 4 items', 'To Projects.'],
];

function notify([app, icon, title, body]) {
    return Gio.DBus.session.call('org.freedesktop.Notifications', '/org/freedesktop/Notifications',
        'org.freedesktop.Notifications', 'Notify',
        new GLib.Variant('(susssasa{sv}i)', [app, 0, icon, title, body, [], {}, -1]),
        null, Gio.DBusCallFlags.NONE, -1, null);
}

function describeCard(message) {
    const [glyph, content] = message._header.get_children();
    const line = content.get_children().filter(c => c instanceof St.Label && c.visible).map(c => c.text).join(' ');
    return {
        title: message.titleLabel.text, glyph: glyph.visible, line,
        icon: message._icon.visible
            ? {...box(message._icon), size: message._icon.get_theme_node().get_length('icon-size')} : null,
        header: box(content), text: box(message.titleLabel), card: box(message),
    };
}

function describeDateMenu(list) {
    const view = list._messageView;
    const controls = list._clearButton.get_parent();
    const dnd = controls.get_children().find(c => c.has_style_class_name('apex-dnd-button'));
    const groups = view.get_children().map(item => item.child ?? item)
        .filter(g => g?._notificationToMessage);
    return {
        empty: list._placeholder.visible,
        footer: {...box(controls), children: controls.get_children().map(c => c.style_class)},
        clear: {...box(list._clearButton), visible: list._clearButton.visible, reactive: list._clearButton.reactive},
        dnd: dnd ? {checked: dnd.checked, label: dnd.accessible_name, ...box(dnd)} : null,
        banners: new Gio.Settings({schema_id: 'org.gnome.desktop.notifications'}).get_boolean('show-banners'),
        groups: groups.map(g => ({
            app: g.source.title, expanded: g.expanded, header: g._headerBox.visible,
            cards: [...g._notificationToMessage.values()].map(describeCard),
        })),
    };
}

async function click(actor) {
    // The virtual pointer moves in the layout's logical pixels.
    const {x, y, width, height} = box(actor);
    const now = () => GLib.get_monotonic_time();
    // The seat drops the first motion's x: the pointer moves twice.
    for (let i = 0; i < 2; i++) {
        pointer.notify_absolute_motion(now(), x + width / 2, y + height / 2);
        await Scripting.sleep(KEY_MS * 4); // eslint-disable-line no-await-in-loop
    }
    pointer.notify_button(now(), Clutter.BUTTON_PRIMARY, Clutter.ButtonState.PRESSED);
    pointer.notify_button(now(), Clutter.BUTTON_PRIMARY, Clutter.ButtonState.RELEASED);
    await Scripting.sleep(STEP_MS);
}

async function shootDateMenu() {
    await Scripting.sleep(SETTLE_MS);
    const {dateMenu} = Main.panel.statusArea;
    const list = dateMenu._messageList;
    // The session's own notifications (the search hint) would only blur the counts.
    Main.messageTray.getSources().forEach(source => source.destroy());
    dateMenu.menu.open();
    await Scripting.sleep(STEP_MS);
    fact('none', describeDateMenu(list));
    await capture('none');
    await notify(NOTIFICATIONS[0]);
    await Scripting.sleep(STEP_MS);
    fact('one', describeDateMenu(list));
    for (const n of NOTIFICATIONS.slice(1))
        await notify(n);  // eslint-disable-line no-await-in-loop
    await Scripting.sleep(STEP_MS);
    fact('many', describeDateMenu(list));
    await capture('many');
    const dnd = list._clearButton.get_parent().get_children().find(c => c.has_style_class_name('apex-dnd-button'));
    if (dnd) {
        await click(dnd);
        fact('dnd-clicked', describeDateMenu(list));
        await click(dnd);
        fact('dnd-clicked-again', describeDateMenu(list));
    }
    // A new stylesheet closes the menu.
    new Gio.Settings({schema_id: 'org.gnome.desktop.interface'}).set_string('color-scheme', 'prefer-dark');
    await Scripting.sleep(SETTLE_MS);
    dateMenu.menu.open();
    await Scripting.sleep(STEP_MS);
    await capture('many-dark');
    await click(list._clearButton);
    await Scripting.sleep(STEP_MS);
    fact('cleared', describeDateMenu(list));
    await capture('cleared');
}

// main.js connects to startup-complete only after importing this module, so a startup that
// completes during the import would never run the script and leave the shell up.
export function init() {
    if (Main.layoutManager._startingUp)
        return;
    console.log('APEXLOCK-LATE startup completed while main.js imported the probe');
    import(import.meta.url).then(self => Scripting.runPerfScript(self, GLib.getenv('SHELL_PERF_OUTPUT')));
}

export async function run() {
    try {
        const seat = global.stage.context.get_backend().get_default_seat();
        keyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        pointer = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
        if (Main.sessionMode.isGreeter)
            await shootGreeter();
        else if (GLib.getenv('APEX_POLKIT') === '1')
            await shootPolkit();
        else if (['lock', 'suspend'].includes(GLib.getenv('APEX_POLKIT')))
            await shootPolkitLocked(GLib.getenv('APEX_POLKIT') === 'suspend');
        else if (GLib.getenv('APEX_DATE_MENU') === '1')
            await shootDateMenu();
        else if (GLib.getenv('APEX_END_SESSION') === '1')
            await shootEndSession();
        else if (GLib.getenv('APEX_SUSPEND') === '1')
            await shootSuspend();
        else if (GLib.getenv('APEX_IDLE') === '1')
            await shootIdleLock();
        else if (GLib.getenv('APEX_WAKE_KEY'))
            await shootWakeKey(GLib.getenv('APEX_WAKE_KEY') === 'locked-blank');
        else
            await shootLock();
    } catch (e) {
        console.log(`APEXLOCK-ERROR ${e.message}\n${e.stack}`);
    }
}
