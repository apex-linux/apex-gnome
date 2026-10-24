// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's app indicators (G2_INDICATORS=1): sni-items.js's StatusNotifierItems in the bar, a
// DBusMenu and its events, the overflow at five, and the privacy group, recording pill and input chip.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';

import * as Png from './png.js';

const FOUR = ['File sync', 'Chat', 'Game launcher', 'Password manager'];
const FIFTH = 'Media player';
const CHAT_ROW = 'Mute for 1 Hour';
const PIXMAP_ITEM = 'Password manager';
// sni-items.js's pixmap is red: as a mask it is the bar's colour, and no red is left.
const PIXMAP_RED = {red: 0xe0, green: 0x1b, blue: 0x24};
const INK_MAX_RGB_DISTANCE = 48;
const SEARCH_ROLE = 'apex-search';

function round(v) {
    return Math.round(v * 100) / 100;
}

function hex(c) {
    return `#${[c.red, c.green, c.blue, c.alpha].map(v => v.toString(16).padStart(2, '0')).join('')}`;
}

function boxOf(actor, unit) {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    return {
        x: round(x / unit.length), y: round(y / unit.length),
        width: round(width / unit.length), height: round(height / unit.length),
    };
}

function radiusOf(actor, unit) {
    return round(actor.get_theme_node().get_border_radius(St.Corner.TOPLEFT) / unit.length);
}

function indicatorBox() {
    return Main.panel._rightBox.get_children().find(a => a.name === 'apexIndicators') ?? null;
}

// The box holds each PanelMenu.Button's container.
function overflowButton() {
    return indicatorBox()?.get_children().map(c => c.child)
        .find(b => b.has_style_class_name('apex-indicators-overflow')) ?? null;
}

function shownButtons() {
    return (indicatorBox()?.get_children() ?? []).filter(c => c.visible).map(c => c.child)
        .filter(b => b.has_style_class_name('apex-indicator'));
}

function button(name) {
    return shownButtons().find(b => b.accessible_name === name) ?? null;
}

function rightBoxOrder() {
    const roles = Object.entries(Main.panel.statusArea);
    return Main.panel._rightBox.get_children().filter(a => a.visible).map(a => {
        if (a.name === 'apexIndicators')
            return 'indicators';
        if (a.has_style_class_name('apex-indicators-divider'))
            return 'divider';
        return roles.find(([, indicator]) => indicator.container === a)?.[0] ?? a.name;
    });
}

function bar(unit) {
    const box = indicatorBox();
    if (!box)
        return null;
    const divider = Main.panel._rightBox.get_children().find(a => a.has_style_class_name('apex-indicators-divider'));
    const overflow = overflowButton();
    return {
        visible: box.visible,
        order: rightBoxOrder(),
        search: Main.panel.statusArea[SEARCH_ROLE] ? boxOf(Main.panel.statusArea[SEARCH_ROLE].get_first_child(), unit) : null,
        items: shownButtons().map(b => {
            const pill = b.get_first_child();
            const [glyph, dot] = pill.get_children();
            return {
                name: b.accessible_name,
                pill: {...boxOf(pill, unit), radius: radiusOf(pill, unit)},
                glyph: {
                    ...boxOf(glyph, unit), colour: hex(glyph.get_theme_node().get_foreground_color()),
                    iconName: glyph.icon_name, mask: glyph.get_effects().length > 0,
                },
                dot: dot.visible
                    ? {...boxOf(dot, unit), radius: radiusOf(dot, unit), colour: hex(dot.get_theme_node().get_background_color())}
                    : null,
            };
        }),
        overflow: overflow.container.visible ? {
            text: overflow.get_first_child().get_children()[1].text,
            pill: {...boxOf(overflow.get_first_child(), unit), radius: radiusOf(overflow.get_first_child(), unit)},
        } : null,
        divider: divider.visible
            ? {...boxOf(divider, unit), colour: hex(divider.get_theme_node().get_background_color())}
            : null,
    };
}

function inkPixels(image, box, ink) {
    let count = 0;
    for (let row = box.y; row < box.y + box.height; row++) {
        for (let col = box.x; col < box.x + box.width; col++) {
            const at = (row * image.width + col) * 4;
            if (Math.hypot(image.rgba[at] - ink.red, image.rgba[at + 1] - ink.green,
                image.rgba[at + 2] - ink.blue) <= INK_MAX_RGB_DISTANCE)
                count++;
        }
    }
    return count;
}

