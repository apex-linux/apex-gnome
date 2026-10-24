// SPDX-License-Identifier: GPL-3.0-or-later
// gnome-shell's automation script for shoot.sh: the lock screen, the greeter or the date menu, captured and
// described.

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
        name: user?._label?._currentLabel?.text ?? user?._label?.text ?? null,
        avatar: avatar instanceof St.Label ? `initial ${avatar.text}` : avatar?.icon_name ?? null,
    };
}

function describeLock(dialog) {
    const clock = dialog._clock;
    const hint = dialog._promptBox?.get_children().find(c => c.has_style_class_name?.('apex-lock-hint'));
    return {
        locked: Main.screenShield.locked,
        classes: dialog.style_class,
        clock: clock.get_children().filter(c => c.visible).map(c => c.style_class).join(' '),
        date: clock._date.text,
        time: clock._time.text,
        hint: hint?.text ?? null,
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

// Board 34's notification list, from fdo Notify calls to the shell's own notification daemon.
const NOTIFICATIONS = [
    ['Settings', 'Update ready', 'Apex 45.20261024.141 starts after the next restart.'],
    ['Calendar', 'Design review at 14:00', 'Canvas boards 34 to 36, in 15 minutes.'],
    ['Terminal', 'Command finished', 'just vm-image exited 0 after 18 min in apex-image.'],
    ['Terminal', 'Command failed', 'just lint exited 1 in apex-gnome.'],
    ['Files', 'Copied 4 items', 'To Projects.'],
];

function notify([app, title, body]) {
    return Gio.DBus.session.call('org.freedesktop.Notifications', '/org/freedesktop/Notifications',
        'org.freedesktop.Notifications', 'Notify',
        new GLib.Variant('(susssasa{sv}i)', [app, 0, '', title, body, [], {}, -1]),
        null, Gio.DBusCallFlags.NONE, -1, null);
}

function describeCard(message) {
    const row = message.get_child();
    const column = row.has_style_class_name?.('apex-message-row') ?? false;
    const icon = column ? row.get_first_child() : message._header.get_first_child();
    return {
        title: message.titleLabel.text, column, iconSize: icon.icon_size,
        icon: box(icon), text: box(message.titleLabel), card: box(message),
    };
}

function describeDateMenu(list) {
    const view = list._messageView;
    const controls = list._clearButton.get_parent();
    const dnd = controls.get_children().find(c => c.has_style_class_name('apex-dnd-switch'));
    const groups = view.get_children().map(item => item.child ?? item)
        .filter(g => g?._notificationToMessage);
    return {
        empty: list._placeholder.visible,
        footer: {...box(controls), children: controls.get_children().map(c => c.style_class)},
        clear: {...box(list._clearButton), visible: list._clearButton.visible, reactive: list._clearButton.reactive},
        dnd: dnd ? {checked: dnd.checked, label: dnd.child.get_children()[1].text, ...box(dnd)} : null,
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
    const dnd = list._clearButton.get_parent().get_children().find(c => c.has_style_class_name('apex-dnd-switch'));
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
        if (GLib.getenv('APEX_DATE_MENU') === '1')
            await shootDateMenu();
        else
            await (Main.sessionMode.isGreeter ? shootGreeter() : shootLock());
    } catch (e) {
        console.log(`APEXLOCK-ERROR ${e.message}\n${e.stack}`);
    }
}
