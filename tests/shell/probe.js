// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for shoot.sh: the lock screen, the greeter or the end-session
// dialog's update card, captured and described.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');
Gio._promisify(Gio.DBusConnection.prototype, 'call');

const SETTLE_MS = 4000;
const STEP_MS = 1500;
const KEY_MS = 15;
const WRONG_ANSWER = 'not-the-password';
const POWER_SAVE_ON = 0;
const POWER_SAVE_OFF = 3;

const POINTER_NUDGE = 4;

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

async function capture(name) {
    const path = GLib.build_filenamev([GLib.getenv('APEX_SHOTS'), `${GLib.getenv('APEX_SHOT')}-${name}.png`]);
    const stream = Gio.File.new_for_path(path).replace(null, false, Gio.FileCreateFlags.NONE, null);
    try {
        await new Shell.Screenshot().screenshot_area(0, 0, global.stage.width, global.stage.height, stream);
    } finally {
        stream.close(null);
    }
    fact(`capture.${name}`, path);
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
    return layout;
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
    const emit = dialog._dbusImpl.emit_signal;
    dialog._dbusImpl.emit_signal = (signal, params) => {
        dialog.confirmed.push(signal);
        emit.call(dialog._dbusImpl, signal, params);
    };
    return dialog;
}

async function press(dialog, label) {
    dialog.buttonLayout.get_children().find(b => b.label === label).emit('clicked', Clutter.BUTTON_PRIMARY);
    await Scripting.sleep(STEP_MS * 2);
}

async function endSessionStep(name, dialog) {
    fact(name, {...describeEndSession(dialog), signals: dialog.confirmed.splice(0), apply: await applyCalls()});
}

async function shootEndSession() {
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
        if (GLib.getenv('APEX_END_SESSION') === '1')
            await shootEndSession();
        else
            await (Main.sessionMode.isGreeter ? shootGreeter() : shootLock());
    } catch (e) {
        console.log(`APEXLOCK-ERROR ${e.message}\n${e.stack}`);
    }
}
