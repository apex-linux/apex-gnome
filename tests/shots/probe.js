// SPDX-License-Identifier: GPL-3.0-or-later

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';
import * as WorkspaceThumbnail from 'resource:///org/gnome/shell/ui/workspaceThumbnail.js';

import * as Png from './png.js';

export const METRICS = {};

const APEX_SCHEMA = 'io.github.apex_linux.Apex.Desktop';
const APEX_KEYBINDINGS_SCHEMA = 'io.github.apex_linux.Apex.Desktop.Keybindings';
const TOGGLE_SPOTLIGHT = 'toggle-spotlight';
const CRASH_GUARD_MARKER = 'apex-shell-starting';
// Well before APEX_SHELL_TEST_FAULT=abort-after-enable aborts the shell (5 s after enable).
const REPORT_AFTER_MS = 1500;
const SETTLE_TIMEOUT_MS = 20000;
const SETTLE_EXTRA_MS = 500;
const CALIBRATION_PX = 100;
const INK_MAX_RGB_DISTANCE = 60;
const TRANSLUCENT_BAR_KEY = 'translucent-top-bar';
const DARK_STYLE_TOGGLE_ICON = 'dark-mode-symbolic';
const LARGE_TEXT_SCALING_FACTOR = 1.25;
const HIGH_CONTRAST_SHEET = 'resource:///org/gnome/shell/theme/gnome-shell-high-contrast.css';
const STRUCTURE_MARKER = '/*! apex-shell-structure */';
const LAYER_ENABLED_KEY = 'layer-enabled';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot');

function hex(color) {
    return `#${[color.red, color.green, color.blue, color.alpha]
        .map(v => Number(v).toString(16).padStart(2, '0')).join('')}`;
}

function round(v) {
    return Math.round(v * 1000) / 1000;
}

function withStyledActor(actor, read) {
    Main.uiGroup.add_child(actor);
    try {
        return read(actor.get_theme_node());
    } finally {
        actor.destroy();
    }
}

function themeMarkerColor() {
    try {
        return withStyledActor(new St.Label({style_class: 'apex-theme-marker', text: 'apex'}),
            node => hex(node.get_foreground_color()).slice(0, 7));
    } catch (e) {
        return `error: ${e.message}`;
    }
}

// Measured through St, so that the metrics hold whether mutter lays the stage out in
// logical or in physical pixels.
function cssUnit() {
    return withStyledActor(new St.Label({
        text: 'x',
        style: `width: ${CALIBRATION_PX}px; font-size: ${CALIBRATION_PX}px;`,
    }), node => ({
        length: node.get_width() / CALIBRATION_PX,
        fontSize: node.get_font().get_size() / CALIBRATION_PX,
    }));
}

function sha256OfText(text) {
    return GLib.compute_checksum_for_string(GLib.ChecksumType.SHA256, text, -1);
}

function sheetInfo(uri) {
    try {
        const [, bytes] = Gio.File.new_for_uri(uri).load_contents(null);
        const text = new TextDecoder().decode(bytes);
        return {
            sha256: GLib.compute_checksum_for_data(GLib.ChecksumType.SHA256, bytes),
            sha256WithoutStructureMarker: sha256OfText(text.replace(STRUCTURE_MARKER, '').trimEnd()),
            bytes: bytes.length,
            markers: ['light', 'dark'].filter(v => text.includes(`/*! apex-shell-theme ${v} */`)),
            structure: text.includes(STRUCTURE_MARKER),
            apexRule: text.includes('.apex-theme-marker'),
        };
    } catch (e) {
        return {error: e.message};
    }
}

function setting(schemaId, read) {
    try {
        const schema = Gio.SettingsSchemaSource.get_default().lookup(schemaId, true);
        return schema ? read(new Gio.Settings({settings_schema: schema})) : 'no-schema';
    } catch (e) {
        return `error: ${e.message}`;
    }
}

