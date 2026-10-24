// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's glass cases (G2_GLASS=1): with patch 0003, frames as the shell drew them (frame.c);
// in every shell, a capture of the stock unlock blur. tests/shots/README.md, "Glass".

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Mtk from 'gi://Mtk';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as BoxPointer from 'resource:///org/gnome/shell/ui/boxpointer.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

import * as BlurRef from './blur-ref.js';

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
const APEX_SCHEMA = 'io.github.apex_linux.Apex.Desktop';
const GLASS_EFFECT = 'apex-glass';
const SOLID_STYLE_CLASS = 'apex-solid';

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

// The pattern as the box sees it, in device pixels.
function patternUnder(tiles, scale) {
    const width = BOX.width * scale, height = BOX.height * scale;
    const rgba = new Uint8Array(width * height * 4);
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            const column = Math.floor((BOX.x - PATTERN.x + x / scale) / TILE);
            const row = Math.floor((BOX.y - PATTERN.y + y / scale) / TILE);
            const [r, g, b] = rgbOf(tiles.get(`${column},${row}`).colour);
            rgba.set([r, g, b, 255], 4 * (y * width + x));
        }
    }
    return rgba;
}


// The frame after the next paint of the stage view, as it went out, and whether that
// paint's redraw clip covered the box.
let step = '';
function nextFrame(scale, label = '') {
    step = label;
    const box = new Mtk.Rectangle(BOX);
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
            const bytes = G2Frame.read(view.get_framebuffer(), BOX.x * scale, BOX.y * scale,
                BOX.width * scale, BOX.height * scale);
            resolve({covered, rgba: bytes.toArray()});
        });
    });
}

async function fullFrame(group, scale) {
    group.queue_redraw();
    return (await nextFrame(scale, 'full')).rgba;
}

// Damage under the box that does not reach its edges: the redraw clip is the tile alone.
function damage(tiles, generation) {
    const [column, row] = DAMAGED_TILES[generation - 1];
    const tile = tiles.get(`${column},${row}`);
    tile.colour = colourOf(column, row, generation);
    tile.style = `background-color: ${tile.colour};`;
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
        await fullFrame(group, scale);

        damage(tiles, 1);
        const clippedOnce = await nextFrame(scale, 'clipped once');
        const reblurred = await nextFrame(scale, 'reblurred');
        const [width, height] = [BOX.width * scale, BOX.height * scale];
        const options = {sigma: SIGMA * deviceCss, saturation: SATURATION, cornerRadius: CORNER_RADIUS * deviceCss};
        const expected = BlurRef.glass(patternUnder(tiles, scale), width, height, options);
        const downscale = BlurRef.fineDownscale(width, height, options.sigma);
        const reference = {
            clippedFirst: clippedOnce.covered === false, reblurCovered: reblurred.covered, downscale,
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

        const last = await fullFrame(group, scale);
        damage(tiles, 3);
        const clipped = await nextFrame(scale, 'clipped');
        const after = await nextFrame(scale, 'after clipped');
        const clippedRedraw = {
            covered: clipped.covered,
            differingFromLast: BlurRef.differing(clipped.rgba, last),
            nextCovered: after.covered,
            nextDifferingFromFull: BlurRef.differing(after.rgba, await fullFrame(group, scale)),
        };

        effect.fine = false;
        const stockLast = await fullFrame(group, scale);
        damage(tiles, 4);
        const stockClipped = await nextFrame(scale, 'stock clipped');
        const stockFull = await fullFrame(group, scale);
        const stock = {
            covered: stockClipped.covered,
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
    return {
        radius, saturation: Math.round(saturation * 1000) / 1000, cornerRadius, enabled, fine,
        followOpacity: effect.follow_opacity, background: mode === Shell.BlurMode.BACKGROUND,
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

async function withMenuOpen(menu, read) {
    menu.open(BoxPointer.PopupAnimation.NONE);
    try {
        await Scripting.waitLeisure();
        return read(menu.box);
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
        return read(Main.messageTray._banner);
    } finally {
        source.destroy();
    }
}

async function surfacesState() {
    const {quickSettings, dateMenu} = Main.panel.statusArea;
    return {
        panel: glassOf(Main.panel),
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

// The glass manager's surfaces, then Reduce Transparency, high contrast and the kill switch.
async function managerTests() {
    const apex = new Gio.Settings({schema_id: APEX_SCHEMA});
    const a11y = new Gio.Settings({schema_id: 'org.gnome.desktop.a11y.interface'});
    const primary = Main.layoutManager.primaryMonitor;
    return {
        monitorScale: global.display.get_monitor_scale(primary.index),
        glass: await surfacesState(),
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
    };
}
