// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's glass cases (G2_GLASS=1): with patch 0003, frames as the shell drew them (frame.c);
// in every shell, a capture of the stock unlock blur. tests/shots/README.md, "Glass".

import Clutter from 'gi://Clutter';
import Cogl from 'gi://Cogl';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Mtk from 'gi://Mtk';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as BoxPointer from 'resource:///org/gnome/shell/ui/boxpointer.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';
import * as SwitcherPopup from 'resource:///org/gnome/shell/ui/switcherPopup.js';
import * as WindowManager from 'resource:///org/gnome/shell/ui/windowManager.js';

import * as BlurRef from './blur-ref.js';
import {deviceRect} from './frame-rect.js';
import * as Png from './png.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');

let G2Frame = null;

// The top bar's glass (ADR 0014): the largest σ over the thinnest box of the design.
const SIGMA = 24;
const SATURATION = 1.6;
const CORNER_RADIUS = 18;
const TILE = 24;
const PATTERN = {x: 120, y: 200, columns: 20, rows: 10};
const BOX = {x: 216, y: 272, width: 320, height: 80};
const DAMAGED_TILES = [[8, 4], [11, 4], [6, 5], [13, 5]];
const PALETTE = ['#e01b24', '#33d17a', '#3584e4', '#f6d32d', '#9141ac', '#ff7800',
    '#ffffff', '#241f31', '#2ec27e', '#c061cb', '#62a0ea', '#986a44'];
const UNLOCK_RADIUS = 90;
const UNLOCK_BRIGHTNESS = 0.65;
const BACKGROUND_RADIUS = 40;
const BACKGROUND_BRIGHTNESS = 0.8;
const FRAME_TIMEOUT_MS = 2000;
const LAYOUT_FRAMES = 10;
const LAYOUT_STEP_MS = 16;
// Left of the overview's workspace, which leaves the scrim bare there.
const SCRIM_BOX = {x: 24, y: 280, width: 160, height: 160};
const SCRIM_WINDOW = {x: 60, y: 320, width: 200, height: 120};
const APEX_SCHEMA = 'io.github.apex_linux.Apex.Desktop';
const GLASS_EFFECT = 'apex-glass';
const CLIP_TRIES = 5;
const SOLID_STYLE_CLASS = 'apex-solid';
const SHADOW_RIM = 2;
const SHADOW_CROP = 20;
const SHADOW_ZOOM = 4;
// Board 22's glass, and a tile whose inside, past the 6 px clear border, starts and ends on the
// pattern's tiles as BOX does: the effect's downscale cells then line up with the tiles' edges.
const TILE_SIGMA = 20;
const TILE_SATURATION = 1.6;
const TILE_RADIUS = 14;
const TILE_RECT = {x: 162, y: 242, width: 372, height: 180};
const TILE_GLASS = 'apexTilePreviewGlass';
const TILE_GLASSED = 'apex-tile-preview-glassed';
// Board 15's list over a checker of its own, clear of the top bar.
const CORNER_AT = {x: 200, y: 300};
const CHECKER = 4;
const CHECKER_CELLS = 48;

function colourOf(column, row, generation = 0) {
    return PALETTE[(column * 7 + row * 5 + generation) % PALETTE.length];
}

function rgbOf(hex) {
    return [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
}

function buildPattern(parent) {
    const tiles = new Map();
    const pattern = new St.Widget({x: PATTERN.x, y: PATTERN.y});
    for (let row = 0; row < PATTERN.rows; row++) {
        for (let column = 0; column < PATTERN.columns; column++) {
            const tile = new St.Widget({
                x: column * TILE, y: row * TILE, width: TILE, height: TILE,
                style: `background-color: ${colourOf(column, row)};`,
            });
            tile.colour = colourOf(column, row);
            tiles.set(`${column},${row}`, tile);
            pattern.add_child(tile);
        }
    }
    parent.add_child(pattern);
    return tiles;
}

// The pattern as a box sees it, in device pixels.
function patternUnder(tiles, scale, box = BOX) {
    const width = box.width * scale, height = box.height * scale;
    const rgba = new Uint8Array(width * height * 4);
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            const column = Math.floor((box.x - PATTERN.x + x / scale) / TILE);
            const row = Math.floor((box.y - PATTERN.y + y / scale) / TILE);
            const [r, g, b] = rgbOf(tiles.get(`${column},${row}`).colour);
            rgba.set([r, g, b, 255], 4 * (y * width + x));
        }
    }
    return rgba;
}


// The frame after the next paint of the stage view, as it went out, and whether that
// paint's redraw clip covered the box.
let step = '';
function nextFrame(scale, label = '', rect = BOX) {
    step = label;
    const box = new Mtk.Rectangle(rect);
    return new Promise((resolve, reject) => {
        let covered = null;
        const paintId = global.stage.connect('paint-view', (_stage, _view, clip) => {
            covered = !clip || clip.contains_rectangle(box) === Mtk.RegionOverlap.IN;
        });
        const timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, FRAME_TIMEOUT_MS, () => {
            global.stage.disconnect(paintId);
            global.stage.disconnect(afterId);
            reject(new Error(`no frame within ${FRAME_TIMEOUT_MS} ms (${step})`));
            return GLib.SOURCE_REMOVE;
        });
        const afterId = global.stage.connect('after-paint', (_stage, view) => {
            global.stage.disconnect(paintId);
            global.stage.disconnect(afterId);
            GLib.source_remove(timeoutId);
            const framebuffer = view.get_framebuffer();
            try {
                const device = deviceRect(rect, scale, {width: framebuffer.get_width(), height: framebuffer.get_height()}, step);
                const bytes = G2Frame.read(framebuffer, device.x, device.y, device.width, device.height);
                resolve({covered, rgba: bytes.toArray()});
            } catch (e) {
                reject(e);
            }
        });
    });
}

