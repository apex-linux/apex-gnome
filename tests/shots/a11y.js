// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's accessibility cases (G2_A11Y=1): each Apex surface open, its text and symbolic icons
// measured against what the stage draws behind them. tests/shots/README.md, "Accessibility".

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as BoxPointer from 'resource:///org/gnome/shell/ui/boxpointer.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';
import * as SwitcherPopup from 'resource:///org/gnome/shell/ui/switcherPopup.js';

import {showInUse, showItems} from './indicators.js';
import * as Png from './png.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');

// Below this share of a target's pixels the backdrop is an outlier: an antialiased corner.
const BACKDROP_PERCENTILE = 0.05;
const MAX_SAMPLES = 4000;
const SWITCHER_APPS = ['Text Editor', 'Terminal', 'Web', 'Files', 'Settings'];
// org.gnome.desktop.interface accent-color: a checked toggle is filled with each.
export const ACCENTS = ['blue', 'teal', 'green', 'yellow', 'orange', 'red', 'pink', 'purple', 'slate'];
// The bar's dots draw their background in the bar's ink: glyphs too.
const DOTS = ['workspace-dot', 'messages-indicator'];
// Board 39's two input sources, as direct.sh's TWO_SOURCES.
const TWO_SOURCES = [['xkb', 'us'], ['xkb', 'fr']];
const CHIP_TIMEOUT_MS = 5000;

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