// windowManager.js keeps each binding's action modes here, and removeKeybinding sets NONE.
function spotlightKey() {
    const modes = Main.wm._allowedKeybindings[TOGGLE_SPOTLIGHT] ?? Shell.ActionMode.NONE;
    return {
        modes: Object.entries(Shell.ActionMode)
            .filter(([name, bit]) => name !== 'ALL' && bit !== 0 && (modes & bit) === bit)
            .map(([name]) => name),
        accelerators: setting(APEX_KEYBINDINGS_SCHEMA, s => s.get_strv(TOGGLE_SPOTLIGHT)),
    };
}

function startingMarker() {
    return GLib.file_test(GLib.build_filenamev([GLib.get_user_runtime_dir(), CRASH_GUARD_MARKER]),
        GLib.FileTest.EXISTS);
}

async function apexHooks() {
    try {
        return await import('resource:///org/gnome/shell/ui/apex/hooks.js');
    } catch {
        return null;
    }
}

// direct.sh freezes the wall clock with libfaketime; the guard's shells keep the real one.
function clock() {
    if (GLib.getenv('FAKETIME') === null)
        return null;
    return {
        now: GLib.DateTime.new_now_local().format_iso8601(),
        text: Main.panel.statusArea.dateMenu?._clockDisplay.get_text() ?? null,
    };
}

async function report() {
    const hooks = await apexHooks();
    const context = St.ThemeContext.get_for_stage(global.stage);
    const uri = context.get_theme().default_stylesheet?.get_uri() ?? null;
    const primary = Main.layoutManager.primaryMonitor;
    return {
        mode: Main.sessionMode.currentMode,
        stylesheet: uri,
        sheet: uri ? sheetInfo(uri) : null,
        highContrastSheet: sheetInfo(HIGH_CONTRAST_SHEET),
        markerColor: themeMarkerColor(),
        sessionColorScheme: Main.sessionMode.colorScheme,
        variant: Main.getStyleVariant?.() ?? null,
        colorSchemeSetting: setting('org.gnome.desktop.interface', s => s.get_string('color-scheme')),
        layerEnabled: setting(APEX_SCHEMA, s => s.get_boolean('layer-enabled')),
        apexHooks: hooks !== null,
        safe: hooks?.safe() ?? null,
        testFault: hooks?.value('test-fault', 'stock') ?? null,
        spotlightKey: spotlightKey(),
        startingMarker: startingMarker(),
        clock: clock(),
        thumbnailScale: WorkspaceThumbnail.MAX_THUMBNAIL_SCALE ?? null,
        monitors: Main.layoutManager.monitors.length,
        logical: primary ? `${primary.width}x${primary.height}` : null,
        monitorScale: primary ? global.display.get_monitor_scale(primary.index) : null,
        stScale: context.scale_factor,
        stage: `${global.stage.width}x${global.stage.height}`,
        env: {
            APEX_SHELL_SAFE: GLib.getenv('APEX_SHELL_SAFE'),
            APEX_SHELL_TEST_FAULT: GLib.getenv('APEX_SHELL_TEST_FAULT'),
        },
    };
}

function sides(read, unit) {
    return Object.fromEntries(Object.entries({
        top: St.Side.TOP, right: St.Side.RIGHT, bottom: St.Side.BOTTOM, left: St.Side.LEFT,
    }).map(([name, side]) => [name, round(read(side) / unit.length)]));
}

function lengthOrNull(node, property, unit) {
    const [found, value] = node.lookup_length(property, false);
    return found ? round(value / unit.length) : null;
}

function font(node, unit) {
    const description = node.get_font();
    return {
        family: description.get_family(),
        size: round(description.get_size() / unit.fontSize),
        weight: description.get_weight(),
        features: node.get_font_features(),
    };
}

function shadow(node, unit) {
    const s = node.get_box_shadow();
    if (!s)
        return null;
    return {
        color: hex(s.color), inset: s.inset, x: round(s.xoffset / unit.length),
        y: round(s.yoffset / unit.length), blur: round(s.blur / unit.length),
        spread: round(s.spread / unit.length),
    };
}