// An actor's box on the next frame, as drawn, in device pixels.
export async function framePixels(actor) {
    G2Frame ??= (await import('gi://G2Frame')).default;
    const [x, y] = actor.get_transformed_position().map(Math.round);
    const [width, height] = actor.get_transformed_size().map(Math.round);
    const scale = actor.get_resource_scale();
    actor.queue_redraw();
    const frame = await nextFrame(scale, `framePixels ${actor}`, {x, y, width, height});
    return {...frame, width: width * scale, height: height * scale};
}

async function fullFrame(group, scale, area = BOX) {
    group.queue_redraw();
    return (await nextFrame(scale, 'full', area)).rgba;
}

// Damage under the box that does not reach its edges: the redraw clip is the tile alone.
let damages = 0;
function damage(tiles, index) {
    const [column, row] = DAMAGED_TILES[index - 1];
    const tile = tiles.get(`${column},${row}`);
    tile.colour = colourOf(column, row, ++damages);
    tile.style = `background-color: ${tile.colour};`;
}

// Another redraw can land in the frame after a damage and cover the box: a full redraw, which
// shows no clip at all, so the tile is damaged again for a frame whose clip misses the box.
async function clippedFrame(group, tiles, index, scale, label) {
    let last, frame, tries = 0;
    do {
        // eslint-disable-next-line no-await-in-loop
        last = await fullFrame(group, scale);
        damage(tiles, index);
        // eslint-disable-next-line no-await-in-loop
        frame = await nextFrame(scale, label);
    } while (frame.covered && ++tries < CLIP_TRIES);
    return {last, frame, tries: tries + 1};
}

// Device pixels per stage pixel, and per CSS pixel: mutter may lay the stage out in either.
async function pixelTests() {
    G2Frame = (await import('gi://G2Frame')).default;
    const cssScale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
    const group = new St.Widget();
    Main.uiGroup.add_child(group);
    const tiles = buildPattern(group);
    const glass = new St.Widget({...BOX});
    group.add_child(glass);
    try {
        await Scripting.waitLeisure();
        const scale = glass.get_resource_scale();
        const deviceCss = scale * cssScale;
        const effect = new Shell.BlurEffect({
            mode: Shell.BlurMode.BACKGROUND, radius: 2 * SIGMA * deviceCss,
            saturation: SATURATION, corner_radius: CORNER_RADIUS * deviceCss, fine: true,
        });
        glass.add_effect(effect);

        const {frame: clippedOnce, tries: referenceTries} = await clippedFrame(group, tiles, 1, scale, 'clipped once');
        const reblurred = await nextFrame(scale, 'reblurred');
        const [width, height] = [BOX.width * scale, BOX.height * scale];
        const options = {sigma: SIGMA * deviceCss, saturation: SATURATION, cornerRadius: CORNER_RADIUS * deviceCss};
        const expected = BlurRef.glass(patternUnder(tiles, scale), width, height, options);
        const downscale = BlurRef.fineDownscale(width, height, options.sigma);
        const reference = {
            clippedFirst: clippedOnce.covered === false, reblurCovered: reblurred.covered, tries: referenceTries, downscale,
            ...BlurRef.errors(reblurred.rgba, expected, width, height, downscale / 2),
        };

        const before = await fullFrame(group, scale);
        damage(tiles, 2);
        glass.queue_redraw();
        const forwarded = await nextFrame(scale, 'forwarded');
        const sameFrame = {
            covered: forwarded.covered,
            changed: BlurRef.differing(before, forwarded.rgba),
            differingFromFull: BlurRef.differing(forwarded.rgba, await fullFrame(group, scale)),
        };

        const {last, frame: clipped, tries: clippedTries} = await clippedFrame(group, tiles, 3, scale, 'clipped');
        const after = await nextFrame(scale, 'after clipped');
        const clippedRedraw = {
            covered: clipped.covered, tries: clippedTries,
            differingFromLast: BlurRef.differing(clipped.rgba, last),
            nextCovered: after.covered,
            nextDifferingFromFull: BlurRef.differing(after.rgba, await fullFrame(group, scale)),
        };

        effect.fine = false;
        const {last: stockLast, frame: stockClipped, tries} = await clippedFrame(group, tiles, 4, scale, 'stock clipped');
        const stockFull = await fullFrame(group, scale);
        const stock = {
            covered: stockClipped.covered, tries,
            differingFromLast: BlurRef.differing(stockClipped.rgba, stockLast),
            differingFromFull: BlurRef.differing(stockClipped.rgba, stockFull),
            ...BlurRef.errors(stockClipped.rgba, BlurRef.glass(patternUnder(tiles, scale), width, height, options),
                width, height, downscale / 2),
        };
        return {scale: deviceCss, sigma: SIGMA, saturation: SATURATION, reference, sameFrame, clippedRedraw, stock};
    } finally {
        group.destroy();
    }
}

function blackPixels(rgba) {
    let count = 0;
    for (let i = 0; i < rgba.length; i += 4) {
        if (rgba[i] + rgba[i + 1] + rgba[i + 2] === 0)
            count++;
    }
    return count;
}