// The pixmap item's glyph in the capture: how much of it is the bar's colour, how much red.
function maskInk(captured) {
    const image = Png.decode(captured.bytes);
    const scale = image.width / global.stage.width;
    const glyph = button(PIXMAP_ITEM)?.get_first_child().get_first_child();
    if (!glyph)
        return null;
    const [x, y] = glyph.get_transformed_position();
    const [width, height] = glyph.get_transformed_size();
    const box = {
        x: Math.round(x * scale), y: Math.round(y * scale),
        width: Math.round(width * scale), height: Math.round(height * scale),
    };
    const ink = glyph.get_theme_node().get_foreground_color();
    return {box, colour: hex(ink), inkPixels: inkPixels(image, box, ink), redPixels: inkPixels(image, box, PIXMAP_RED)};
}

function rowReport(item, unit) {
    const report = {kind: item.constructor.name, label: item.label?.text ?? null, height: boxOf(item, unit).height};
    if (item.has_style_class_name('apex-indicator-menu-header'))
        Object.assign(report, {header: true, colour: hex(item.label.get_theme_node().get_foreground_color())});
    const toggle = item._switch;
    if (toggle)
        report.switch = {...boxOf(toggle, unit), checked: toggle.state, radius: radiusOf(toggle, unit)};
    const shortcut = item.get_children().find(c => c.has_style_class_name?.('apex-indicator-menu-shortcut'));
    if (shortcut)
        report.shortcut = {text: shortcut.text, colour: hex(shortcut.get_theme_node().get_foreground_color())};
    return report;
}

function menuReport(menu, unit) {
    if (!menu)
        return null;
    return {
        open: menu.isOpen,
        content: {...boxOf(menu.box, unit), radius: radiusOf(menu.box, unit)},
        rows: menu._getMenuItems().filter(i => i.visible).map(i => rowReport(i, unit)),
    };
}

function spawnItems(log, names) {
    const here = GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0]);
    return Gio.Subprocess.new(['gjs', '-m', GLib.build_filenamev([here, 'sni-items.js']), log, ...names],
        Gio.SubprocessFlags.NONE);
}

function logLines(log) {
    try {
        return new TextDecoder().decode(GLib.file_get_contents(log)[1]).split('\n').filter(Boolean);
    } catch {
        return [];
    }
}

let _pointer = null;

// A click as the user makes it: a virtual pointer over the actor's centre.
async function click(actor, mouseButton) {
    _pointer ??= global.stage.context.get_backend().get_default_seat()
        .create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
    const now = () => GLib.get_monotonic_time();
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    _pointer.notify_absolute_motion(now(), x + width / 2, y + height / 2);
    await Scripting.sleep(50);
    _pointer.notify_button(now(), mouseButton, Clutter.ButtonState.PRESSED);
    _pointer.notify_button(now(), mouseButton, Clutter.ButtonState.RELEASED);
    await Scripting.sleep(100);
}

function textOf(label, unit) {
    const node = label.get_theme_node();
    const font = node.get_font();
    return {
        text: label.text, size: round(font.get_size() / unit.fontSize), weight: font.get_weight(),
        tracking: round(node.get_letter_spacing() / unit.length), features: node.get_font_features(),
        colour: hex(node.get_foreground_color()),
    };
}

function filled(actor, unit) {
    return {...boxOf(actor, unit), radius: radiusOf(actor, unit), colour: hex(actor.get_theme_node().get_background_color())};
}