function paint(node, unit) {
    return {background: hex(node.get_background_color()), boxShadow: shadow(node, unit)};
}

function underPseudoClass(actor, pseudoClass, read) {
    const had = actor.has_style_pseudo_class(pseudoClass);
    actor.add_style_pseudo_class(pseudoClass);
    try {
        return read();
    } finally {
        if (!had)
            actor.remove_style_pseudo_class(pseudoClass);
    }
}

function firstVisibleLabel(actor) {
    for (const child of actor.get_children()) {
        if (!child.visible)
            continue;
        if (child instanceof St.Label)
            return child;
        const found = firstVisibleLabel(child);
        if (found)
            return found;
    }
    return null;
}

function styleOf(actor, unit) {
    if (!actor)
        return null;
    const node = actor.get_theme_node();
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    const label = firstVisibleLabel(actor);
    return {
        name: actor.get_name(),
        styleClass: actor.get_style_class_name(),
        pseudoClass: actor.get_style_pseudo_class(),
        x: round(x / unit.length),
        y: round(y / unit.length),
        width: round(width / unit.length),
        height: round(height / unit.length),
        border: sides(side => node.get_border_width(side), unit),
        padding: sides(side => node.get_padding(side), unit),
        hpadding: {
            natural: lengthOrNull(node, '-natural-hpadding', unit),
            minimum: lengthOrNull(node, '-minimum-hpadding', unit),
        },
        spacing: lengthOrNull(node, 'spacing', unit),
        radius: round(node.get_border_radius(St.Corner.TOPLEFT) / unit.length),
        transition: node.get_transition_duration(),
        foreground: hex(node.get_foreground_color()),
        ...paint(node, unit),
        font: font(node, unit),
        label: label ? {
            text: label.get_text(),
            font: font(label.get_theme_node(), unit),
            foreground: hex(label.get_theme_node().get_foreground_color()),
        } : null,
    };
}

function button(actor, unit) {
    if (!actor)
        return null;
    const pill = actor.get_first_child();
    const pillPaintWhenButtonIs = pseudoClass =>
        underPseudoClass(actor, pseudoClass, () => paint(pill.get_theme_node(), unit));
    return {
        ...styleOf(actor, unit),
        pill: pill ? {
            ...styleOf(pill, unit),
            hover: pillPaintWhenButtonIs('hover'),
            checked: pillPaintWhenButtonIs('checked'),
        } : null,
    };
}

function boxOf(actor, unit) {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    return {
        x: round(x / unit.length), y: round(y / unit.length),
        width: round(width / unit.length), height: round(height / unit.length),
    };
}

// panel.js's WorkspaceDot allocates the widened width; its child draws the scaled, faded dot.
function workspaceDots(activities, unit) {
    const active = global.workspace_manager.get_active_workspace_index();
    return activities.get_first_child().get_children().map((slot, index) => {
        const dot = slot.get_first_child();
        return {
            active: index === active,
            ...boxOf(dot, unit),
            opacity: round(dot.opacity / 255 * slot.opacity / 255),
            radius: round(dot.get_theme_node().get_border_radius(St.Corner.TOPLEFT) / unit.length),
        };
    });
}

function clockTextGap(label, unit) {
    const parts = label.get_text().match(/^(.*\S)(\s+)(\d{1,2}:\d{2}.*)$/u);
    if (!parts)
        return null;
    const layout = label.clutter_text.get_layout();
    const byteLength = text => new TextEncoder().encode(text).length;
    const dateEnd = layout.index_to_pos(byteLength(parts[1])).x;
    const timeStart = layout.index_to_pos(byteLength(parts[1] + parts[2])).x;
    const [, logical] = layout.get_extents();
    return round((timeStart - dateEnd) / logical.width * boxOf(label, unit).width);
}