// G2_GLASS_STRESS=SECONDS: a window moves and tiles change under the box, half forwarded, and
// each frame is checked; G2_GLASS_STRESS_STOCK=1 runs stock's effect as the control.
async function stress(seconds) {
    G2Frame = (await import('gi://G2Frame')).default;
    const group = new St.Widget();
    Main.uiGroup.add_child(group);
    const tiles = buildPattern(group);
    const window = new St.Widget({width: 96, height: 64, style: 'background-color: #ffffff;'});
    group.add_child(window);
    const glass = new St.Widget({...BOX});
    group.add_child(glass);
    const result = {frames: 0, clipped: 0, compared: 0, black: 0, stale: 0, unequal: 0};
    try {
        await Scripting.waitLeisure();
        const scale = glass.get_resource_scale();
        const deviceCss = scale * St.ThemeContext.get_for_stage(global.stage).scale_factor;
        glass.add_effect(new Shell.BlurEffect({
            mode: Shell.BlurMode.BACKGROUND, radius: 2 * SIGMA * deviceCss,
            saturation: SATURATION, corner_radius: CORNER_RADIUS * deviceCss,
            fine: GLib.getenv('G2_GLASS_STRESS_STOCK') !== '1',
        }));
        const inside = BlurRef.fullyCovered(BOX.width * scale, BOX.height * scale, CORNER_RADIUS * deviceCss);
        let last = await fullFrame(group, scale);
        const end = GLib.get_monotonic_time() + seconds * 1e6;
        for (let tick = 1; GLib.get_monotonic_time() < end; tick++) {
            window.set_position(BOX.x - 40 + (tick * 7) % (BOX.width + 80), BOX.y - 20 + (tick * 3) % (BOX.height + 40));
            const column = 4 + tick % 12, row = 3 + tick % 4;
            const tile = tiles.get(`${column},${row}`);
            tile.colour = colourOf(column, row, tick);
            tile.style = `background-color: ${tile.colour};`;
            if (tick % 2)
                glass.queue_redraw();
            // eslint-disable-next-line no-await-in-loop
            const frame = await nextFrame(scale, 'stress');
            result.frames++;
            result.black += blackPixels(frame.rgba) > 0 ? 1 : 0;
            if (!frame.covered) {
                result.clipped++;
                result.stale += BlurRef.differing(frame.rgba, last, inside) > 0 ? 1 : 0;
            } else if (tick % 20 === 0) {
                result.compared++;
                // eslint-disable-next-line no-await-in-loop
                result.unequal += BlurRef.differing(frame.rgba, await fullFrame(group, scale), inside) > 0 ? 1 : 0;
            }
            last = frame.rgba;
        }
        return {seconds, paint: GLib.getenv('CLUTTER_PAINT'), stock: GLib.getenv('G2_GLASS_STRESS_STOCK') === '1', ...result};
    } finally {
        group.destroy();
    }
}

// unlockDialog.js's background blur, and a background-mode blur over it, at default values
// of every property 0003-blur adds.
async function unlockCapture() {
    const monitor = Main.layoutManager.primaryMonitor;
    const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
    const group = new St.Widget({x: monitor.x, y: monitor.y, width: monitor.width, height: monitor.height});
    const unlock = new St.Widget({width: monitor.width, height: monitor.height, effect: new Shell.BlurEffect({name: 'blur'})});
    for (let row = 0; row * TILE * 2 < monitor.height; row++) {
        for (let column = 0; column * TILE * 2 < monitor.width; column++) {
            unlock.add_child(new St.Widget({
                x: column * TILE * 2, y: row * TILE * 2, width: TILE * 2, height: TILE * 2,
                style: `background-color: ${colourOf(column, row)};`,
            }));
        }
    }
    unlock.get_effect('blur').set({brightness: UNLOCK_BRIGHTNESS, radius: UNLOCK_RADIUS * scale});
    const background = new St.Widget({...BOX});
    background.add_effect(new Shell.BlurEffect({
        mode: Shell.BlurMode.BACKGROUND, radius: BACKGROUND_RADIUS * scale, brightness: BACKGROUND_BRIGHTNESS,
    }));
    group.add_child(unlock);
    group.add_child(background);
    Main.uiGroup.add_child(group);
    try {
        await Scripting.waitLeisure();
        const dir = GLib.getenv('G2_CAPTURES');
        const file = `${GLib.getenv('G2_CASE')}-unlock.png`;
        GLib.mkdir_with_parents(dir, 0o755);
        const stream = Gio.File.new_for_path(GLib.build_filenamev([dir, file]))
            .replace(null, false, Gio.FileCreateFlags.NONE, null);
        try {
            await new Shell.Screenshot().screenshot_area(monitor.x, monitor.y, monitor.width, monitor.height, stream);
        } finally {
            stream.close(null);
        }
        return {file};
    } finally {
        group.destroy();
    }
}

function glassOf(actor) {
    const effect = actor?.get_effect(GLASS_EFFECT);
    if (!effect)
        return null;
    const {radius, saturation, corner_radius: cornerRadius, enabled, fine, mode} = effect;
    const box = actor.allocation;
    return {
        radius, saturation: Math.round(saturation * 1000) / 1000, cornerRadius, enabled, fine,
        followOpacity: effect.follow_opacity, background: mode === Shell.BlurMode.BACKGROUND,
        mapped: actor.mapped, allocation: [box.get_width(), box.get_height()], painted: paintedOf(actor),
    };
}

// The box St paints the background in, from the allocation's origin, and its corners, in device pixels.
function paintedOf(actor) {
    const node = actor.get_theme_node();
    const scale = actor.get_resource_scale();
    const box = actor.allocation;
    const paint = node.get_background_paint_box(box);
    const corners = [St.Corner.TOPLEFT, St.Corner.TOPRIGHT, St.Corner.BOTTOMRIGHT, St.Corner.BOTTOMLEFT];
    return {
        box: [paint.x1 - box.x1, paint.y1 - box.y1, paint.get_width(), paint.get_height()],
        radii: corners.map(corner => Math.round(node.get_border_radius(corner) * scale)),
    };
}

function blurEffectsUnder(root) {
    const found = [];
    const visit = actor => {
        for (const effect of actor.get_effects()) {
            if (effect instanceof Shell.BlurEffect)
                found.push(actor.get_name() ?? actor.constructor.name);
        }
        actor.get_children().forEach(visit);
    };
    visit(root);
    return found;
}