// Board 39's "everything": the camera and microphone in use, a recording, and two input sources.
async function everything(unit, settle, capture) {
    const {quickSettings, screenRecording, keyboard} = Main.panel.statusArea;
    const inUse = [quickSettings._camera._indicator, quickSettings._volumeInput._indicator];
    inUse.forEach(icon => icon.show());
    screenRecording.show();
    screenRecording._label.text = '0:42';
    await settle();
    const pill = quickSettings.get_first_child();
    const group = pill.get_children().find(a => a.name === 'apexPrivacyGroup') ?? null;
    const glyphs = (group?.get_children() ?? []).filter(i => i.visible)
        .flatMap(indicator => indicator.get_children().filter(icon => icon.visible));
    const next = pill.get_children().find(a => a !== group && a.visible);
    const [stop, timer] = screenRecording._box.get_children().filter(c => c.visible);
    const chip = keyboard._container.get_children().find(label => label.visible);
    const report = {
        order: rightBoxOrder(),
        pill: {...boxOf(pill, unit), paddingLeft: round(pill.get_theme_node().get_padding(St.Side.LEFT) / unit.length)},
        privacy: group?.visible ? {
            ...filled(group, unit), next: boxOf(next, unit),
            glyphs: glyphs.map(g => ({...boxOf(g, unit), iconName: g.icon_name, colour: hex(g.get_theme_node().get_foreground_color())})),
        } : null,
        recording: {...filled(screenRecording._box, unit), stop: filled(stop, unit), timer: {...boxOf(timer, unit), ...textOf(timer, unit)}},
        input: {pill: {...boxOf(keyboard._container, unit), radius: radiusOf(keyboard._container, unit)}, ...textOf(chip, unit)},
        search: boxOf(Main.panel.statusArea[SEARCH_ROLE].get_first_child(), unit),
    };
    report.capture = (await capture('indicators-everything')).file;
    inUse.forEach(icon => icon.hide());
    screenRecording.hide();
    await settle();
    report.after = {privacy: group?.visible ?? null, paddingLeft: round(pill.get_theme_node().get_padding(St.Side.LEFT) / unit.length)};
    return report;
}

async function until(condition, timeoutMs = 10000) {
    for (let waited = 0; waited < timeoutMs && !condition(); waited += 100)
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(100);
    return condition();
}

// helpers: the probe's cssUnit, settle and capture.
export async function indicatorsReport({cssUnit, settle, capture}) {
    const unit = cssUnit();
    Main.overview.hide();
    await settle();
    const [accent] = St.ThemeContext.get_for_stage(global.stage).get_accent_color();
    const report = {unit, accent: hex(accent), empty: bar(unit)};
    const log = GLib.build_filenamev([GLib.getenv('G2_CAPTURES'), `${GLib.getenv('G2_CASE')}-sni.log`]);
    GLib.file_set_contents(log, '');
    const items = [spawnItems(log, FOUR)];
    try {
        await until(() => shownButtons().length === FOUR.length);
        await settle();
        report.four = bar(unit);
        const captured = await capture('indicators');
        report.four.mask = maskInk(captured);
        report.four.capture = captured.file;
        report.everything = await everything(unit, settle, capture);

        await click(button('Chat'), Clutter.BUTTON_SECONDARY);
        await settle();
        const menu = Main.panel.menuManager.activeMenu;
        report.menu = menuReport(menu, unit);
        report.menu.capture = (await capture('indicator-menu')).file;
        menu._getMenuItems().find(i => i.label?.text === CHAT_ROW)?.activate(Clutter.get_current_event());
        await until(() => logLines(log).includes('Chat Event 5 clicked'), 3000);
        await settle();
        report.menu.closed = !menu.isOpen;

        await click(button('File sync'), Clutter.BUTTON_PRIMARY);
        await until(() => logLines(log).some(l => l.startsWith('File sync Activate')), 3000);

        items.push(spawnItems(log, [FIFTH]));
        await until(() => overflowButton()?.container.visible);
        await settle();
        report.five = bar(unit);
        await click(overflowButton(), Clutter.BUTTON_PRIMARY);
        await settle();
        const overflowMenu = Main.panel.menuManager.activeMenu;
        report.overflowMenu = {
            ...menuReport(overflowMenu, unit),
            rows: overflowMenu?._getMenuItems().map(row => {
                const children = row.get_children();
                const glyph = children.find(c => c.has_style_class_name('apex-indicator-icon'));
                const chevron = children.find(c => c.has_style_class_name('apex-indicators-overflow-chevron'));
                return {
                    label: children.find(c => c instanceof St.Label)?.text ?? null, height: boxOf(row, unit).height,
                    glyph: glyph ? boxOf(glyph, unit).width : null, chevron: chevron?.icon_name ?? null,
                };
            }) ?? [],
        };
        report.overflowMenu.capture = (await capture('indicator-overflow')).file;
        overflowMenu?.close();
        await settle();
    } finally {
        items.forEach(item => item.force_exit());
    }
    await until(() => !indicatorBox()?.visible, 5000);
    report.gone = bar(unit);
    report.log = logLines(log);
    return report;
}