function panelItems(boxActor, unit) {
    return boxActor.get_children().filter(c => c.visible).map(container => {
        const item = container.get_first_child();
        const pill = item?.get_first_child();
        const label = item ? firstVisibleLabel(item) : null;
        return {
            accessibleName: item?.accessible_name ?? null,
            label: label ? {text: label.get_text(), weight: label.get_theme_node().get_font().get_weight()} : null,
            pill: pill ? {...boxOf(pill, unit), radius: round(pill.get_theme_node().get_border_radius(St.Corner.TOPLEFT) / unit.length)} : null,
        };
    });
}

function reactiveActorAtTopLeftPixel(unit) {
    const actor = global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE, 0, 0);
    return actor ? {name: actor.get_name(), type: actor.constructor.name, ...boxOf(actor, unit)} : null;
}

function blurEffects(root) {
    const found = [];
    const visit = actor => {
        for (const effect of actor.get_effects()) {
            if (effect instanceof Shell.BlurEffect) {
                found.push({
                    actor: actor.get_name() ?? actor.constructor.name,
                    radius: effect.radius, saturation: effect.saturation ?? null,
                });
            }
        }
        actor.get_children().forEach(visit);
    };
    visit(root);
    return found;
}

function visibleStatusIcons() {
    return Main.panel.statusArea.quickSettings.get_first_child().get_children()
        .filter(indicator => indicator.visible)
        .flatMap(indicator => indicator.get_children())
        .filter(icon => icon.visible && icon instanceof St.Icon);
}

function glyphName(icon) {
    return icon.icon_name ?? icon.gicon?.to_string() ?? null;
}

function statusGlyphs() {
    return visibleStatusIcons().map(glyphName);
}

function statusGlyphSizes(unit) {
    return visibleStatusIcons().map(icon => {
        const {width, height} = boxOf(icon, unit);
        return {
            name: glyphName(icon), width, height,
            iconSize: lengthOrNull(icon.get_theme_node(), 'icon-size', unit),
        };
    });
}

// The battery's percentage is a label beside its glyph, in the same indicator.
function statusLabels(unit) {
    return Main.panel.statusArea.quickSettings.get_first_child().get_children()
        .filter(indicator => indicator.visible)
        .flatMap(indicator => indicator.get_children())
        .filter(label => label.visible && label instanceof St.Label)
        .map(label => ({
            text: label.get_text(),
            font: font(label.get_theme_node(), unit),
            foreground: hex(label.get_theme_node().get_foreground_color()),
        }));
}

function accentColor() {
    try {
        const [accent] = St.ThemeContext.get_for_stage(global.stage).get_accent_color();
        return hex(accent);
    } catch (e) {
        return `error: ${e.message}`;
    }
}

function topBar(unit) {
    const box = name => Main.panel.get_children().find(c => c.get_name() === name) ?? null;
    const {statusArea} = Main.panel;
    const {_clockDisplay: clockLabel} = statusArea.dateMenu;
    return {
        panel: styleOf(Main.panel, unit),
        left: styleOf(box('panelLeft'), unit),
        center: styleOf(box('panelCenter'), unit),
        right: styleOf(box('panelRight'), unit),
        activities: button(statusArea.activities, unit),
        clock: button(statusArea.dateMenu, unit),
        status: button(statusArea.quickSettings, unit),
        dots: workspaceDots(statusArea.activities, unit),
        clockTextGap: clockTextGap(clockLabel, unit),
        clockShowsWeekday: clockLabel.get_text().startsWith(GLib.DateTime.new_now_local().format('%a')),
        leftItems: panelItems(box('panelLeft'), unit),
        rightItems: panelItems(box('panelRight'), unit),
        corner: reactiveActorAtTopLeftPixel(unit),
        glass: blurEffects(Main.layoutManager.panelBox),
        statusGlyphs: statusGlyphSizes(unit),
        statusLabels: statusLabels(unit),
        accent: accentColor(),
    };
}

async function settle() {
    let idle = false;
    await Promise.race([
        Scripting.waitLeisure().then(() => {
            idle = true;
        }),
        Scripting.sleep(SETTLE_TIMEOUT_MS),
    ]);
    await Scripting.sleep(SETTLE_EXTRA_MS);
    return idle;
}