// Glass comes on once its surface is laid out with area (#135); leisure can come before that frame.
async function laidOut(actor) {
    const ready = () => actor.mapped && actor.has_allocation() && actor.allocation.get_width() > 0 && actor.allocation.get_height() > 0;
    // eslint-disable-next-line no-await-in-loop
    for (let frames = 0; actor && !ready() && frames < LAYOUT_FRAMES && await paintedFrame(); frames++)
        ;
    return actor;
}

async function withMenuOpen(menu, read) {
    menu.open(BoxPointer.PopupAnimation.NONE);
    try {
        await Scripting.waitLeisure();
        return await read(await laidOut(menu.box));
    } finally {
        menu.close(BoxPointer.PopupAnimation.NONE);
    }
}

async function withBanner(read) {
    const source = new MessageTray.Source({title: 'G2 Glass', iconName: 'dialog-information-symbolic'});
    Main.messageTray.add(source);
    source.addNotification(new MessageTray.Notification({
        source, title: 'Glass', body: 'A banner over the desktop.', urgency: MessageTray.Urgency.NORMAL,
    }));
    try {
        await Scripting.waitLeisure();
        return read(await laidOut(Main.messageTray._banner));
    } finally {
        source.destroy();
    }
}

function dockBackground() {
    return Main.layoutManager.uiGroup.get_children().find(actor => actor.get_name() === 'apexDockBox')
        ?.get_first_child()?._background ?? null;
}

async function surfacesState() {
    const {quickSettings, dateMenu} = Main.panel.statusArea;
    return {
        panel: glassOf(Main.panel),
        dock: glassOf(dockBackground()),
        quickSettings: await withMenuOpen(quickSettings.menu, glassOf),
        calendar: await withMenuOpen(dateMenu.menu, glassOf),
        banner: await withBanner(glassOf),
        blurEffects: blurEffectsUnder(global.stage),
        solidClass: Main.uiGroup.has_style_class_name(SOLID_STYLE_CLASS),
    };
}

async function withSetting(settings, key, value, read) {
    const old = settings.get_value(key);
    settings.set_value(key, value);
    try {
        await Scripting.waitLeisure();
        return await read();
    } finally {
        settings.set_value(key, old);
        await Scripting.waitLeisure();
    }
}

function scrimActor() {
    return Main.uiGroup.get_children().find(actor => actor.name === 'apexGlassScrim') ?? null;
}

// The scrims blur a clone of the hidden window_group: St restyles no unmapped actor, so the stand-in
// window is a Clutter.Actor. Actor mode grows no paint volume, so only forwarded damage re-blurs whole.
async function scrimTests() {
    const scale = Main.panel.get_resource_scale();
    const colour = hex => Cogl.Color.from_string(hex)[1];
    const window = new Clutter.Actor({...SCRIM_WINDOW, background_color: colour('#e01b24')});
    global.window_group.add_child(window);
    try {
        Main.overview.show();
        await Scripting.waitLeisure();
        const overview = glassOf(await laidOut(scrimActor()));
        const Glass = await import('resource:///org/gnome/shell/ui/apex/glass/feature.js');
        const before = await fullFrame(Main.uiGroup, scale, SCRIM_BOX);
        window.background_color = colour('#33d17a');
        const unforwarded = await nextFrame(scale, 'scrim damaged', SCRIM_BOX);
        const unforwardedFull = await fullFrame(Main.uiGroup, scale, SCRIM_BOX);
        window.background_color = colour('#3584e4');
        Glass.forwardDamage(SCRIM_WINDOW);
        const forwarded = await nextFrame(scale, 'scrim damage forwarded', SCRIM_BOX);
        const forwardedFull = await fullFrame(Main.uiGroup, scale, SCRIM_BOX);
        const bar = glassOf(Main.panel);
        Main.overview.dash.showAppsButton.checked = true;
        await Scripting.waitLeisure();
        const launcher = glassOf(scrimActor());
        Main.overview.hide();
        await Scripting.waitLeisure();
        return {
            overview, launcher, barOverScrim: bar, hidden: glassOf(scrimActor()),
            unforwarded: {changed: BlurRef.differing(before, unforwarded.rgba), differingFromFull: BlurRef.differing(unforwarded.rgba, unforwardedFull)},
            forwarded: {changed: BlurRef.differing(unforwardedFull, forwarded.rgba), differingFromFull: BlurRef.differing(forwarded.rgba, forwardedFull)},
        };
    } finally {
        window.destroy();
    }
}

// switcherPopup.js's popups join uiGroup, then add their list: a stand-in popup of that name does.
const StandInSwitcherPopup = GObject.registerClass(class GlassTestSwitcherPopup extends St.Widget {});

async function derivedState() {
    const {primaryIndex} = Main.layoutManager;
    Main.osdWindowManager.showOne(primaryIndex, Gio.ThemedIcon.new('audio-volume-medium-symbolic'), null, 0.5);
    const checker = buildChecker();
    const popup = new StandInSwitcherPopup({x: CORNER_AT.x, y: CORNER_AT.y});
    Main.uiGroup.add_child(popup);
    const list = new SwitcherPopup.SwitcherList(true);
    list.addItem(new St.Icon({icon_name: 'application-x-executable', icon_size: 96}), null);
    popup.add_child(list);
    // The closed screenshot UI is unstyled; it would be styled, and blurred, on opening.
    Main.screenshotUI._panel.ensure_style();
    try {
        await Scripting.waitLeisure();
        return {
            osd: glassOf(await laidOut(Main.osdWindowManager._osdWindows[primaryIndex]._hbox)),
            switcher: {...glassOf(await laidOut(list)), corner: await cornerOf(list)},
            screenshot: glassOf(Main.screenshotUI._panel),
        };
    } finally {
        Main.osdWindowManager._osdWindows[primaryIndex].cancel();
        popup.destroy();
        checker.destroy();
    }
}