// St draws text in the colour of its Pango attributes, which gjs reads only as the list's text;
// a Clutter.Text St never styled has none and draws in its own colour.
export function textColour(text) {
    const attributes = text.get_attributes()?.to_string() ?? '';
    const colour = attributes.match(/ foreground #([0-9a-f]{4})([0-9a-f]{4})([0-9a-f]{4})/);
    if (!colour) {
        const {red, green, blue, alpha} = text.get_color();
        return {red, green, blue, alpha};
    }
    // St writes each 8-bit channel times 255, not 257, into Pango's 16 bits.
    const byte = v => Math.round(v / 255);
    const [red, green, blue] = colour.slice(1).map(c => byte(parseInt(c, 16)));
    const alpha = byte(Number(attributes.match(/ foreground-alpha (\d+)/)?.[1] ?? 255 * 255));
    return {red, green, blue, alpha};
}

// A Clutter.Text St does not wrap, as an St.Button's own label, which St styles from the button.
function bareText(actor) {
    const parent = actor.get_parent();
    return actor instanceof Clutter.Text && actor.text?.trim() && !(parent instanceof St.Label || parent instanceof St.Entry);
}

// What a target draws in its foreground colour: the text of a label, an entry or a bare text, or a
// glyph; a dot draws its background.
function targetsOf(root) {
    const found = [];
    const walk = actor => {
        if (!actor.visible || !actor.mapped || actor.get_paint_opacity() === 0)
            return;
        // Upstream's high-contrast sheet draws the clock's indicator as a glyph, unfilled.
        const dot = DOTS.find(d => actor.has_style_class_name?.(d) && actor.get_theme_node().get_background_color().alpha > 0);
        if (dot)
            found.push({actor, kind: 'dot', ink: actor, name: dot});
        else if (actor instanceof St.Entry && actor.get_text())
            found.push({actor, kind: 'text', ink: actor.clutter_text, name: actor.get_text()});
        else if (actor instanceof St.Label && actor.get_text().trim())
            found.push({actor, kind: 'text', ink: actor.clutter_text, name: actor.get_text()});
        else if (bareText(actor))
            found.push({actor, kind: 'text', ink: actor, name: actor.text});
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
    const bare = actor instanceof Clutter.Text;
    const node = bare ? null : actor.get_theme_node();
    let color = bare ? textColour(actor) : node.get_foreground_color();
    if (target.kind === 'dot')
        color = node.get_background_color();
    // Hiding an icon hides its own fill too: it goes back over the captured pixels.
    const fill = target.kind === 'icon' ? node.get_background_color() : null;
    const label = actor instanceof St.Label ? actor : null;
    const layout = bare ? actor.get_layout() : label?.clutter_text?.get_layout();
    return {
        kind: target.kind,
        name: target.name.slice(0, 40),
        styleClass: (bare ? null : actor.get_style_class_name()) ?? actor.get_parent()?.get_style_class_name?.() ?? null,
        bare,
        inactive: insensitive(actor, root),
        fill: fill?.alpha ? [fill.red, fill.green, fill.blue, fill.alpha / 255] : null,
        rgb: [color.red, color.green, color.blue],
        alpha: color.alpha / 255 * actor.get_paint_opacity() / 255,
        extents: extents(actor),
        box: roundedBox(extents(actor), unit),
        ellipsized: layout?.is_ellipsized() ?? false,
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
    }
    return {box: roundedBox(box, unit), targets: targets.map(t => measure(t, image))};
}

// The pixel at stage point x, y of a capture.
function pixelAt(image, x, y) {
    const at = (Math.floor((y - image.y) * image.scale) * image.width + Math.floor((x - image.x) * image.scale)) * 4;
    return [image.rgba[at], image.rgba[at + 1], image.rgba[at + 2]];
}

// A filled pill's fill, read across its middle clear of the corners, against the bar a pixel or
// two beyond each end: the median inside, as a stop square stays drawn there.
function edgeOf(pill, image) {
    const box = extents(pill);
    const radius = pill.get_theme_node().get_border_radius(St.Corner.TOPLEFT);
    const inside = [];
    const outside = [];
    for (let y = box.y + box.height / 4; y < box.y + box.height * 3 / 4; y++) {
        for (let x = box.x + radius; x < box.x + box.width - radius; x++)
            inside.push(pixelAt(image, x, y));
        for (const x of [box.x - 2, box.x - 1, box.x + box.width, box.x + box.width + 1])
            outside.push(pixelAt(image, x, y));
    }
    inside.sort((a, b) => luminance(a) - luminance(b));
    const fill = inside[Math.floor(inside.length / 2)];
    const samples = outside.map(bar => ({bar, ratio: ratio(fill, bar)})).sort((a, b) => a.ratio - b.ratio);
    const worst = samples[Math.floor(samples.length * BACKDROP_PERCENTILE)];
    return {fill: hex(fill), bar: hex(worst.bar), ratio: Math.round(worst.ratio * 100) / 100};
}

async function chipShown(keyboard) {
    for (let waited = 0; waited < CHIP_TIMEOUT_MS && !keyboard.visible; waited += 100)
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(100);
}

// An app indicator draws its icon as a mask in the bar's ink, symbolic or not: a glyph.
function indicatorTargets(pill) {
    const glyph = pill.get_first_child();
    return glyph?.mapped ? [{actor: glyph, kind: 'icon', ink: glyph, name: pill.get_parent().accessible_name}] : [];
}

// Board 39's bar with everything on it, sni-items.js's apps and the overflow too: each pill over its
// fill, a filled pill against the bar, the whole bar for Large Text's layout and the Chat app's menu.
async function pillsReport(settle, unit, report) {
    const {quickSettings, screenRecording, screenSharing, keyboard} = Main.panel.statusArea;
    const sources = new Gio.Settings({schema_id: 'org.gnome.desktop.input-sources'});
    const saved = sources.get_value('sources');
    sources.set_value('sources', new GLib.Variant('a(ss)', TWO_SOURCES));
    const hideInUse = showInUse();
    const items = await showItems();
    try {
        await chipShown(keyboard);
        await settle();
        const roots = {
            input: keyboard._container,
            recording: screenRecording._box,
            sharing: screenSharing.get_first_child(),
            privacy: quickSettings.get_first_child().get_children().find(a => a.name === 'apexPrivacyGroup') ?? null,
            overflow: items.overflow,
            ...Object.fromEntries(items.pills.map((pill, i) => [`indicator${i}`, pill])),
        };
        const targetsIn = (pill, root) => {
            if (!root?.mapped)
                return [];
            return pill.startsWith('indicator') ? indicatorTargets(root) : targetsOf(root);
        };
        const found = Object.fromEntries(Object.entries(roots).map(([pill, root]) => [pill, targetsIn(pill, root)]));
        const targets = Object.fromEntries(Object.entries(found).map(([pill, list]) =>
            [pill, list.map(t => snapshot(t, roots[pill], new Map(), unit))]));
        const inks = Object.values(found).flat().map(t => t.ink);
        const opacities = inks.map(ink => ink.opacity);
        inks.forEach(ink => setOpacity(ink, 0));
        let image;
        try {
            await settle();
            image = await stagePixels(extents(Main.panel));
        } finally {
            inks.forEach((ink, i) => setOpacity(ink, opacities[i]));
        }
        const pills = Object.fromEntries(Object.entries(roots).map(([pill, root]) => {
            if (!root?.mapped)
                return [pill, {error: 'not shown'}];
            const filled = root.get_theme_node().get_background_color().alpha > 0;
            return [pill, {targets: targets[pill].map(t => measure(t, image)), edge: filled ? edgeOf(root, image) : null}];
        }));
        const crowded = await report(Main.panel);
        const indicatorMenu = await withOpen(() => items.openMenu(), menu => menu?.close(), menu => menu ? report(menu.box)
            : {error: 'no menu'});
        return {box: roundedBox(extents(Main.panel), unit), pills, crowded, indicatorMenu};
    } finally {
        await items.end();
        hideInUse();
        sources.set_value('sources', saved);
    }
}

const FOCUS_MARGIN = 8;
const FOCUS_CHANGED = 8;
const BUSY_SIZE = 480;
const BUSY_STRIPE = 12;
const WAIT_MS = 5000;

async function until(condition) {
    for (let waited = 0; waited < WAIT_MS && !condition(); waited += 50)
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(50);
    return condition();
}

function firstFocusable(root) {
    const walk = actor => {
        for (const child of actor.get_children()) {
            if (child instanceof St.Widget && child.can_focus && child.reactive && child.mapped)
                return child;
            const found = walk(child);
            if (found)
                return found;
        }
        return null;
    };
    return root ? walk(root) : null;
}

// A focus indicator is what key focus changes: the pixels that differ between the control
// unfocused and focused, wherever it draws them, each read against what it was before.
async function focusRing(target, settle, unit) {
    if (!target?.mapped)
        return {error: 'no focusable control'};
    global.stage.set_key_focus(null);
    await settle();
    const margin = FOCUS_MARGIN * unit.length;
    const {x, y, width, height} = extents(target);
    if (![x, y, width, height].every(Number.isFinite))
        return {error: 'not allocated'};
    const left = Math.max(0, x - margin), top = Math.max(0, y - margin);
    const box = {
        x: left, y: top,
        width: Math.min(global.stage.width, x + width + margin) - left,
        height: Math.min(global.stage.height, y + height + margin) - top,
    };
    if (box.width < 1 || box.height < 1)
        return {error: `off the stage at ${Math.round(x)},${Math.round(y)}`};
    const before = await stagePixels(box);
    target.grab_key_focus();
    await settle();
    const focus = global.stage.get_key_focus();
    // An entry hands key focus to its own text.
    const focused = focus === target || target.contains(focus);
    const after = await stagePixels(box);
    global.stage.set_key_focus(null);
    const ratios = [];
    for (let at = 0; at < after.rgba.length; at += 4) {
        const was = [before.rgba[at], before.rgba[at + 1], before.rgba[at + 2]];
        const now = [after.rgba[at], after.rgba[at + 1], after.rgba[at + 2]];
        if (Math.max(...now.map((v, i) => Math.abs(v - was[i]))) > FOCUS_CHANGED)
            ratios.push(ratio(now, was));
    }
    ratios.sort((a, b) => b - a);
    // The thinnest indicator WCAG 2.4.13 counts: a 1 px line around the control.
    const perimeter = Math.round(2 * (width + height) * after.scale);
    const ringRatio = ratios.length >= perimeter ? ratios[perimeter - 1] : 1;
    return {
        name: target.accessible_name || target.constructor.name, focused, changed: ratios.length, perimeter,
        ratio: Math.round(ringRatio * 100) / 100,
    };
}

// A busy wallpaper, fine stripes of black, white and the accents, for the glass under a ring.
function busyWallpaper() {
    const colours = [[0, 0, 0], [255, 255, 255], [53, 132, 228], [230, 97, 0], [46, 194, 126], [255, 255, 255]];
    const rgba = new Uint8Array(BUSY_SIZE * BUSY_SIZE * 4);
    for (let y = 0; y < BUSY_SIZE; y++) {
        for (let x = 0; x < BUSY_SIZE; x++) {
            const [r, g, b] = colours[Math.floor((x + y) / BUSY_STRIPE) % colours.length];
            rgba.set([r, g, b, 255], (y * BUSY_SIZE + x) * 4);
        }
    }
    const path = GLib.build_filenamev([GLib.get_tmp_dir(), 'apex-g2-busy.png']);
    GLib.file_set_contents(path, Png.encode({width: BUSY_SIZE, height: BUSY_SIZE, rgba}));
    return GLib.filename_to_uri(path, null);
}

// Resolves once every background manager has swapped in a new background and the old ones are gone.
function swapped() {
    const managers = Main.layoutManager._bgManagers;
    let count = 0;
    const ids = managers.map(m => m.connect('changed', () => count++));
    return until(() => count >= managers.length && Main.layoutManager._backgroundGroup.get_n_children() === managers.length)
        .finally(() => ids.forEach((id, i) => managers[i].disconnect(id)));
}

// The wallpaper set for read, waiting for the swap each way, not for a time.
async function withWallpaper(uri, read) {
    const background = new Gio.Settings({schema_id: 'org.gnome.desktop.background'});
    const saved = ['picture-uri', 'picture-uri-dark', 'picture-options'].map(k => [k, background.get_value(k)]);
    let swap = swapped();
    background.set_string('picture-options', 'wallpaper');
    background.set_string('picture-uri', uri);
    background.set_string('picture-uri-dark', uri);
    try {
        if (!await swap)
            return {error: 'the wallpaper never changed'};
        return await read();
    } finally {
        swap = swapped();
        saved.forEach(([key, value]) => background.set_value(key, value));
        await swap;
    }
}

// WCAG 2.4.11 and 1.4.11: a focused control's indicator, on Quick Settings and Spotlight (glass),
// the dock and a dialog, over the case's backdrop and over a busy wallpaper.
async function focusReport(h, settle, unit) {
    const {menu} = Main.panel.statusArea.quickSettings;
    const surfaces = async () => ({
        quickSettings: await withOpen(() => menu.open(BoxPointer.PopupAnimation.NONE),
            () => menu.close(BoxPointer.PopupAnimation.NONE), () => focusRing(firstFocusable(menu.box), settle, unit)),
        dock: await focusRing(firstFocusable(h.apexDock()), settle, unit),
        dialog: await withOpen(() => h.openModalDialog(), d => d.close(), d => focusRing(firstFocusable(d.root), settle, unit)),
        spotlight: await h.withSpotlight(popup => focusRing(firstFocusable(popup.panel), settle, unit)) ?? {error: 'no Spotlight'},
    });
    return {backdrop: await surfaces(), busy: await withWallpaper(busyWallpaper(), surfaces)};
}

// The bar over whatever the stage draws now, as a11yReport measures it.
export async function barReport(settle, unit) {
    await settle();
    return surfaceReport(Main.panel, settle, unit);
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
// The shell idle, then one frame painted after it: what the stage shows is what it last drew.
const FRAME_TIMEOUT_MS = 1000;
async function quiet() {
    await Scripting.waitLeisure();
    await new Promise(resolve => {
        let id = 0;
        const done = () => {
            if (!id)
                return;
            global.stage.disconnect(id);
            id = 0;
            resolve();
        };
        id = global.stage.connect('after-paint', done);
        global.stage.queue_redraw();
        setTimeout(done, FRAME_TIMEOUT_MS);
    });
}

export async function a11yReport(h) {
    const {unit} = h;
    const waits = {count: 0, ms: 0};
    const settle = async () => {
        const start = GLib.get_monotonic_time();
        const idle = await quiet();
        waits.count++;
        waits.ms += Math.round((GLib.get_monotonic_time() - start) / 1000);
        return idle;
    };
    const report = root => settle().then(() => surfaceReport(root, settle, unit));
    // How long each step takes, for the case's time limit.
    const timings = {};
    let mark = GLib.get_monotonic_time();
    const lap = name => {
        const now = GLib.get_monotonic_time();
        timings[name] = Math.round((now - mark) / 1000);
        mark = now;
    };
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
    // Unread notifications put the clock's dot on the bar.
    out.barUnread = await withOpen(notifications, source => source.destroy(), () => report(Main.panel));
    lap('bar');
    out.barPills = await pillsReport(settle, unit, report);
    lap('barPills');
    out.dock = await report(h.apexDock());
    lap('dock');
    out.popupMenu = await withOpen(() => h.openPopupMenu(), s => s.close(), s => report(s.root));
    lap('popupMenu');
    out.osd = await withOpen(() => h.openOsd(), s => s.close(), s => report(s.root));
    lap('osd');
    out.banner = await withOpen(() => h.openBanner(), s => s.close(), () => report(Main.messageTray._banner));
    lap('banner');
    const {menu} = Main.panel.statusArea.quickSettings;
    out.quickSettings = await withOpen(() => menu.open(BoxPointer.PopupAnimation.NONE),
        () => menu.close(BoxPointer.PopupAnimation.NONE), () => report(menu.box));
    lap('quickSettings');
    const iface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
    // The surface stays open while the accent changes under it.
    const underEachAccent = (open, close, root) => withOpen(open, close, async opened => {
        const measured = {};
        try {
            for (const accent of ACCENTS) {
                iface.set_string('accent-color', accent);
                // eslint-disable-next-line no-await-in-loop
                measured[accent] = await report(root(opened));
            }
        } finally {
            iface.reset('accent-color');
        }
        return measured;
    });
    const accents = iface.settings_schema.has_key('accent-color');
    if (accents) {
        out.quickSettingsAccents = await underEachAccent(() => menu.open(BoxPointer.PopupAnimation.NONE),
            () => menu.close(BoxPointer.PopupAnimation.NONE), () => menu.box);
    }
    lap('quickSettingsAccents');
    const wifi = h.findDescendant(menu.box, a => a.constructor.name === 'NMWirelessToggle');
    out.wifiMenu = wifi ? await withOpen(() => {
        menu.open(BoxPointer.PopupAnimation.NONE);
        wifi.menu.open(BoxPointer.PopupAnimation.NONE);
    }, () => {
        wifi.menu.close(BoxPointer.PopupAnimation.NONE);
        menu.close(BoxPointer.PopupAnimation.NONE);
    }, () => report(wifi.menu.box)) : {error: 'no Wi-Fi toggle'};
    // The connected network's row at rest, its fill drawn rather than the key focus's.
    out.wifiMenuConnected = wifi ? await withOpen(() => {
        menu.open(BoxPointer.PopupAnimation.NONE);
        wifi.menu.open(BoxPointer.PopupAnimation.NONE);
        global.stage.set_key_focus(wifi.menu.box);
    }, () => {
        wifi.menu.close(BoxPointer.PopupAnimation.NONE);
        menu.close(BoxPointer.PopupAnimation.NONE);
    }, () => {
        const row = h.findDescendant(wifi.menu.box, a => a.constructor.name === 'NMWirelessNetworkItem' && a.network.is_active);
        return row ? report(row) : {error: 'no connected network'};
    }) : {error: 'no Wi-Fi toggle'};
    lap('wifiMenu');
    const dateMenu = Main.panel.statusArea.dateMenu.menu;
    out.dateMenu = await withOpen(() => {
        const source = notifications();
        dateMenu.open(BoxPointer.PopupAnimation.NONE);
        return source;
    }, source => {
        dateMenu.close(BoxPointer.PopupAnimation.NONE);
        source.destroy();
    }, () => report(dateMenu.box));
    lap('dateMenu');
    // Today's fill is each accent shaded, as a checked toggle's is.
    if (accents) {
        out.dateMenuAccents = await underEachAccent(() => dateMenu.open(BoxPointer.PopupAnimation.NONE),
            () => dateMenu.close(BoxPointer.PopupAnimation.NONE), () => dateMenu.box);
    }
    lap('dateMenuAccents');
    out.switcher = await withOpen(switcher, list => list.destroy(), list => report(list));
    lap('switcher');
    out.dialog = await withOpen(() => h.openModalDialog(), d => d.close(), d => report(d.root));
    lap('dialog');
    // A dialog's default button takes its fill from the accent; the screenshot UI is measured once.
    const screenshot = () => withOpen(async () => {
        await Main.screenshotUI.open();
        global.stage.set_key_focus(null);
    }, () => Main.screenshotUI.close(true), () => report(Main.screenshotUI._panel));
    out.screenshot = await screenshot();
    lap('screenshot');
    if (accents)
        out.dialogAccents = await underEachAccent(() => h.openModalDialog(), d => d.close(), d => d.root);
    lap('dialogAccents');
    // Checked, the box shows its glyph over the accent's shade.
    const checkBoxDialog = () => {
        const opened = h.openMountPasswordDialog();
        opened.check.checked = true;
        return opened;
    };
    out.checkBoxDialog = await withOpen(checkBoxDialog, d => d.close(), d => report(d.root));
    if (accents)
        out.checkBoxDialogAccents = await underEachAccent(checkBoxDialog, d => d.close(), d => d.root);
    lap('checkBoxDialog');
    out.endSession = await withOpen(() => h.openEndSessionDialog(), d => d?.cancel(), d => report(d?.dialogLayout._dialog));
    lap('endSession');
    out.spotlight = await h.withSpotlight(async (popup, toast) => {
        popup.panel.get_children()[0].get_children()[1].set_text('disk');
        return {popup: await report(popup.panel), toast: await report(await toast())};
    }) ?? {error: 'no Spotlight'};
    lap('spotlight');
    out.focus = await focusReport(h, settle, unit);
    lap('focus');
    Main.overview.show();
    global.stage.set_key_focus(null);
    out.overview = await report(Main.overview._overview);
    lap('overview');
    const {showAppsButton} = Main.overview.dash;
    out.appGrid = await withOpen(() => (showAppsButton.checked = true), () => (showAppsButton.checked = false),
        () => report(Main.overview._overview._controls._appDisplay));
    lap('appGrid');
    Main.overview.hide();
    await settle();
    out.timingsMs = {...timings, settles: waits.count, settleMs: waits.ms};
    return out;
}