function captureBox(actor, scale) {
    if (!actor)
        return null;
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    const x0 = Math.floor(x * scale);
    const y0 = Math.floor(y * scale);
    return {
        x: x0, y: y0, width: Math.ceil((x + width) * scale) - x0,
        height: Math.ceil((y + height) * scale) - y0,
    };
}

async function capture(scene) {
    const dir = GLib.getenv('G2_CAPTURES');
    const name = `${GLib.getenv('G2_CASE')}-${scene}.png`;
    GLib.mkdir_with_parents(dir, 0o755);
    const path = GLib.build_filenamev([dir, name]);
    const stream = Gio.File.new_for_path(path).replace(null, false, Gio.FileCreateFlags.NONE, null);
    try {
        await new Shell.Screenshot().screenshot(false, stream);
    } finally {
        stream.close(null);
    }
    const [, bytes] = GLib.file_get_contents(path);
    const {width, height} = Png.size(bytes);
    const scale = width / global.stage.width;
    return {
        file: name, width, height, bytes,
        boxes: {
            panel: captureBox(Main.panel, scale),
            clock: captureBox(Main.panel.statusArea.dateMenu, scale),
        },
    };
}

function inkPixelCount(image, box, ink) {
    let count = 0;
    for (let row = box.y; row < box.y + box.height; row++) {
        for (let col = box.x; col < box.x + box.width; col++) {
            const at = (row * image.width + col) * 4;
            const distance = Math.hypot(image.rgba[at] - ink.red, image.rgba[at + 1] - ink.green,
                image.rgba[at + 2] - ink.blue);
            if (distance <= INK_MAX_RGB_DISTANCE)
                count++;
        }
    }
    return count;
}

// The Activities pill's padding left of the dots holds the diamond and nothing else.
function diamondInk(bytes) {
    const image = Png.decode(bytes);
    const scale = image.width / global.stage.width;
    const pill = Main.panel.statusArea.activities.get_first_child();
    const node = pill.get_theme_node();
    const [x, y] = pill.get_transformed_position();
    const leftPadding = {
        x: Math.round(x * scale),
        y: Math.round(y * scale),
        width: Math.round(node.get_padding(St.Side.LEFT) * scale),
        height: Math.round(pill.get_transformed_size()[1] * scale),
    };
    const ink = node.get_foreground_color();
    return {box: leftPadding, colour: hex(ink), inkPixels: inkPixelCount(image, leftPadding, ink)};
}

function thumbnails() {
    const box = Main.overview._overview.controls._thumbnailsBox;
    return {shown: box.visible && box.should_show, maxScale: box.maxThumbnailScale, scale: round(box.scale)};
}

// A low-urgency notification skips the banner and stays unread: the clock shows its dot.
async function withUnreadNotification(unit) {
    const source = new MessageTray.Source({title: 'G2', iconName: 'dialog-information-symbolic'});
    Main.messageTray.add(source);
    source.addNotification(new MessageTray.Notification({
        source, title: 'G2', body: 'unread', urgency: MessageTray.Urgency.LOW,
    }));
    await settle();
    const {dateMenu} = Main.panel.statusArea;
    const indicator = dateMenu._indicator;
    const measured = {
        dot: {
            visible: indicator.visible, ...boxOf(indicator, unit),
            radius: round(indicator.get_theme_node().get_border_radius(St.Corner.TOPLEFT) / unit.length),
            background: hex(indicator.get_theme_node().get_background_color()),
        },
        pillWidth: boxOf(dateMenu.get_first_child(), unit).width,
        labelWidth: boxOf(dateMenu._clockDisplay, unit).width,
    };
    source.destroy();
    await settle();
    return measured;
}