// Black and white squares under the list: its blur greys them wherever it reaches, and only there.
function buildChecker() {
    const checker = new St.Widget({x: CORNER_AT.x - CHECKER, y: CORNER_AT.y - CHECKER});
    for (let row = 0; row < CHECKER_CELLS; row++) {
        for (let column = 0; column < CHECKER_CELLS; column++) {
            checker.add_child(new St.Widget({
                x: column * CHECKER, y: row * CHECKER, width: CHECKER, height: CHECKER,
                style: `background-color: ${(row + column) % 2 ? 'black' : 'white'};`,
            }));
        }
    }
    Main.uiGroup.insert_child_above(checker, global.window_group);
    return checker;
}

async function capturedPixels({x, y, width, height}) {
    const stream = Gio.MemoryOutputStream.new_resizable();
    await new Shell.Screenshot().screenshot_area(x, y, width, height, stream);
    stream.close(null);
    return Png.decode(stream.steal_as_bytes().get_data()).rgba;
}

// The list's bottom-left corner square, as the screen shows it with its glass and without, and as
// a screenshot captures it: past the border's arc nothing blurs, inside it everything does.
async function cornerOf(list) {
    const [x, y] = list.get_transformed_position().map(Math.round);
    const [width, height] = list.get_transformed_size().map(Math.round);
    const scale = list.get_resource_scale();
    const effect = list.get_effect(GLASS_EFFECT);
    const radius = effect.corner_radius;
    const on = await framePixels(list);
    effect.enabled = false;
    const off = await framePixels(list);
    effect.enabled = true;
    const captured = await capturedPixels({x, y, width, height});
    const [w, h] = [width * scale, height * scale];
    const masks = {outside: new Uint8Array(w * h), inside: new Uint8Array(w * h), square: new Uint8Array(w * h)};
    for (let py = h - radius; py < h; py++) {
        for (let px = 0; px < radius; px++) {
            const d = Math.hypot(radius - px - 0.5, py + 0.5 - (h - radius));
            masks.square[py * w + px] = 1;
            masks.outside[py * w + px] = d > radius + 1 ? 1 : 0;
            masks.inside[py * w + px] = d < radius - 1 ? 1 : 0;
        }
    }
    const count = mask => mask.reduce((sum, bit) => sum + bit, 0);
    return {
        radius, outside: count(masks.outside), inside: count(masks.inside), square: count(masks.square),
        blurredOutside: BlurRef.differing(on.rgba, off.rgba, masks.outside),
        blurredInside: BlurRef.differing(on.rgba, off.rgba, masks.inside),
        capturedDiffering: BlurRef.differing(captured, on.rgba, masks.square),
    };
}

// The pixels the rounded box covers fully, a band in from its edges: no shadow layer reaches them.
function interiorMask(width, height, radius, band) {
    const mask = BlurRef.fullyCovered(width, height, radius);
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            if (Math.min(x, y, width - 1 - x, height - 1 - y) < band)
                mask[y * width + x] = 0;
        }
    }
    return mask;
}

// A surface's frame with its shadows and with `shadows` in disabled-features: the same pixels
// wherever the rounded box covers fully, but for a 2 px band in from its edges.
function compareFrames(on, off) {
    const {width, height, radius} = on;
    return {
        covered: on.covered && off.covered,
        sameSize: width === off.width && height === off.height,
        interiorDiffering: BlurRef.differing(on.rgba, off.rgba, interiorMask(width, height, radius, SHADOW_RIM)),
        rim: rimMax(on.rgba, off.rgba, width, height, radius),
        picked: on.picked,
        samePick: on.picked === off.picked,
    };
}

// The largest channel difference in the rim the rounded box covers at least in part: outside
// its arc, in the corners, the layer's shadow is meant to show.
function rimMax(a, b, width, height, radius) {
    let max = 0;
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            if (Math.min(x, y, width - 1 - x, height - 1 - y) >= SHADOW_RIM || BlurRef.coverage(x, y, width, height, radius) === 0)
                continue;
            const i = 4 * (y * width + x);
            max = Math.max(max, ...[0, 1, 2].map(c => Math.abs(a[i + c] - b[i + c])));
        }
    }
    return max;
}

// The four corners of a box and SHADOW_CROP px around them, each four times over, in one PNG.
async function writeCorners(box, name) {
    const [x, y] = box.get_transformed_position().map(Math.round);
    const [width, height] = box.get_transformed_size().map(Math.round);
    const scale = box.get_resource_scale();
    const c = SHADOW_CROP;
    const rect = {x: x - c, y: y - c, width: width + 2 * c, height: height + 2 * c};
    // A surface at the stage's edge has its shadow margin past it: read what the stage has, the rest stays clear.
    const [rx, ry] = [Math.max(0, rect.x), Math.max(0, rect.y)];
    const [rw0, rh0] = [Math.min(global.stage.width, rect.x + rect.width) - rx, Math.min(global.stage.height, rect.y + rect.height) - ry];
    const read = {x: rx, y: ry, width: rw0, height: rh0};
    global.stage.queue_redraw();
    const frame = await nextFrame(scale, `corners ${name}`, read);
    const [rw, rh, side] = [read.width * scale, read.height * scale, 2 * c * scale];
    const [dx, dy] = [(read.x - rect.x) * scale, (read.y - rect.y) * scale];
    const out = 2 * side * SHADOW_ZOOM;
    const rgba = new Uint8Array(out * out * 4);
    const [fw, fh] = [rect.width * scale, rect.height * scale];
    const origins = [[0, 0], [fw - side, 0], [0, fh - side], [fw - side, fh - side]];
    origins.forEach(([ox, oy], i) => {
        for (let py = 0; py < side * SHADOW_ZOOM; py++) {
            for (let px = 0; px < side * SHADOW_ZOOM; px++) {
                const [fx, fy] = [ox + Math.floor(px / SHADOW_ZOOM) - dx, oy + Math.floor(py / SHADOW_ZOOM) - dy];
                if (fx < 0 || fy < 0 || fx >= rw || fy >= rh)
                    continue;
                const from = 4 * (fy * rw + fx);
                const to = 4 * (((i >> 1) * side * SHADOW_ZOOM + py) * out + (i & 1) * side * SHADOW_ZOOM + px);
                rgba.set(frame.rgba.subarray(from, from + 4), to);
            }
        }
    });
    const file = Gio.File.new_for_path(`${GLib.getenv('G2_CAPTURES')}/shadow-corners-${name}.png`);
    file.replace_contents(Png.encode({width: out, height: out, rgba}), null, false, Gio.FileCreateFlags.NONE, null);
    return file.get_basename();
}

