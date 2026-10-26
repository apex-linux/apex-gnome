// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's dock-dnd case (G2_DOCK_DND=1): a virtual pointer drags on the dock as a user does, and each
// drop is read back from favorite-apps and the dock's drawn order. tests/shots/README.md.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import * as AppFavorites from 'resource:///org/gnome/shell/ui/appFavorites.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

import {actionModeName, settleDesktop, until} from './idle.js';

const GLIDE_STEPS = 24;
const GLIDE_STEP_MS = 16;
const HOVER_MS = 400;
const DROP_MS = 600;
const APP_TIMEOUT_MS = 15000;
const WEATHER = 'org.gnome.Weather.desktop';
const RUNNING = 'io.github.apex_linux.G2Window.desktop';
const RUNNING_DESKTOP_FILE = `[Desktop Entry]
Type=Application
Name=G2 Window
Exec=gjs -m window.js
`;

const now = () => GLib.get_monotonic_time();
const centre = actor => {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    return [x + width / 2, y + height / 2];
};

class Pointer {
    constructor() {
        const seat = global.stage.context.get_backend().get_default_seat();
        this._pointer = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
        this._keyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        this._at = global.get_pointer();
    }

    // A new device can drop one axis of its first motion: move until the pointer is there.
    async jump([x, y]) {
        const target = [Math.round(x), Math.round(y)];
        await until(() => {
            const [px, py] = global.get_pointer();
            if (px === target[0] && py === target[1])
                return true;
            this._pointer.notify_absolute_motion(now(), ...target);
            return false;
        }, 3000);
        this._at = target;
    }

    // Small steps, so DND's threshold and hover updates see a hand's motion.
    async glide(to) {
        const [x0, y0] = this._at;
        for (let step = 1; step <= GLIDE_STEPS; step++) {
            const t = step / GLIDE_STEPS;
            this._pointer.notify_absolute_motion(now(), x0 + (to[0] - x0) * t, y0 + (to[1] - y0) * t);
            // eslint-disable-next-line no-await-in-loop
            await Scripting.sleep(GLIDE_STEP_MS);
        }
        this._at = to;
        await Scripting.sleep(HOVER_MS);
    }

    button(buttonState) {
        this._pointer.notify_button(now(), Clutter.BUTTON_PRIMARY, buttonState);
    }

    escape() {
        this._keyboard.notify_keyval(now(), Clutter.KEY_Escape, Clutter.KeyState.PRESSED);
        this._keyboard.notify_keyval(now(), Clutter.KEY_Escape, Clutter.KeyState.RELEASED);
    }

    // During: what the dock shows at the drop point before the button comes up.
    async drag(from, to, {during = () => null, cancel = false} = {}) {
        await this.jump(from);
        await Scripting.sleep(100);
        this.button(Clutter.ButtonState.PRESSED);
        await Scripting.sleep(100);
        await this.glide(to);
        const seen = during();
        if (cancel) {
            this.escape();
            await Scripting.sleep(100);
        }
        this.button(Clutter.ButtonState.RELEASED);
        await Scripting.sleep(DROP_MS);
        return seen;
    }
}

function appItems(dock) {
    return dock._box.get_children().filter(item => !item.animatingOut && item.child?._delegate?.app);
}

function itemOf(dock, id) {
    return appItems(dock).find(item => item.child._delegate.app.get_id() === id) ?? null;
}

function tailKind(item, dock) {
    const {separator, showApps, trash} = dock.tailItems;
    if (item === separator)
        return 'separator';
    if (item === showApps)
        return 'show-apps';
    return item === trash ? 'trash' : item.constructor.name;
}

// The point a drop at the given fraction of an item's width reaches, at its vertical centre.
function across(item, fraction) {
    const [x, y] = item.get_transformed_position();
    const [width, height] = item.get_transformed_size();
    return [x + width * fraction, y + height / 2];
}