async function withDoNotDisturb() {
    const notifications = new Gio.Settings({schema_id: 'org.gnome.desktop.notifications'});
    const off = statusGlyphs();
    notifications.set_boolean('show-banners', false);
    await settle();
    const on = statusGlyphs();
    notifications.reset('show-banners');
    await settle();
    return {off, on};
}

async function withPanelStyleClass(styleClass, measure) {
    Main.panel.add_style_class_name(styleClass);
    try {
        await settle();
        return measure();
    } finally {
        Main.panel.remove_style_class_name(styleClass);
        await settle();
    }
}

// The lock screen and the greeter add these style classes to the same panel.
function withLockScreenPanel(unit) {
    return withPanelStyleClass('unlock-screen', () => {
        const status = Main.panel.statusArea.quickSettings;
        return {
            status: button(status, unit),
            statusHover: underPseudoClass(status, 'hover', () => paint(status.get_theme_node(), unit)),
        };
    });
}

async function withLargeText() {
    const settings = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
    settings.set_double('text-scaling-factor', LARGE_TEXT_SCALING_FACTOR);
    try {
        await settle();
        const unit = cssUnit();
        const {dateMenu} = Main.panel.statusArea;
        const clockLabel = dateMenu._clockDisplay;
        return {
            textScalingFactor: settings.get_double('text-scaling-factor'),
            barHeight: boxOf(Main.panel, unit).height,
            clockPillHeight: boxOf(dateMenu.get_first_child(), unit).height,
            clockText: {
                ...font(clockLabel.get_theme_node(), unit),
                height: boxOf(clockLabel, unit).height,
                naturalHeight: round(clockLabel.get_preferred_height(-1)[1] / unit.length),
            },
            statusGlyphs: statusGlyphSizes(unit),
        };
    } finally {
        settings.reset('text-scaling-factor');
        await settle();
    }
}

async function withOpaqueBar(unit) {
    const schema = Gio.SettingsSchemaSource.get_default().lookup(APEX_SCHEMA, true);
    if (!schema?.has_key(TRANSLUCENT_BAR_KEY))
        return {error: `${APEX_SCHEMA} has no ${TRANSLUCENT_BAR_KEY} key`};
    const settings = new Gio.Settings({settings_schema: schema});
    settings.set_boolean(TRANSLUCENT_BAR_KEY, false);
    await settle();
    const measured = paint(Main.panel.get_theme_node(), unit);
    settings.reset(TRANSLUCENT_BAR_KEY);
    await settle();
    return measured;
}

// Without GDM the shell posts "Screen Lock disabled" at startup; its banner would cover
// the scenes for as long as it happens to stay.
function dropStartupNotifications() {
    for (const source of Main.messageTray.getSources())
        source.destroy();
}

async function scenes() {
    const unit = cssUnit();
    const startedInOverview = Main.overview.visible;

    dropStartupNotifications();
    Main.overview.hide();
    const desktopIdle = await settle();
    const desktop = {idle: desktopIdle, ...await capture('desktop')};
    const diamond = diamondInk(desktop.bytes);
    delete desktop.bytes;
    // After the capture: reading the hover and checked styles restyles the pills.
    const bar = topBar(unit);
    bar.withDot = await withUnreadNotification(unit);
    bar.dnd = await withDoNotDisturb();
    bar.opaque = await withOpaqueBar(unit);
    bar.lockScreen = await withLockScreenPanel(unit);
    bar.largeText = await withLargeText();

    Main.overview.show();
    await settle();
    // The search entry's cursor blinks: without key focus the scene is still.
    global.stage.set_key_focus(null);
    const overviewIdle = await settle();
    const overview = {idle: overviewIdle, ...await capture('overview'), thumbnails: thumbnails()};
    delete overview.bytes;
    Main.overview.hide();

    const primary = Main.layoutManager.primaryMonitor;
    return {
        unit, startedInOverview,
        monitorScale: global.display.get_monitor_scale(primary.index),
        topBar: {...bar, diamond},
        scenes: {desktop, overview},
    };
}