// What a click just inside the box's left edge reaches: the same actor with shadows on and off.
function pickedInside(box) {
    const [x, y] = box.get_transformed_position();
    const [, height] = box.get_transformed_size();
    const actor = global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE, Math.round(x) + 1, Math.round(y + height / 2));
    return `${actor?.constructor.name}.${actor?.style_class ?? ''}`;
}

// A BoxPointer draws a background and border of its own only with an arrow colour or border.
function drawsNothingOutside(boxPointer) {
    const node = boxPointer.get_theme_node();
    const [hasColour, colour] = node.lookup_color('-arrow-background-color', false);
    return (!hasColour || colour.alpha === 0) && node.get_length('-arrow-border-width') === 0;
}

async function popupMenuOver(read) {
    const source = new St.Widget({x: 400, y: 300, width: 40, height: 20, reactive: true});
    Main.uiGroup.add_child(source);
    const menu = new PopupMenu.PopupMenu(source, 0.5, St.Side.TOP);
    ['Open', 'Rename', 'Move to Trash'].forEach(label => menu.addAction(label, () => {}));
    Main.uiGroup.add_child(menu.actor);
    try {
        return await withMenuOpen(menu, box => read(box, menu.actor));
    } finally {
        menu.destroy();
        source.destroy();
    }
}

async function dialogOver(read) {
    const dialog = new ModalDialog.ModalDialog();
    dialog.contentLayout.add_child(new St.Label({text: 'Move "Report.pdf" to the Trash?'}));
    dialog.addButton({label: 'Cancel', action: () => {}});
    dialog.open();
    try {
        await Scripting.waitLeisure();
        return await read(dialog.dialogLayout._dialog, null);
    } finally {
        dialog.close();
        await Scripting.waitLeisure();
    }
}

// A surface opened since the last relayout has no allocation, and its transformed position is NaN.
async function laidOutPosition(box) {
    for (let waited = 0; waited < FRAME_TIMEOUT_MS; waited += LAYOUT_STEP_MS) {
        const [x, y] = box.get_transformed_position();
        if (box.has_allocation() && Number.isFinite(x) && Number.isFinite(y))
            return [x, y];
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(LAYOUT_STEP_MS);
    }
    throw new Error(`${box} had no allocation ${FRAME_TIMEOUT_MS} ms after it opened`);
}

// The shadow layers, above their surfaces and cut out inside them, leave each surface's own
// pixels alone: Quick Settings (glass, over the pattern), a popup menu and a dialog, light and dark.
async function shadowsOverSurfaces() {
    const apex = new Gio.Settings({schema_id: APEX_SCHEMA});
    const disabled = apex.get_strv('disabled-features');
    const group = new St.Widget();
    Main.uiGroup.insert_child_above(group, global.window_group);
    buildPattern(group);
    const surfaces = {
        quickSettings: read => withMenuOpen(Main.panel.statusArea.quickSettings.menu,
            box => read(box, Main.panel.statusArea.quickSettings.menu.actor)),
        popupMenu: popupMenuOver,
        dialog: dialogOver,
    };
    const readAll = async withShadows => {
        const frames = {};
        for (const [name, open] of Object.entries(surfaces)) {
            // eslint-disable-next-line no-await-in-loop
            frames[name] = await open(async (box, boxPointer) => {
                const [x, y] = await laidOutPosition(box);
                group.set_position(Math.round(x) - PATTERN.x, Math.round(y) - PATTERN.y);
                await Scripting.waitLeisure();
                const radius = box.get_theme_node().get_border_radius(St.Corner.TOPLEFT) * box.get_resource_scale();
                return {
                    ...await framePixels(box), radius,
                    picked: pickedInside(box),
                    arrowless: boxPointer ? drawsNothingOutside(boxPointer) : null,
                    corners: withShadows && name === 'quickSettings' ? await writeCorners(box, readAll.variant) : null,
                };
            });
        }
        return frames;
    };
    const compareVariant = async variant => {
        readAll.variant = variant;
        const on = await readAll(true);
        apex.set_strv('disabled-features', [...disabled, 'shadows']);
        await Scripting.waitLeisure();
        const off = await readAll(false);
        apex.set_strv('disabled-features', disabled);
        await Scripting.waitLeisure();
        return Object.fromEntries(Object.keys(surfaces).map(name => [name, {
            ...compareFrames(on[name], off[name]),
            arrowless: on[name].arrowless, corners: on[name].corners,
        }]));
    };
    const iface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
    try {
        return {
            light: await compareVariant('light'),
            dark: await withSetting(iface, 'color-scheme', new GLib.Variant('s', 'prefer-dark'), () => compareVariant('dark')),
        };
    } finally {
        apex.set_strv('disabled-features', disabled);
        group.destroy();
        await Scripting.waitLeisure();
    }
}