function state(dock, before) {
    const items = appItems(dock);
    const xs = items.map(item => item.get_transformed_position()[0]);
    return {
        favorites: global.settings.get_strv('favorite-apps'),
        apps: items.map(item => item.child._delegate.app.get_id()),
        drawnInOrder: xs.every((x, i) => i === 0 || x > xs[i - 1]),
        tail: dock._dashContainer.get_children().slice(1).filter(item => item.visible).map(item => tailKind(item, dock)),
        drag: {
            placeholder: Boolean(dock._dragPlaceholder),
            emptyTarget: Boolean(dock._emptyDropTarget),
            modals: Main.modalCount,
            actionMode: actionModeName(),
            grab: global.stage.get_grab_actor() !== null,
            showAppsLabel: dock._showAppsIcon._labelText,
            showAppsName: dock._showAppsIcon.child.accessible_name,
            faded: items.filter(item => item.child.opacity < 255 || !item.child.visible)
                .map(item => item.child._delegate.app.get_id()),
            // Dash items add their hover labels to the chrome; anything else new is a drag's leftover.
            strays: Main.uiGroup.get_children().filter(actor => !before.has(actor) && !actor.has_style_class_name?.('dash-label'))
                .map(actor => ({
                    type: actor.constructor.name, name: actor.name, width: actor.width, height: actor.height,
                    children: actor.get_n_children(),
                })),
        },
    };
}

async function runningApp() {
    const dir = GLib.build_filenamev([GLib.get_user_data_dir(), 'applications']);
    GLib.mkdir_with_parents(dir, 0o755);
    const here = GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0]);
    GLib.file_set_contents(GLib.build_filenamev([dir, RUNNING]),
        RUNNING_DESKTOP_FILE.replace('window.js', GLib.build_filenamev([here, 'window.js'])));
    const apps = Shell.AppSystem.get_default();
    const installed = await until(() => apps.lookup_app(RUNNING) !== null, APP_TIMEOUT_MS);
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
    launcher.setenv('WAYLAND_DISPLAY', GLib.getenv('G2_WAYLAND_DISPLAY') ?? 'apex-g2', true);
    launcher.setenv('GDK_BACKEND', 'wayland', true);
    const client = launcher.spawnv(['gjs', '-m', GLib.build_filenamev([here, 'window.js'])]);
    const running = await until(() => apps.lookup_app(RUNNING)?.state === Shell.AppState.RUNNING, APP_TIMEOUT_MS);
    return {client, installed, running};
}

export async function dockDndReport(helpers) {
    const settled = await settleDesktop(helpers);
    const dock = helpers.apexDock();
    const before = new Set(Main.uiGroup.get_children());
    const pointer = new Pointer();
    const read = () => state(dock, before);
    const steps = {initial: read()};
    const [first, second] = steps.initial.apps;
    if (!first || !second)
        throw new Error(`the dock shows ${steps.initial.apps.length} favourites, not two to reorder`);

    // The second favourite onto the first's leading quarter: favourites' position 0.
    await pointer.drag(centre(itemOf(dock, second)), across(itemOf(dock, first), 0.25));
    steps.reorder = read();

    Main.overview.showApps();
    await helpers.settle();
    const tile = Main.overview._overview.controls._appDisplay._orderedItems?.find(icon => icon.id === WEATHER);
    if (!tile)
        throw new Error(`the app grid has no ${WEATHER} to drag`);
    const firstNow = steps.reorder.apps[0];
    await pointer.drag(centre(tile), across(itemOf(dock, firstNow), 0.75));
    Main.overview.hide();
    await helpers.settle();
    steps.fromGrid = read();

    const showApps = dock._showAppsIcon;
    const label = await pointer.drag(centre(itemOf(dock, WEATHER)), centre(showApps), {during: () => showApps.label.text});
    steps.unpin = {label};
    await helpers.settle();
    Object.assign(steps.unpin, read());

    const monitor = Main.layoutManager.primaryMonitor;
    const middle = [monitor.x + monitor.width / 2, monitor.y + monitor.height / 2];
    await pointer.drag(centre(itemOf(dock, firstNow)), middle);
    await helpers.settle();
    steps.dropOff = read();

    await pointer.drag(centre(itemOf(dock, firstNow)), centre(dock.tailItems.trash));
    await helpers.settle();
    steps.onTrash = read();

    const {client, installed, running} = await runningApp();
    try {
        steps.running = {installed, running, shown: await until(() => itemOf(dock, RUNNING) !== null, APP_TIMEOUT_MS)};
        Object.assign(steps.running, {before: read()});
        await pointer.drag(centre(itemOf(dock, RUNNING)), across(itemOf(dock, firstNow), 0.75));
        await helpers.settle();
        steps.running.after = read();
    } finally {
        AppFavorites.getAppFavorites().removeFavorite(RUNNING);
        client.force_exit();
    }
    await helpers.settle();

    await pointer.drag(centre(itemOf(dock, firstNow)), middle, {cancel: true});
    await helpers.settle();
    steps.cancelled = read();
    return {settled, steps};
}