function findDescendant(actor, matches) {
    for (const child of actor.get_children()) {
        if (matches(child))
            return child;
        const found = findDescendant(child, matches);
        if (found)
            return found;
    }
    return null;
}

function darkStyleToggle() {
    return findDescendant(Main.panel.statusArea.quickSettings.menu.box,
        actor => actor.icon_name === DARK_STYLE_TOGGLE_ICON && 'checked' in actor);
}

// Emits the toggle's own clicked signal, which darkMode.js answers by writing color-scheme.
async function withDarkStyleOffInQuickSettings() {
    const toggle = darkStyleToggle();
    if (!toggle)
        return {error: `no Quick Settings toggle with the icon ${DARK_STYLE_TOGGLE_ICON}`};
    const checkedBefore = toggle.checked;
    toggle.emit('clicked', Clutter.BUTTON_PRIMARY);
    await settle();
    const {stylesheet, sheet, markerColor, sessionColorScheme, variant, colorSchemeSetting} = await report();
    return {
        toggle: {title: toggle.title, checkedBefore, checkedAfter: toggle.checked},
        stylesheet, sheet, markerColor, sessionColorScheme, variant, colorSchemeSetting,
    };
}

function actorCensus() {
    const counts = {};
    const visit = actor => {
        const type = actor.constructor.name;
        counts[type] = (counts[type] ?? 0) + 1;
        actor.get_children().forEach(visit);
    };
    visit(global.stage);
    return counts;
}

async function layerState(layerEnabled) {
    const {stylesheet, sheet, markerColor, sessionColorScheme, variant, safe} = await report();
    return {
        layerEnabled, stylesheet, markers: sheet?.markers ?? null, markerColor, sessionColorScheme,
        variant, safe, spotlightKey: spotlightKey(), actors: actorCensus(),
    };
}

// Each write reaches the layer's changed::layer-enabled handler, as gsettings set would.
async function withLayerCycles(cycles) {
    const settings = new Gio.Settings({schema_id: APEX_SCHEMA});
    dropStartupNotifications();
    await settle();
    const states = [await layerState(settings.get_boolean(LAYER_ENABLED_KEY))];
    for (let cycle = 1; cycle <= cycles; cycle++) {
        for (const on of [false, true]) {
            settings.set_boolean(LAYER_ENABLED_KEY, on);
            // eslint-disable-next-line no-await-in-loop
            await settle();
            // eslint-disable-next-line no-await-in-loop
            states.push({cycle, ...await layerState(settings.get_boolean(LAYER_ENABLED_KEY))});
        }
    }
    return {cycles, states};
}

// main.js connects to startup-complete only after importing this module, so a startup that
// completes during the import would never run the script and leave the shell up.
export function init() {
    if (Main.layoutManager._startingUp)
        return;
    console.log('APEXG2-LATE startup completed while main.js imported the probe');
    import(import.meta.url).then(self => Scripting.runPerfScript(self, GLib.getenv('SHELL_PERF_OUTPUT')));
}

export async function run() {
    await Scripting.sleep(REPORT_AFTER_MS);
    console.log(`APEXG2 ${JSON.stringify(await report())}`);

    if (GLib.getenv('G2_SCENES') === '1') {
        let result;
        try {
            result = await scenes();
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-SCENES ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_TURN_DARK_OFF') === '1') {
        let toggled;
        try {
            toggled = await withDarkStyleOffInQuickSettings();
        } catch (e) {
            toggled = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-TOGGLED ${JSON.stringify(toggled)}`);
    }

    const cycles = Number(GLib.getenv('G2_CYCLES') ?? '0');
    if (cycles > 0) {
        let result;
        try {
            result = await withLayerCycles(cycles);
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-CYCLES ${JSON.stringify(result)}`);
    }

    const wait = Number(GLib.getenv('PROBE_WAIT') ?? '0');
    if (wait > 0) {
        await Scripting.sleep(wait * 1000);
        console.log(`APEXG2-SURVIVED ${wait}s startingMarker=${startingMarker()}`);
    }
}