// The pixels of a box inside a frame of a larger one, both in device pixels.
function cropOf(rgba, frameWidth, inner) {
    const out = new Uint8Array(inner.width * inner.height * 4);
    for (let y = 0; y < inner.height; y++)
        out.set(rgba.subarray(4 * ((inner.y + y) * frameWidth + inner.x), 4 * ((inner.y + y) * frameWidth + inner.x + inner.width)), 4 * y * inner.width);
    return out;
}

// A rounded ring's width from its coverage, drawn white over black, in device pixels: in each
// corner's radius-square the quarter annulus between r and r - w, along each straight run w a row.
function ringWidths(rgba, frameWidth, inner, radius) {
    const coverage = (x0, y0, w, h) => {
        let sum = 0;
        for (let y = y0; y < y0 + h; y++) {
            for (let x = x0; x < x0 + w; x++)
                sum += rgba[4 * ((inner.y + y) * frameWidth + inner.x + x)] / 255;
        }
        return sum;
    };
    const [r, w, h] = [radius, inner.width, inner.height];
    const corner = area => r - Math.sqrt(Math.max(0, r * r - 4 * area / Math.PI));
    const round2 = v => Math.round(v * 100) / 100;
    return {
        corners: [[0, 0], [w - r, 0], [0, h - r], [w - r, h - r]].map(([x, y]) => round2(corner(coverage(x, y, r, r)))),
        edges: [coverage(r, 0, w - 2 * r, r) / (w - 2 * r), coverage(w - r, r, r, h - 2 * r) / (h - 2 * r),
            coverage(r, h - r, w - 2 * r, r) / (w - 2 * r), coverage(0, r, r, h - 2 * r) / (h - 2 * r)].map(round2),
    };
}

// The ring the glass actor's sheet gives it, in CSS pixels, and what the preview itself still paints.
function ringStyle(glass, preview, cssPerStage) {
    const node = glass?.get_theme_node();
    const sides = [St.Side.TOP, St.Side.RIGHT, St.Side.BOTTOM, St.Side.LEFT];
    return {
        mapped: glass?.mapped ?? false, glass: glassOf(glass),
        borders: node ? sides.map(side => node.get_border_width(side) * cssPerStage) : null,
        radius: node ? node.get_border_radius(St.Corner.TOPLEFT) * cssPerStage : null,
        borderColor: node?.get_border_color(St.Side.TOP).to_string() ?? null,
        background: node?.get_background_color().to_string() ?? null,
        glassed: preview.has_style_class_name(TILE_GLASSED),
        previewBackground: preview.get_theme_node().get_background_color().to_string(),
        previewShadow: preview.get_theme_node().get_box_shadow() !== null,
    };
}

// Board 22: the stock preview tiled over the pattern, as probe.js's tile preview opens it. The
// glass actor's fill and ring held off, the frame shows the blur alone, inside the clear border.
async function tilePreviewTests() {
    G2Frame ??= (await import('gi://G2Frame')).default;
    const group = new St.Widget();
    global.window_group.insert_child_above(group, Main.layoutManager._backgroundGroup);
    const tiles = buildPattern(group);
    const stand = new Clutter.Actor({...TILE_RECT});
    global.window_group.add_child(stand);
    const window = {
        get_compositor_private: () => stand,
        get_frame_rect: () => new Mtk.Rectangle({...TILE_RECT}),
    };
    const preview = new WindowManager.TilePreview();
    const glassActor = () => global.window_group.get_children().find(actor => actor.name === TILE_GLASS && actor.get_next_sibling() === preview);
    try {
        preview.open(window, new Mtk.Rectangle({...TILE_RECT}), Main.layoutManager.primaryIndex);
        await Scripting.waitLeisure();
        await laidOut(preview);
        const glass = await laidOut(glassActor());
        const scale = preview.get_resource_scale();
        const deviceCss = scale * St.ThemeContext.get_for_stage(global.stage).scale_factor;
        const style = ringStyle(glass, preview, scale / deviceCss);
        glass?.set_style('background-color: transparent; border-color: transparent;');
        const inset = preview.get_theme_node().get_border_width(St.Side.TOP);
        const [px, py] = preview.get_transformed_position();
        const [pw, ph] = preview.get_transformed_size();
        const [gx, gy] = glass?.get_transformed_position() ?? [NaN, NaN];
        const [gw, gh] = glass?.get_transformed_size() ?? [NaN, NaN];
        const inner = {x: px + inset, y: py + inset, width: pw - 2 * inset, height: ph - 2 * inset};
        group.queue_redraw();
        const frame = await nextFrame(scale, 'tile preview', {x: px, y: py, width: pw, height: ph});
        const [fw, fh] = [pw * scale, ph * scale];
        const innerDevice = {x: inset * scale, y: inset * scale, width: inner.width * scale, height: inner.height * scale};
        const options = {sigma: TILE_SIGMA * deviceCss, saturation: TILE_SATURATION, cornerRadius: TILE_RADIUS * deviceCss};
        const expected = BlurRef.glass(patternUnder(tiles, scale, inner), innerDevice.width, innerDevice.height, options);
        const downscale = BlurRef.fineDownscale(innerDevice.width, innerDevice.height, options.sigma);
        const band = new Uint8Array(fw * fh);
        for (let y = 0; y < fh; y++) {
            for (let x = 0; x < fw; x++)
                band[y * fw + x] = Math.min(x, y, fw - 1 - x, fh - 1 - y) < inset * scale ? 1 : 0;
        }
        const bare = patternUnder(tiles, scale, {x: px, y: py, width: pw, height: ph});
        const shown = {
            scale: deviceCss, inset: inset / deviceCss * scale, preview: {x: px, y: py, width: pw, height: ph},
            glassBox: {x: gx, y: gy, width: gw, height: gh}, inner, glass: glassOf(glass), downscale,
            ...BlurRef.errors(cropOf(frame.rgba, fw, innerDevice), expected, innerDevice.width, innerDevice.height, downscale / 2),
            bandDiffering: BlurRef.differing(frame.rgba, bare, band),
            innerDiffering: BlurRef.differing(cropOf(frame.rgba, fw, innerDevice), cropOf(bare, fw, innerDevice)),
        };
        // The ring alone, white over black: each pixel's red is the ring's coverage there.
        const black = new St.Widget({x: px, y: py, width: pw, height: ph, style: 'background-color: black;'});
        global.window_group.insert_child_above(black, group);
        glass?.set_style('background-color: transparent; border-color: white;');
        await Scripting.waitLeisure();
        black.queue_redraw();
        const ringFrame = await nextFrame(scale, 'tile ring', {x: px, y: py, width: pw, height: ph});
        black.destroy();
        glass?.set_style(null);
        const ring = {
            ...style, expected: style.borders?.[0] * deviceCss,
            ...ringWidths(ringFrame.rgba, fw, innerDevice, Math.round(style.radius * deviceCss)),
        };
        const apex = new Gio.Settings({schema_id: APEX_SCHEMA});
        const a11y = new Gio.Settings({schema_id: 'org.gnome.desktop.a11y.interface'});
        const read = () => Promise.resolve(ringStyle(glassActor(), preview, scale / deviceCss));
        const reduceTransparency = await withSetting(apex, 'reduce-transparency', new GLib.Variant('b', true), read);
        const highContrast = await withSetting(a11y, 'high-contrast', new GLib.Variant('b', true), read);
        preview.close();
        await Scripting.waitLeisure();
        group.queue_redraw();
        const left = await nextFrame(scale, 'tile preview hidden', {x: px, y: py, width: pw, height: ph});
        return {
            shown, ring, reduceTransparency, highContrast,
            hidden: {glass: glassOf(glass), visible: preview.visible, differing: BlurRef.differing(left.rgba, bare)},
        };
    } finally {
        preview.destroy();
        stand.destroy();
        group.destroy();
        await Scripting.waitLeisure();
    }
}

