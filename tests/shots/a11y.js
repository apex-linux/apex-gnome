// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's accessibility cases (G2_A11Y=1): each Apex surface open, its text and symbolic icons
// measured against what the stage draws behind them. tests/shots/README.md, "Accessibility".

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as BoxPointer from 'resource:///org/gnome/shell/ui/boxpointer.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';
import * as SwitcherPopup from 'resource:///org/gnome/shell/ui/switcherPopup.js';

import * as Png from './png.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');

// Below this share of a target's pixels the backdrop is an outlier: an antialiased corner.
const BACKDROP_PERCENTILE = 0.05;
const MAX_SAMPLES = 4000;
const SWITCHER_APPS = ['Text Editor', 'Terminal', 'Web', 'Files', 'Settings'];
// org.gnome.desktop.interface accent-color: a checked toggle is filled with each.
export const ACCENTS = ['blue', 'teal', 'green', 'yellow', 'orange', 'red', 'pink', 'purple', 'slate'];

function srgb(channel) {
    const c = channel / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

function luminance([r, g, b]) {
    return 0.2126 * srgb(r) + 0.7152 * srgb(g) + 0.0722 * srgb(b);
}

export function ratio(a, b) {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
}

function over([r, g, b], alpha, [br, bg, bb]) {
    return [r * alpha + br * (1 - alpha), g * alpha + bg * (1 - alpha), b * alpha + bb * (1 - alpha)];
}

function hex(rgb) {
    return `#${rgb.map(v => Math.round(v).toString(16).padStart(2, '0')).join('')}`;
}

// A disabled control, which WCAG exempts. St marks every unreactive widget insensitive,
// labels too, so only a button that stopped taking clicks counts.
function insensitive(actor, root) {
    for (let a = actor; a && a !== root.get_parent(); a = a.get_parent()) {
        if (a instanceof St.Button && !a.reactive)
            return true;
    }
    return false;
}

function symbolic(icon) {
    const names = icon.gicon?.get_names?.() ?? [icon.icon_name];
    return names.some(n => n?.endsWith('-symbolic'));
}

// What a target draws in its foreground colour: the text of a label or an entry, or a glyph.
function targetsOf(root) {
    const found = [];
    const walk = actor => {
        if (!actor.visible || !actor.mapped || actor.get_paint_opacity() === 0)
            return;
        if (actor instanceof St.Entry && actor.get_text())
            found.push({actor, kind: 'text', ink: actor.clutter_text, name: actor.get_text()});
        else if (actor instanceof St.Label && actor.get_text().trim())
            found.push({actor, kind: 'text', ink: actor.clutter_text, name: actor.get_text()});
        else if (actor instanceof St.Icon && symbolic(actor))
            found.push({actor, kind: 'icon', ink: actor, name: actor.gicon?.get_names?.()[0] ?? actor.icon_name});
        actor.get_children().forEach(walk);
    };
    walk(root);
    return found;
}

function extents(actor) {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    return {x, y, width, height};
}

async function stagePixels(box) {
    const stream = Gio.MemoryOutputStream.new_resizable();
    const x = Math.max(0, Math.floor(box.x));
    const y = Math.max(0, Math.floor(box.y));
    const width = Math.min(global.stage.width - x, Math.ceil(box.width));
    const height = Math.min(global.stage.height - y, Math.ceil(box.height));
    await new Shell.Screenshot().screenshot_area(x, y, width, height, stream);
    stream.close(null);
    const image = Png.decode(stream.steal_as_bytes().get_data());
    return {...image, x, y, scale: image.width / width};
}

function ancestor(actor, root, matches) {
    for (let a = actor.get_parent(); a && a !== root.get_parent(); a = a.get_parent()) {
        if (matches(a))
            return a;
    }
    return null;
}

// The nearest filled box: text in two of them, a notification stack's cards, may overlap.
function card(actor, root, cards) {
    const filled = ancestor(actor, root, a => a.get_theme_node?.().get_background_color().alpha > 0) ?? root;
    if (!cards.has(filled))
        cards.set(filled, cards.size);
    return cards.get(filled);
}

// What measure() needs of a target, read while the target still exists.
function snapshot(target, root, cards, unit) {
    const {actor} = target;
    const node = actor.get_theme_node();
    const color = node.get_foreground_color();
    // Hiding an icon hides its own fill too: it goes back over the captured pixels.
    const fill = target.kind === 'icon' ? node.get_background_color() : null;
    const label = actor instanceof St.Label ? actor : null;
    return {
        kind: target.kind,
        name: target.name.slice(0, 40),
        styleClass: actor.get_style_class_name() ?? actor.get_parent()?.get_style_class_name() ?? null,
        inactive: insensitive(actor, root),
        fill: fill?.alpha ? [fill.red, fill.green, fill.blue, fill.alpha / 255] : null,
        rgb: [color.red, color.green, color.blue],
        alpha: color.alpha / 255 * actor.get_paint_opacity() / 255,
        extents: extents(actor),
        box: roundedBox(extents(actor), unit),
        ellipsized: label?.clutter_text?.get_layout().is_ellipsized() ?? false,
        // A collapsed notification's body, whole once the notification expands.
        expandable: !!label?.has_style_class_name('message-body') && !!ancestor(actor, root, a => a.has_style_class_name?.('message')),
        card: card(actor, root, cards),
    };
}

function roundedBox(box, unit) {
    return Object.fromEntries(Object.entries(box).map(([k, v]) => [k, Math.round(v / unit.length * 10) / 10]));
}

// The worst backdrop pixel, after the outliers, for the target's ink composited over each.
function measure(target, image) {
    const {extents: box, rgb, alpha, fill} = target;
    const x0 = Math.max(0, Math.floor((box.x - image.x) * image.scale));
    const y0 = Math.max(0, Math.floor((box.y - image.y) * image.scale));
    const x1 = Math.min(image.width, Math.ceil((box.x + box.width - image.x) * image.scale));
    const y1 = Math.min(image.height, Math.ceil((box.y + box.height - image.y) * image.scale));
    const step = Math.max(1, Math.floor(Math.sqrt((x1 - x0) * (y1 - y0) / MAX_SAMPLES)));
    const samples = [];
    for (let y = y0; y < y1; y += step) {
        for (let x = x0; x < x1; x += step) {
            const at = (y * image.width + x) * 4;
            const drawn = [image.rgba[at], image.rgba[at + 1], image.rgba[at + 2]];
            const backdrop = fill ? over(fill.slice(0, 3), fill[3], drawn) : drawn;
            samples.push({backdrop, ratio: ratio(over(rgb, alpha, backdrop), backdrop)});
        }
    }
    samples.sort((a, b) => a.ratio - b.ratio);
    const worst = samples[Math.floor(samples.length * BACKDROP_PERCENTILE)];
    const {extents: unusedExtents, rgb: unusedRgb, fill: unusedFill, ...rest} = target;
    return {
        ...rest,
        fill: fill ? `${hex(fill.slice(0, 3))} at ${Math.round(fill[3] * 1000) / 1000}` : null,
        // Wholly outside the surface's capture, as another workspace's label is.
        offscreen: samples.length === 0,
        ink: hex(rgb),
        alpha: Math.round(alpha * 1000) / 1000,
        backdrop: worst ? hex(worst.backdrop) : null,
        ratio: worst ? Math.round(worst.ratio * 100) / 100 : null,
    };
}

function setOpacity(actor, opacity) {
    try {
        actor.opacity = opacity;
    } catch {
        // The target went with its parent while the stage drew without it.
    }
}

// Each target's ink hidden while the stage draws what is behind it, then shown again.
async function surfaceReport(root, settle, unit) {
    if (!root?.mapped)
        return {error: 'not shown'};
    const found = targetsOf(root);
    const cards = new Map();
    const targets = found.map(t => snapshot(t, root, cards, unit));
    const box = extents(root);
    const opacities = found.map(t => t.ink.opacity);
    found.forEach(t => setOpacity(t.ink, 0));
    let image;
    try {
        await settle();
        image = await stagePixels(box);
    } finally {
        found.forEach((t, i) => setOpacity(t.ink, opacities[i]));
        await settle();
    }
    return {box: roundedBox(box, unit), targets: targets.map(t => measure(t, image))};
}

async function withOpen(open, close, read) {
    const opened = await open();
    try {
        return await read(opened);
    } finally {
        await close(opened);
    }
}

function switcher() {
    const list = new SwitcherPopup.SwitcherList(true);
    for (const name of SWITCHER_APPS) {
        const app = new St.BoxLayout({style_class: 'alt-tab-app', orientation: Clutter.Orientation.VERTICAL});
        app.add_child(new St.Icon({icon_name: 'application-x-executable', icon_size: 96}));
        app.add_child(new St.Label({text: name, x_align: Clutter.ActorAlign.CENTER}));
        list.addItem(app, app.get_last_child());
    }
    Main.uiGroup.add_child(list);
    const [, width] = list.get_preferred_width(-1);
    const [, height] = list.get_preferred_height(width);
    const {primaryMonitor: monitor} = Main.layoutManager;
    list.set_position(monitor.x + Math.floor((monitor.width - width) / 2), monitor.y + Math.floor((monitor.height - height) / 2));
    list.highlight(1);
    return list;
}

function notifications() {
    const source = new MessageTray.Source({title: 'G2 Updates', iconName: 'software-update-available-symbolic'});
    Main.messageTray.add(source);
    for (const title of ['Update ready', 'Design review']) {
        source.addNotification(new MessageTray.Notification({
            source, title, body: 'Starts after the next restart.', urgency: MessageTray.Urgency.LOW,
        }));
    }
    return source;
}

// Every Apex surface in turn; h holds probe.js's openers and helpers.
export async function a11yReport(h) {
    const {settle, unit} = h;
    const report = root => settle().then(() => surfaceReport(root, settle, unit));
    const out = {
        highContrast: St.Settings.get().high_contrast,
        textScalingFactor: new Gio.Settings({schema_id: 'org.gnome.desktop.interface'}).get_double('text-scaling-factor'),
        monitor: (m => ({x: m.x / unit.length, y: m.y / unit.length, width: m.width / unit.length, height: m.height / unit.length}))(
            Main.layoutManager.primaryMonitor),
    };
    // A startup notification's banner would lie behind whatever it covers.
    for (const source of Main.messageTray.getSources())
        source.destroy();
    Main.overview.hide();
    out.bar = await report(Main.panel);
    out.dock = await report(h.apexDock());
    out.popupMenu = await withOpen(() => h.openPopupMenu(), s => s.close(), s => report(s.root));
    out.osd = await withOpen(() => h.openOsd(), s => s.close(), s => report(s.root));
    out.banner = await withOpen(() => h.openBanner(), s => s.close(), () => report(Main.messageTray._banner));
    const {menu} = Main.panel.statusArea.quickSettings;
    out.quickSettings = await withOpen(() => menu.open(BoxPointer.PopupAnimation.NONE),
        () => menu.close(BoxPointer.PopupAnimation.NONE), () => report(menu.box));
    const iface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
    if (iface.settings_schema.has_key('accent-color')) {
        out.quickSettingsAccents = {};
        for (const accent of ACCENTS) {
            iface.set_string('accent-color', accent);
            // eslint-disable-next-line no-await-in-loop
            out.quickSettingsAccents[accent] = await withOpen(() => menu.open(BoxPointer.PopupAnimation.NONE),
                () => menu.close(BoxPointer.PopupAnimation.NONE), () => report(menu.box));
        }
        iface.reset('accent-color');
    }
    const wifi = h.findDescendant(menu.box, a => a.constructor.name === 'NMWirelessToggle');
    out.wifiMenu = wifi ? await withOpen(() => {
        menu.open(BoxPointer.PopupAnimation.NONE);
        wifi.menu.open(BoxPointer.PopupAnimation.NONE);
    }, () => {
        wifi.menu.close(BoxPointer.PopupAnimation.NONE);
        menu.close(BoxPointer.PopupAnimation.NONE);
    }, () => report(wifi.menu.box)) : {error: 'no Wi-Fi toggle'};
    const dateMenu = Main.panel.statusArea.dateMenu.menu;
    out.dateMenu = await withOpen(() => {
        const source = notifications();
        dateMenu.open(BoxPointer.PopupAnimation.NONE);
        return source;
    }, source => {
        dateMenu.close(BoxPointer.PopupAnimation.NONE);
        source.destroy();
    }, () => report(dateMenu.box));
    out.switcher = await withOpen(switcher, list => list.destroy(), list => report(list));
    out.dialog = await withOpen(() => h.openModalDialog(), d => d.close(), d => report(d.root));
    out.endSession = await withOpen(() => h.openEndSessionDialog(), d => d?.cancel(), d => report(d?.dialogLayout._dialog));
    out.spotlight = await h.withSpotlight(async (popup, toast) => {
        popup.panel.get_children()[0].get_children()[1].set_text('disk');
        return {popup: await report(popup.panel), toast: await report(await toast())};
    }) ?? {error: 'no Spotlight'};
    Main.overview.show();
    global.stage.set_key_focus(null);
    out.overview = await report(Main.overview._overview);
    const {showAppsButton} = Main.overview.dash;
    out.appGrid = await withOpen(() => (showAppsButton.checked = true), () => (showAppsButton.checked = false),
        () => report(Main.overview._overview._controls._appDisplay));
    Main.overview.hide();
    await settle();
    return out;
}