// The glass manager's surfaces, then Reduce Transparency, high contrast and the kill switch.
// Leisure can come before the frame clock's next frame, so each step waits for a painted one.
function paintedFrame() {
    return new Promise(resolve => {
        let id = 0;
        const timeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, FRAME_TIMEOUT_MS, () => {
            global.stage.disconnect(id);
            resolve(false);
            return GLib.SOURCE_REMOVE;
        });
        id = global.stage.connect('after-paint', () => {
            global.stage.disconnect(id);
            GLib.source_remove(timeout);
            resolve(true);
        });
        global.stage.queue_redraw();
    });
}

// 0003's actor mode sizes its offscreen to the box: an empty one must not blur, over real frames.
async function emptyBoxTests() {
    const Registry = await import('resource:///org/gnome/shell/ui/apex/glass/registry.js');
    const actor = new St.Widget({name: 'apexGlassEmptyTest', style_class: 'apex-glass-scrim', width: 0, height: 0});
    actor.add_child(new Clutter.Clone({source: global.window_group}));
    Main.uiGroup.add_child(actor);
    Registry.register(actor, {name: 'emptyTest', mode: 'actor'});
    let emptyFrames = 0;
    const state = async () => {
        if (await paintedFrame())
            emptyFrames++;
        return glassOf(actor);
    };
    // Laid out, the blur comes on from notify::allocation: allow it the frames a layout takes.
    const settled = async wanted => {
        let frames = 0;
        // eslint-disable-next-line no-await-in-loop
        while (actor.get_effect(GLASS_EFFECT)?.enabled !== wanted && frames < 10 && await paintedFrame())
            frames++;
        const box = actor.allocation;
        return {...glassOf(actor), frames, allocation: [box.get_width(), box.get_height()]};
    };
    try {
        const shown = await state();
        actor.hide();
        const hidden = await state();
        actor.show();
        const shownAgain = await state();
        actor.set_size(320, 200);
        const laidOutState = await settled(true);
        actor.set_size(320, 0);
        return {shown, hidden, shownAgain, emptyFrames, laidOut: laidOutState, zeroHeight: await settled(false)};
    } finally {
        Registry.unregister(actor);
        actor.destroy();
    }
}

async function managerTests() {
    const apex = new Gio.Settings({schema_id: APEX_SCHEMA});
    const a11y = new Gio.Settings({schema_id: 'org.gnome.desktop.a11y.interface'});
    const primary = Main.layoutManager.primaryMonitor;
    return {
        monitorScale: global.display.get_monitor_scale(primary.index),
        glass: await surfacesState(),
        scrims: await scrimTests(),
        derived: await derivedState(),
        tile: await tilePreviewTests(),
        emptyBox: await emptyBoxTests(),
        reduceTransparency: await withSetting(apex, 'reduce-transparency', new GLib.Variant('b', true), surfacesState),
        highContrast: await withSetting(a11y, 'high-contrast', new GLib.Variant('b', true), surfacesState),
        disabled: await withSetting(apex, 'disabled-features', new GLib.Variant('as', ['glass']), surfacesState),
        restored: await surfacesState(),
    };
}

export async function glassReport() {
    const patched = new Shell.BlurEffect().fine !== undefined;
    const stressSeconds = Number(GLib.getenv('G2_GLASS_STRESS') ?? '0');
    if (patched && stressSeconds > 0)
        return {patched, stress: await stress(stressSeconds)};
    return {
        patched,
        unlock: await unlockCapture(),
        pixels: patched ? await pixelTests() : null,
        manager: patched ? await managerTests() : null,
        shadows: patched ? await shadowsOverSurfaces() : null,
    };
}
