// SPDX-License-Identifier: GPL-3.0-or-later

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Mtk from 'gi://Mtk';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as BoxPointer from 'resource:///org/gnome/shell/ui/boxpointer.js';
import * as Dialog from 'resource:///org/gnome/shell/ui/dialog.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';
import * as OverviewControls from 'resource:///org/gnome/shell/ui/overviewControls.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';
import * as Slider from 'resource:///org/gnome/shell/ui/slider.js';
import * as SwitcherPopup from 'resource:///org/gnome/shell/ui/switcherPopup.js';
import * as WindowManager from 'resource:///org/gnome/shell/ui/windowManager.js';
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
const PERF_HELPER_PING_S = 10;
const DEFERRED_WORK_TIMEOUT_MS = 21000;
const OSD_SETTLE_TIMEOUT_MS = 3000;
const CALIBRATION_PX = 100;
const INK_MAX_RGB_DISTANCE = 60;
const TRANSLUCENT_BAR_KEY = 'translucent-top-bar';
const DARK_STYLE_TOGGLE_ICON = 'dark-mode-symbolic';
const LARGE_TEXT_SCALING_FACTOR = 1.25;
const HIGH_CONTRAST_SHEET = 'resource:///org/gnome/shell/theme/gnome-shell-high-contrast.css';
const STRUCTURE_MARKER = '/*! apex-shell-structure */';
const LAYER_ENABLED_KEY = 'layer-enabled';
const SEARCH_HINT_KEY = 'search-hint-shown';
const DOCK_INTELLIHIDE_KEY = 'dock-intellihide';
const G2_WINDOW_TITLE = 'G2 maximised window';
const OSD_LEVEL = 0.62;
const POWER_PROFILE_WAIT_MS = 3000;
const MOTION_WINDOW_ID = 'io.github.apex_linux.G2Window';
const MOTION_WAIT_MS = 10000;
const MOTION_SETTLE_MS = 1000;
const OSD_GLYPH = 'audio-volume-medium-symbolic';
const SWITCHER_APPS = ['Text Editor', 'Terminal', 'Web', 'Files', 'Settings'];
const SWITCHER_ICON_SIZE = 96;

Gio._promisify(Shell.Screenshot.prototype, 'screenshot');
Gio._promisify(Gio.Subprocess.prototype, 'communicate_utf8_async');

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

// direct.sh freezes the wall clock with clock.c; the guard's shells keep the real one.
function clock() {
    if (GLib.getenv('G2_CLOCK_EPOCH') === null)
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
        searchHintShown: setting(APEX_SCHEMA, s => s.settings_schema.has_key(SEARCH_HINT_KEY)
            ? s.get_boolean(SEARCH_HINT_KEY) : 'no-key'),
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
        borderColor: hex(node.get_border_color(St.Side.TOP)),
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

function apexDock() {
    return findDescendant(Main.layoutManager.uiGroup, actor => actor.get_name() === 'apexDock');
}

// ApexDock's items in order: the box's apps, then dock.js's tail.
function dockItem(item, dock) {
    const iconSize = item.child?._delegate?.icon?.iconSize ?? null;
    if (item.has_style_class_name?.('apex-dock-separator'))
        return {kind: 'separator'};
    if (item === dock._showAppsIcon)
        return {kind: 'show-apps', iconSize, iconName: item._iconActor?.icon_name ?? null};
    if (item === dock.tailItems?.trash)
        return {kind: 'trash', iconSize};
    if (item.child?._delegate?.app)
        return {kind: 'app', name: item.child._delegate.app.get_name(), iconSize};
    return {kind: item.constructor.name};
}

// How far the overview's workspace view stays above the dock's background.
function dockClearance(unit) {
    const dock = apexDock();
    const workspaces = Main.overview._overview?.controls?._workspacesDisplay;
    if (!dock || !workspaces)
        return null;
    const view = boxOf(workspaces, unit);
    return round(boxOf(dock._background, unit).y - view.y - view.height);
}

function dockReport(unit) {
    const dock = apexDock();
    if (!dock)
        return null;
    const monitor = Main.layoutManager.primaryMonitor;
    const background = boxOf(dock._background, unit);
    const items = [...dock._box.get_children(), ...dock._dashContainer.get_children().slice(1)]
        .filter(item => item.visible);
    return {
        visible: dock.visible && dock.get_parent().visible,
        background,
        bottomGap: round((monitor.y + monitor.height) / unit.length - background.y - background.height),
        centreOffset: round(background.x + background.width / 2 - (monitor.x + monitor.width / 2) / unit.length),
        radius: round(dock._background.get_theme_node().get_border_radius(St.Corner.TOPLEFT) / unit.length),
        items: items.map(item => dockItem(item, dock)),
        overviewDashVisible: Main.overview.dash.visible,
    };
}

// The menu a right click opens on the dock's first app: stock's AppMenu, which offers the
// other GPU while switcheroo-control reports two.
async function dockAppMenu() {
    const icon = apexDock()?._box.get_children().find(item => item.child?._delegate?.app)?.child;
    if (!icon)
        return null;
    icon.popupMenu();
    await settle();
    const items = icon._menu._getMenuItems()
        .filter(item => item.visible && item.label?.text).map(item => item.label.text);
    icon._menu.close(BoxPointer.PopupAnimation.NONE);
    await settle();
    return {
        app: icon.app.get_name(),
        hasDualGpu: global.get_switcheroo_control()?.get_cached_property('HasDualGpu')?.unpack() ?? null,
        items,
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
            dock: captureBox(apexDock(), scale),
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

// The overview lays out in the primary monitor's work area, which starts below the bar.
function workArea(unit) {
    const {primaryIndex, primaryMonitor} = Main.layoutManager;
    const area = Main.layoutManager.getWorkAreaForMonitor(primaryIndex);
    return {y: round((area.y - primaryMonitor.y) / unit.length), height: round(area.height / unit.length)};
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

// A stock PopupMenu holding the board's rows: two adjacent rows, a separator, an icon row.
function openPopupMenu() {
    const anchor = new St.Widget({x: 400, y: 300, width: 1, height: 1});
    Main.uiGroup.add_child(anchor);
    const menu = new PopupMenu.PopupMenu(anchor, 0.5, St.Side.TOP);
    Main.uiGroup.add_child(menu.actor);
    const rows = [new PopupMenu.PopupMenuItem('Unpin'), new PopupMenu.PopupMenuItem('App Details')];
    const separator = new PopupMenu.PopupSeparatorMenuItem();
    const iconRow = new PopupMenu.PopupImageMenuItem('Home', 'user-home-symbolic');
    [...rows, separator, iconRow].forEach(item => menu.addMenuItem(item));
    menu.open(BoxPointer.PopupAnimation.NONE);
    return {
        measure: unit => {
            const line = separator.get_children().find(c => c.has_style_class_name('popup-separator-menu-item-separator'));
            return {
                content: styleOf(menu.box, unit),
                rows: [...rows, iconRow].map(row => ({
                    ...styleOf(row, unit),
                    hover: underPseudoClass(row, 'hover', () => paint(row.get_theme_node(), unit)),
                })),
                separator: {...boxOf(line, unit), background: hex(line.get_theme_node().get_background_color())},
                icon: lengthOrNull(iconRow._icon.get_theme_node(), 'icon-size', unit),
            };
        },
        close: () => {
            menu.close(BoxPointer.PopupAnimation.NONE);
            menu.destroy();
            anchor.destroy();
        },
    };
}

// Resolves at the stage's next painted frame, or false once the deadline (µs) passes.
function nextFrame(deadline) {
    return new Promise(resolve => {
        const timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT,
            Math.max(0, Math.ceil((deadline - GLib.get_monotonic_time()) / 1000)), () => {
                global.stage.disconnect(paintId);
                resolve(false);
                return GLib.SOURCE_REMOVE;
            });
        const paintId = global.stage.connect('after-paint', () => {
            global.stage.disconnect(paintId);
            GLib.source_remove(timeoutId);
            resolve(true);
        });
        global.stage.queue_redraw();
    });
}

// Whether condition held and actor's allocation stayed the same, non-empty, over two frames.
async function settledOverTwoFrames(actor, condition, timeoutMs) {
    const deadline = GLib.get_monotonic_time() + timeoutMs * 1000;
    let last = null;
    // eslint-disable-next-line no-await-in-loop
    while (await nextFrame(deadline)) {
        const box = actor.get_allocation_box();
        const now = condition() && box.get_width() > 0 && box.get_height() > 0
            ? [box.x1, box.y1, box.x2, box.y2].join() : null;
        if (now !== null && now === last)
            return true;
        last = now;
    }
    return false;
}

// An OSD still fading out from an earlier show resets itself, level and all, once the fade
// ends: it goes first. The new one would hide 1.5 s on, often before settle() returns.
async function openOsd() {
    const {primaryIndex, primaryMonitor} = Main.layoutManager;
    const window = Main.osdWindowManager._osdWindows[primaryIndex];
    window.cancel();
    const gone = await settledOverTwoFrames(global.stage, () => !window.visible, OSD_SETTLE_TIMEOUT_MS);
    Main.osdWindowManager.showOne(primaryIndex, Gio.ThemedIcon.new(OSD_GLYPH), null, OSD_LEVEL);
    if (window._hideTimeoutId)
        GLib.source_remove(window._hideTimeoutId);
    window._hideTimeoutId = 0;
    const settled = gone && await settledOverTwoFrames(window._hbox,
        () => window.visible && window._hbox.mapped && window._level.visible, OSD_SETTLE_TIMEOUT_MS);
    return {
        measure: unit => {
            if (!settled)
                return {error: 'the OSD never settled'};
            if (!window.visible)
                return {error: 'the OSD hid before it was measured'};
            const box = styleOf(window._hbox, unit);
            const levelNode = window._level.get_theme_node();
            return {
                box,
                bottomGap: round((primaryMonitor.y + primaryMonitor.height) / unit.length - box.y - box.height),
                icon: lengthOrNull(window._icon.get_theme_node(), 'icon-size', unit),
                level: {
                    ...boxOf(window._level, unit),
                    barHeight: lengthOrNull(levelNode, '-barlevel-height', unit),
                    background: hex(levelNode.get_color('-barlevel-background-color')),
                    active: hex(levelNode.get_color('-barlevel-active-background-color')),
                },
            };
        },
        close: () => window._hide(),
    };
}

// A normal-urgency notification with an action shows a banner under the bar.
function openBanner() {
    const source = new MessageTray.Source({title: 'G2 Updates', iconName: 'software-update-available-symbolic'});
    Main.messageTray.add(source);
    const notification = new MessageTray.Notification({
        source, title: 'Updates Ready', body: 'They start at the next restart.',
        gicon: Gio.ThemedIcon.new('system-software-install'), urgency: MessageTray.Urgency.NORMAL,
    });
    notification.addAction('Restart Now', () => {});
    source.addNotification(notification);
    return {
        measure: unit => {
            const message = Main.messageTray._banner;
            if (!message)
                return {error: 'no banner'};
            const find = styleClass => findDescendant(message, a => a.has_style_class_name?.(styleClass));
            const box = styleOf(message, unit);
            return {
                box,
                topGap: round(box.y - (Main.layoutManager.primaryMonitor.y + Main.panel.height) / unit.length),
                header: styleOf(find('message-header'), unit),
                title: styleOf(find('message-title'), unit),
                body: styleOf(find('message-body'), unit),
                icon: lengthOrNull(find('message-icon').get_theme_node(), 'icon-size', unit),
                close: styleOf(find('message-close-button'), unit),
                actions: styleOf(find('message-action-bin'), unit),
                button: {
                    ...styleOf(find('notification-button'), unit),
                    minHeight: lengthOrNull(find('notification-button').get_theme_node(), 'min-height', unit),
                },
            };
        },
        close: () => source.destroy(),
    };
}

// Open together as on board 16; G2_SURFACE_SCENES=1 also captures them.
async function shellSurfaces(unit) {
    const opened = {popupMenu: openPopupMenu(), osd: await openOsd(), banner: openBanner()};
    try {
        await settle();
        const scene = GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture('surfaces') : null;
        if (scene)
            delete scene.bytes;
        return {scene, ...Object.fromEntries(Object.entries(opened).map(([name, s]) => [name, s.measure(unit)]))};
    } finally {
        Object.values(opened).forEach(s => s.close());
        await settle();
    }
}

// A slider never shows in the container (no audio, no backlight): one in a stand-in row.
function quickSlider(unit) {
    const box = new St.BoxLayout({style_class: 'popup-menu-content quick-settings'});
    const row = new St.BoxLayout();
    const slider = new Slider.Slider(OSD_LEVEL);
    row.add_child(slider);
    box.add_child(new St.Bin({style_class: 'quick-slider', child: row}));
    return withStyledActor(box, () => {
        const node = slider.get_theme_node();
        return {
            spacing: lengthOrNull(row.get_theme_node(), 'spacing', unit),
            trackHeight: lengthOrNull(node, '-barlevel-height', unit),
            track: hex(node.get_color('-barlevel-background-color')),
            fill: hex(node.get_color('-barlevel-active-background-color')),
            handleRadius: lengthOrNull(node, '-slider-handle-radius', unit),
            handle: hex(node.get_foreground_color()),
        };
    });
}

function quickToggle(toggle, unit) {
    const box = toggle.get_first_child();
    const [title, subtitle] = findDescendant(box, a => a.has_style_class_name?.('quick-toggle-title'))
        ?.get_parent().get_children() ?? [];
    return {
        ...styleOf(toggle, unit),
        box: styleOf(box, unit),
        icon: lengthOrNull(findDescendant(box, a => a.has_style_class_name?.('quick-toggle-icon')).get_theme_node(), 'icon-size', unit),
        title: styleOf(title, unit),
        subtitle: subtitle?.visible ? styleOf(subtitle, unit) : null,
        hover: underPseudoClass(toggle, 'hover', () => paint(toggle.get_theme_node(), unit)),
    };
}

// The fixtures' Wi-Fi makes the network toggle checked, with a menu: board 17 opens it.
async function quickSettings(unit) {
    const {quickSettings: indicator} = Main.panel.statusArea;
    const {menu} = indicator;
    const grid = findDescendant(menu.box, a => a.has_style_class_name?.('quick-settings-grid'));
    const byType = name => findDescendant(menu.box, a => a.constructor.name === name);
    menu.open(BoxPointer.PopupAnimation.NONE);
    const wifi = byType('NMWirelessToggle');
    try {
        await settle();
        wifi?.menu.open(BoxPointer.PopupAnimation.NONE);
        await settle();
        const scene = GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture('quick-settings') : null;
        if (scene)
            delete scene.bytes;
        const system = byType('SystemItem');
        const wifiToggle = wifi && findDescendant(wifi, a => a.has_style_class_name?.('quick-toggle'));
        const menuButton = wifi && findDescendant(wifi, a => a.has_style_class_name?.('quick-toggle-menu-button'));
        const header = wifi && findDescendant(wifi.menu.box, a => a.has_style_class_name?.('header'));
        const find = (root, styleClass) => findDescendant(root, a => a.has_style_class_name?.(styleClass));
        return {
            scene,
            box: styleOf(menu.box, unit),
            grid: {
                rows: lengthOrNull(grid.get_theme_node(), 'spacing-rows', unit),
                columns: lengthOrNull(grid.get_theme_node(), 'spacing-columns', unit),
            },
            system: {
                ...boxOf(system, unit),
                spacing: lengthOrNull(system.get_first_child().get_theme_node(), 'spacing', unit),
                battery: quickToggle(byType('PowerToggle'), unit),
                screenshot: {
                    ...styleOf(byType('ScreenshotItem'), unit),
                    icon: lengthOrNull(byType('ScreenshotItem').get_first_child().get_theme_node(), 'icon-size', unit),
                },
            },
            wifi: wifi ? {
                ...boxOf(wifi, unit),
                toggle: quickToggle(wifiToggle, unit),
                separator: boxOf(find(wifi, 'quick-toggle-separator'), unit),
                menuButton: styleOf(menuButton, unit),
            } : null,
            unchecked: quickToggle(byType('DoNotDisturbToggle'), unit),
            slider: quickSlider(unit),
            wifiMenu: wifi ? {
                box: styleOf(wifi.menu.box, unit),
                header: styleOf(header, unit),
                headerIcon: {
                    ...styleOf(find(header, 'icon'), unit),
                    iconSize: lengthOrNull(find(header, 'icon').get_theme_node(), 'icon-size', unit),
                },
                title: styleOf(find(header, 'title'), unit),
                subtitle: styleOf(find(header, 'subtitle'), unit),
                rows: wifi.menu._getMenuItems().filter(i => i.visible && i.label?.text).map(i => styleOf(i, unit)),
                rowHover: (row => row && underPseudoClass(row, 'hover', () => paint(row.get_theme_node(), unit)))(
                    wifi.menu._getMenuItems().find(i => i.visible && i.label?.text)),
                separator: styleOf(wifi.menu._getMenuItems().find(i => i instanceof PopupMenu.PopupSeparatorMenuItem), unit),
            } : null,
        };
    } finally {
        wifi?.menu.close(BoxPointer.PopupAnimation.NONE);
        menu.close(BoxPointer.PopupAnimation.NONE);
        await settle();
    }
}

// The quick-settings feature: the toggles' order, Power Mode lit, On/Off subtitles; then two
// clicks on Power Mode, which stock answers by switching to the last profile and back.
async function quickSettingsLayer() {
    const indicator = Main.panel.statusArea.quickSettings;
    // Without a VPN connection the VPN toggle is hidden and has no title.
    const name = t => t.constructor.name === 'NMVpnToggle' ? 'VPN' : t.title;
    const toggles = indicator.menu._grid.get_children().filter(t => 'checked' in t && name(t));
    const power = indicator._powerProfiles?.quickSettingsItems[0] ?? null;
    const dnd = toggles.find(t => t.constructor.name === 'DoNotDisturbToggle');
    const powerState = () => power && {
        lit: power.has_style_class_name('apex-lit'),
        checked: power.checked,
        subtitle: power.subtitle,
        visible: power.visible,
    };
    const clickPower = async () => {
        const before = power.checked;
        power.emit('clicked', Clutter.BUTTON_PRIMARY);
        for (let waited = 0; power.checked === before && waited < POWER_PROFILE_WAIT_MS; waited += 50)
            // eslint-disable-next-line no-await-in-loop
            await Scripting.sleep(50);
        await settle();
        return powerState();
    };
    const state = {
        order: toggles.map(t => ({title: name(t), visible: t.visible})),
        power: powerState(),
        pillShowsPower: indicator._powerProfiles?.get_parent() === indicator._indicators &&
            indicator._powerProfiles.visible,
        dndSubtitle: dnd?.subtitle ?? null,
    };
    if (power?.visible) {
        state.switched = await clickPower();
        state.back = await clickPower();
    }
    return state;
}

// G2 opens no windows, so the switcher is a stock SwitcherList of AppIcon-shaped items.
async function windowSwitcher(unit) {
    const list = new SwitcherPopup.SwitcherList(true);
    const apps = SWITCHER_APPS.map(name => {
        const app = new St.BoxLayout({style_class: 'alt-tab-app', orientation: Clutter.Orientation.VERTICAL});
        app.add_child(new St.Icon({icon_name: 'application-x-executable', icon_size: SWITCHER_ICON_SIZE}));
        app.add_child(new St.Label({text: name, x_align: Clutter.ActorAlign.CENTER}));
        list.addItem(app, app.get_last_child());
        return app;
    });
    Main.uiGroup.add_child(list);
    try {
        const [, width] = list.get_preferred_width(-1);
        const [, height] = list.get_preferred_height(width);
        const {primaryMonitor: monitor} = Main.layoutManager;
        list.set_position(monitor.x + Math.floor((monitor.width - width) / 2), monitor.y + Math.floor((monitor.height - height) / 2));
        list.highlight(1);
        await settle();
        const scene = GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture('switcher') : null;
        if (scene)
            delete scene.bytes;
        const label = apps[0].get_last_child();
        return {
            scene,
            list: styleOf(list, unit),
            spacing: lengthOrNull(list._list.get_theme_node(), 'spacing', unit),
            items: list._items.map(item => styleOf(item, unit)),
            app: {spacing: lengthOrNull(apps[0].get_theme_node(), 'spacing', unit), label: font(label.get_theme_node(), unit)},
        };
    } finally {
        list.destroy();
        await settle();
    }
}

// A stock ModalDialog shaped like polkit's: title, description, password entry, two buttons.
async function modalDialog(unit) {
    const dialog = new ModalDialog.ModalDialog({styleClass: 'prompt-dialog'});
    const content = new Dialog.MessageDialogContent({
        title: 'Authentication Required',
        description: 'Booting the previous version needs an administrator password.',
    });
    const entry = new St.PasswordEntry({style_class: 'prompt-dialog-password-entry', hint_text: 'Password', can_focus: true});
    content.add_child(entry);
    dialog.contentLayout.add_child(content);
    const buttons = [
        dialog.addButton({label: 'Cancel', action: () => {}, key: Clutter.KEY_Escape}),
        dialog.addButton({label: 'Authenticate', action: () => {}, default: true}),
    ];
    dialog.open();
    try {
        await settle();
        global.stage.set_key_focus(null);
        const scene = GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture('dialog') : null;
        if (scene)
            delete scene.bytes;
        const find = styleClass => findDescendant(content, a => a.has_style_class_name?.(styleClass));
        const endSession = withStyledActor(new St.BoxLayout({style_class: 'modal-dialog end-session-dialog'}),
            node => lengthOrNull(node, 'width', unit));
        return {
            scene,
            box: styleOf(dialog.dialogLayout._dialog, unit),
            contentSpacing: lengthOrNull(dialog.contentLayout.get_theme_node(), 'spacing', unit),
            textSpacing: lengthOrNull(content.get_theme_node(), 'spacing', unit),
            title: styleOf(find('message-dialog-title'), unit),
            description: styleOf(find('message-dialog-description'), unit),
            entry: {
                ...styleOf(entry, unit),
                focus: underPseudoClass(entry, 'focus', () => paint(entry.get_theme_node(), unit)),
            },
            buttons: buttons.map(b => ({
                ...styleOf(b, unit),
                default: b.has_style_pseudo_class('default'),
                hover: underPseudoClass(b, 'hover', () => paint(b.get_theme_node(), unit)),
            })),
            endSessionWidth: endSession,
        };
    } finally {
        dialog.close();
        dialog.destroy();
        await settle();
    }
}

// Two low-urgency notifications fill the list without banners; the menu shows the fixed date.
async function calendarMenu(unit) {
    const source = new MessageTray.Source({title: 'G2 Updates', iconName: 'software-update-available-symbolic'});
    Main.messageTray.add(source);
    for (const title of ['Update ready', 'Design review']) {
        source.addNotification(new MessageTray.Notification({
            source, title, body: 'Starts after the next restart.', urgency: MessageTray.Urgency.LOW,
        }));
    }
    const {menu} = Main.panel.statusArea.dateMenu;
    menu.open(BoxPointer.PopupAnimation.NONE);
    try {
        await settle();
        const scene = GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture('datemenu') : null;
        if (scene)
            delete scene.bytes;
        const find = (root, styleClass) => findDescendant(root, a => a.has_style_class_name?.(styleClass));
        const box = menu.box;
        const message = findDescendant(box, a => a.constructor.name === 'NotificationMessage');
        const calendar = find(box, 'calendar');
        const days = calendar.get_children().filter(a => a.has_style_class_name?.('calendar-day'));
        const day = classes => days.find(d => classes.every(c => d.has_style_class_name(c)) &&
            !d.has_style_class_name('calendar-today') && (classes.includes('calendar-other-month') || !d.has_style_class_name('calendar-other-month')));
        const events = find(box, 'events-button');
        return {
            scene,
            box: styleOf(box, unit),
            area: {spacing: lengthOrNull(find(box, 'message-list').get_parent().get_theme_node(), 'spacing', unit)},
            list: styleOf(find(box, 'message-list'), unit),
            column: styleOf(find(box, 'datemenu-calendar-column'), unit),
            message: {
                ...styleOf(message, unit),
                marginBottom: round(message.get_theme_node().get_margin(St.Side.BOTTOM) / unit.length),
                header: styleOf(find(message, 'message-header'), unit),
                title: styleOf(find(message, 'message-title'), unit),
                body: styleOf(find(message, 'message-body'), unit),
                close: styleOf(find(message, 'message-close-button'), unit),
                icon: lengthOrNull(find(message, 'message-icon').get_theme_node(), 'icon-size', unit),
            },
            controls: styleOf(find(box, 'message-list-controls'), unit),
            clear: styleOf(find(box, 'message-list-clear-button'), unit),
            dayLabel: styleOf(find(box, 'day-label'), unit),
            dateLabel: styleOf(find(box, 'date-label'), unit),
            calendar: styleOf(calendar, unit),
            monthLabel: styleOf(find(calendar, 'calendar-month-label'), unit),
            pager: styleOf(find(calendar, 'pager-button'), unit),
            heading: styleOf(find(calendar, 'calendar-day-heading'), unit),
            day: styleOf(day(['calendar-weekday']), unit),
            weekend: styleOf(day(['calendar-weekend']), unit),
            otherMonth: styleOf(day(['calendar-other-month']), unit),
            today: styleOf(days.find(d => d.has_style_class_name('calendar-today')), unit),
            events: styleOf(events, unit),
            eventsTitle: styleOf(find(events, 'events-title'), unit),
        };
    } finally {
        menu.close(BoxPointer.PopupAnimation.NONE);
        source.destroy();
        await settle();
    }
}

// Board 38's rows, from providers of the probe's own: G2's image has no files or settings
// to find, so a real query would draw nothing to measure.
const CALCULATOR = 'org.gnome.Calculator.desktop';
const SPOTLIGHT_ROWS = {
    [CALCULATOR]: [{id: '2880 / 1.5', name: '2880 / 1.5', description: ' = 1920', clipboardText: '1920'}],
    'applications': [
        {id: 'org.gnome.DiskUtility.desktop', name: 'Disks', description: 'Manage drives and media', icon: 'drive-harddisk'},
        {id: 'org.gnome.baobab.desktop', name: 'Disk Usage Analyzer', description: 'Check folder sizes and available disk space', icon: 'drive-harddisk'},
        {id: CALCULATOR, name: 'Calculator', description: 'Perform arithmetic, scientific or financial calculations', icon: 'accessories-calculator'},
    ],
    'org.gnome.Settings.desktop': [
        {id: 'about', name: 'About', description: 'System · name, memory and disk capacity', icon: 'help-about-symbolic'},
        {id: 'privacy', name: 'File History & Trash', description: 'Privacy & Security', icon: 'user-trash-symbolic', keywords: 'disk'},
        {id: 'removable', name: 'Removable Media', description: 'Apps · what happens when a disk is plugged in', icon: 'media-removable-symbolic'},
        {id: 'storage', name: 'Disk Encryption', description: 'Privacy & Security', icon: 'drive-harddisk-symbolic'},
    ],
    'org.gnome.Nautilus.desktop': [
        {id: 'csv', name: 'disk-usage-2026-10.csv', description: '~/Documents', icon: 'text-x-generic'},
        {id: 'png', name: 'disk-unlock-board.png', description: '~/Pictures/Screenshots', icon: 'image-x-generic'},
        {id: 'images', name: 'Disk Images', description: '~/Downloads', icon: 'folder'},
        {id: 'md', name: 'diskspace-notes.md', description: '~/apex/docs', icon: 'text-x-generic'},
        {id: 'old', name: 'disk-old.md', description: '~/apex/docs', icon: 'text-x-generic'},
    ],
};

function spotlightMatches(providerId, row, terms) {
    if (providerId === CALCULATOR)
        return row.id === terms.join(' ');
    const text = `${row.name} ${row.description} ${row.keywords ?? ''}`.toLowerCase();
    return terms.every(t => text.includes(t));
}

function spotlightProviders() {
    return new Map(Object.entries(SPOTLIGHT_ROWS).map(([id, rows]) => [id, {
        id,
        appInfo: {get_icon: () => Gio.ThemedIcon.new('accessories-calculator')},
        getInitialResultSet: terms => Promise.resolve(rows.filter(r => spotlightMatches(id, r, terms)).map(r => r.id)),
        filterResults: (ids, max) => ids.slice(0, max),
        getResultMetas: ids => Promise.resolve(rows.filter(r => ids.includes(r.id)).map(r => ({
            ...r, createIcon: size => new St.Icon({icon_name: r.icon ?? 'image-missing', icon_size: size}),
        }))),
        activateResult: () => {},
    }]));
}

async function spotlightScene(popup, name, text) {
    popup.panel.get_children()[0].get_children()[1].set_text(text);
    await settle();
    global.stage.set_key_focus(null);
    const scene = name && GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture(`spotlight-${name}`) : null;
    if (scene)
        delete scene.bytes;
    return scene;
}

// Board 38's four scenes: search, calculator, copied and empty, through Spotlight's own popup.
async function spotlightStyle(unit) {
    if ((await apexHooks())?.safe() !== false)
        return null;
    let Popup, Toast;
    try {
        ({Popup} = await import('resource:///org/gnome/shell/ui/apex/spotlight/popup.js'));
        Toast = await import('resource:///org/gnome/shell/ui/apex/spotlight/toast.js');
    } catch {
        return null;
    }
    const {primaryMonitor: monitor} = Main.layoutManager;
    const popup = new Popup(spotlightProviders, 0);
    popup.open();
    try {
        const captured = {};
        captured.empty = await spotlightScene(popup, 'empty', '');
        const fieldOnly = popup.panel.get_children().filter(a => a.visible).length === 1;
        captured.search = await spotlightScene(popup, 'search', 'disk');
        const [field, results] = popup.panel.get_children();
        const rows = results.get_children().filter(a => a.has_style_class_name('apex-spotlight-row'));
        const row = actor => {
            const [icon, text, action] = actor.get_children();
            const [title, subtitle] = text.get_children();
            return {
                ...styleOf(actor, unit), icon: styleOf(icon, unit), text: styleOf(text, unit),
                title: {...styleOf(title, unit), text: title.get_text()},
                subtitle: {...styleOf(subtitle, unit), text: subtitle.get_text()},
                action: {
                    ...styleOf(action, unit),
                    verb: {...styleOf(action.get_children()[0], unit), text: action.get_children()[0].get_text()},
                    chip: styleOf(action.get_children()[1], unit),
                },
            };
        };
        const headers = results.get_children().filter(a => a.has_style_class_name('apex-spotlight-header'));
        const measured = {
            fieldOnly,
            panel: {...styleOf(popup.panel, unit), top: round((popup.panel.get_transformed_position()[1] - monitor.y) / unit.length)},
            field: styleOf(field, unit),
            glyph: {...styleOf(field.get_children()[0], unit), size: lengthOrNull(field.get_children()[0].get_theme_node(), 'icon-size', unit)},
            entry: {
                ...styleOf(field.get_children()[1], unit),
                hint: hex(field.get_children()[1].get_hint_actor().get_theme_node().get_foreground_color()),
            },
            results: styleOf(results, unit),
            headers: headers.map(h => ({...styleOf(h, unit), tracking: round(h.get_theme_node().get_letter_spacing() / unit.length)})),
            sections: headers.map(h => h.get_child().get_text()),
            rows: rows.map(row),
            selected: rows.map(r => r.has_style_pseudo_class('selected')),
        };
        captured.calculator = await spotlightScene(popup, 'calculator', '2880 / 1.5');
        const [, calculator] = popup.panel.get_children();
        measured.calculator = {
            sections: calculator.get_children().filter(a => a.has_style_class_name('apex-spotlight-header')).map(h => h.get_child().get_text()),
            row: row(calculator.get_children().find(a => a.has_style_class_name('apex-spotlight-row'))),
        };
        captured.none = await spotlightScene(popup, 'none', 'zzz');
        measured.empty = styleOf(popup.panel.get_children()[2], unit);
        await spotlightScene(popup, null, '2880 / 1.5');
        popup.activateSelected();
        await settle();
        const scene = GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture('spotlight-copied') : null;
        if (scene)
            delete scene.bytes;
        captured.copied = scene;
        const pill = Toast.current()?.get_first_child();
        if (pill) {
            const check = pill.get_first_child();
            const box = styleOf(pill, unit);
            measured.toast = {
                box, label: {...styleOf(pill.get_last_child(), unit), text: pill.get_last_child().get_text()},
                bottomGap: round((monitor.y + monitor.height) / unit.length - box.y - box.height),
                check: {...styleOf(check, unit), icon: lengthOrNull(check.get_child().get_theme_node(), 'icon-size', unit)},
            };
        }
        measured.closedOnCopy = !popup.isOpen;
        return {scenes: captured, ...measured};
    } finally {
        popup.destroy();
        await settle();
    }
}

// Text typed in the overview reaches its search entry; patch 0013 hands it to Spotlight.
async function overviewSearch() {
    const feature = await import('resource:///org/gnome/shell/ui/apex/spotlight/feature.js').catch(() => null);
    const popup = feature?.popup();
    if (!popup)
        return null;
    const entry = Main.overview._overview.controls._searchEntry;
    entry.set_text('disk');
    await settle();
    const result = {
        opened: popup.isOpen,
        text: popup.isOpen ? popup.panel.get_children()[0].get_children()[1].get_text() : null,
        overviewText: entry.get_text(),
    };
    popup.close();
    await settle();
    return result;
}

// Board 36: in the app grid the overview's pill is the launcher's, which filters the grid.
async function launcherSearch(unit) {
    const feature = await import('resource:///org/gnome/shell/ui/apex/spotlight/feature.js').catch(() => null);
    const popup = feature?.popup();
    if (!popup)
        return null;
    const {controls} = Main.overview._overview;
    const entry = controls._searchEntry;
    const results = () => controls._appDisplay.get_children().find(a => a.name === 'apexLauncherResults');
    const scene = async name => {
        await settle();
        global.stage.set_key_focus(null);
        const captured = GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture(name) : null;
        if (captured)
            delete captured.bytes;
        return captured;
    };
    // The overview is up already, where showApps() does nothing: the button is what a click sets.
    Main.overview.dash.showAppsButton.checked = true;
    try {
        await settle();
        const pill = {...styleOf(entry, unit), hint: entry.hint_text};
        entry.set_text('files');
        const filtered = await scene('launcher');
        const icons = results()?.get_children()[0].get_children() ?? [];
        const found = {
            appDisplay: boxOf(controls._appDisplay, unit),
            results: results() ? boxOf(results(), unit) : null,
            gridHidden: !controls._appDisplay._box.visible,
            names: icons.map(icon => icon.app.get_name()),
            firstSelected: icons[0]?.has_style_pseudo_class('selected') ?? false,
            spotlightOpen: popup.isOpen,
        };
        entry.set_text('zzzqx');
        const none = await scene('launcher-none');
        const empty = results()?.get_children()[1];
        const [title, hint] = empty?.get_children() ?? [];
        const emptyTop = empty ? round(empty.get_transformed_position()[1] / unit.length) - found.results.y : null;
        return {
            scenes: {filtered, none}, pill, found,
            empty: empty ? {...styleOf(empty, unit), top: emptyTop, title: {...styleOf(title, unit), text: title.text}, hint: {...styleOf(hint, unit), text: hint.text}} : null,
        };
    } finally {
        entry.set_text('');
        Main.overview.dash.showAppsButton.checked = false;
        popup.close();
        await settle();
    }
}

// What the overview draws without windows; a caption and a search section are stand-ins.
function overviewStyle(unit) {
    const {controls} = Main.overview._overview;
    const thumbnailsBox = controls._thumbnailsBox;
    const caption = new St.Label({style_class: 'window-caption', text: 'Home'});
    const section = new St.BoxLayout({style_class: 'search-section-content'});
    Main.layoutManager.overviewGroup.add_child(caption);
    Main.layoutManager.overviewGroup.add_child(section);
    try {
        return {
            group: paint(Main.layoutManager.overviewGroup.get_theme_node(), unit),
            search: {
                ...styleOf(controls._searchEntry, unit),
                icon: lengthOrNull(controls._searchEntry.primary_icon?.get_theme_node() ?? controls._searchEntry.get_theme_node(), 'icon-size', unit),
                focus: underPseudoClass(controls._searchEntry, 'focus', () => ({
                    ...paint(controls._searchEntry.get_theme_node(), unit),
                    borderColor: hex(controls._searchEntry.get_theme_node().get_border_color(St.Side.TOP)),
                })),
            },
            thumbnailsSpacing: lengthOrNull(thumbnailsBox.get_theme_node(), 'spacing', unit),
            thumbnail: thumbnailsBox._thumbnails?.[0] ? styleOf(thumbnailsBox._thumbnails[0], unit) : null,
            indicator: thumbnailsBox._indicator ? styleOf(thumbnailsBox._indicator, unit) : null,
            caption: {...styleOf(caption, unit), minHeight: lengthOrNull(caption.get_theme_node(), 'min-height', unit)},
            section: styleOf(section, unit),
        };
    } finally {
        caption.destroy();
        section.destroy();
    }
}

// What the overview feature changes, in the empty overview the scene captured. With no
// window to show a title, its hook's answer stands in.
async function overviewLayer(unit) {
    const {controls} = Main.overview._overview;
    const view = controls._workspacesDisplay._getPrimaryView();
    const workspace = view._workspaces[global.workspace_manager.get_active_workspace_index()];
    const empty = workspace.get_children().find(a => a.has_style_class_name?.('apex-workspace-empty'));
    const thumbnailsBox = controls._thumbnailsBox;
    const hooks = await apexHooks();
    return {
        titleVisible: hooks?.value('window-title-visible', false) ?? null,
        thumbnailsThreshold: hooks?.value('thumbnails-threshold', null) ?? null,
        thumbnails: {
            maxScale: thumbnailsBox.maxThumbnailScale,
            first: thumbnailsBox._thumbnails?.[0] ? boxOf(thumbnailsBox._thumbnails[0], unit) : null,
        },
        workspace: {
            ...boxOf(workspace, unit),
            background: workspace._background.visible,
            empty: empty ? {...styleOf(empty, unit), visible: empty.visible, text: empty.text} : null,
        },
    };
}

function standInStyle(styleClass, parentClass, unit) {
    const parent = new St.BoxLayout({style_class: parentClass ?? ''});
    const actor = new St.Widget({style_class: styleClass});
    parent.add_child(actor);
    return withStyledActor(parent, () => {
        const node = actor.get_theme_node();
        const [type] = node.get_background_gradient();
        return {
            width: lengthOrNull(node, 'width', unit), height: lengthOrNull(node, 'height', unit),
            radius: round(node.get_border_radius(St.Corner.TOPLEFT) / unit.length),
            background: hex(node.get_background_color()), gradient: type,
        };
    });
}

// The launcher of the fixture image: a few apps and the System folder, opened as board 36 does.
async function appGrid(unit) {
    const {showAppsButton} = Main.overview.dash;
    const appDisplay = Main.overview._overview.controls._appDisplay;
    showAppsButton.checked = true;
    let folder = null;
    try {
        await settle();
        const tiles = appDisplay._orderedItems ?? [];
        const app = tiles.find(t => t.constructor.name === 'AppIcon');
        folder = tiles.find(t => t.constructor.name === 'FolderIcon');
        const label = app ? firstVisibleLabel(app) : null;
        const measured = {
            app: app ? {
                ...styleOf(app, unit),
                labelFont: label ? font(label.get_theme_node(), unit) : null,
                spacing: lengthOrNull(findDescendant(app, a => a.has_style_class_name?.('overview-icon'))
                    .get_first_child().get_theme_node(), 'spacing', unit),
                hover: underPseudoClass(app, 'hover', () => paint(app.get_theme_node(), unit)),
                focus: underPseudoClass(app, 'focus', () => paint(app.get_theme_node(), unit)),
            } : null,
            folder: folder ? styleOf(folder, unit) : null,
            strip: round(Main.overview._overview.controls.layoutManager
                .getWorkspacesBoxForState(OverviewControls.ControlsState.APP_GRID).get_height() / unit.length),
            box: boxOf(appDisplay, unit),
            searchBottom: (b => b.y + b.height)(boxOf(Main.overview._overview.controls._searchEntry, unit)),
            grid: {
                columns: appDisplay._grid.layout_manager.columns_per_page,
                rows: appDisplay._grid.layout_manager.rows_per_page,
                iconSize: app?.icon.iconSize ?? null,
            },
            runningDot: standInStyle('app-grid-running-dot', null, unit),
            pageIndicator: standInStyle('page-indicator-icon', 'page-indicator', unit),
            pageHint: standInStyle('page-navigation-hint next', null, unit),
        };
        if (folder) {
            folder.open();
            await settle();
            const dialog = findDescendant(Main.layoutManager.overviewGroup, a => a.has_style_class_name?.('app-folder-dialog'));
            measured.scene = GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture('appgrid') : null;
            if (measured.scene)
                delete measured.scene.bytes;
            measured.dialog = dialog ? {
                ...styleOf(dialog, unit),
                title: styleOf(findDescendant(dialog, a => a.has_style_class_name?.('folder-name-label')), unit),
                button: styleOf(findDescendant(dialog, a => a.has_style_class_name?.('icon-button')), unit),
            } : null;
        }
        return measured;
    } finally {
        folder?._dialog?.popdown();
        showAppsButton.checked = false;
        await settle();
    }
}

// G2 opens no window to drag to an edge, so a stand-in actor in the window group plays the
// window and the stock preview opens over the left half of the work area.
async function tilePreview(unit) {
    const {primaryIndex, primaryMonitor} = Main.layoutManager;
    const area = Main.layoutManager.getWorkAreaForMonitor(primaryIndex);
    const stand = new Clutter.Actor({x: area.x, y: area.y, width: area.width / 2, height: area.height});
    global.window_group.add_child(stand);
    const window = {
        get_compositor_private: () => stand,
        get_frame_rect: () => new Mtk.Rectangle({x: area.x + 100, y: area.y + 100, width: 600, height: 400}),
    };
    const preview = new WindowManager.TilePreview();
    try {
        preview.open(window, new Mtk.Rectangle({x: area.x, y: area.y, width: area.width / 2, height: area.height}), primaryIndex);
        await settle();
        const scene = GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture('tile-preview') : null;
        if (scene)
            delete scene.bytes;
        return {
            scene,
            tile: {
                x: round((area.x - primaryMonitor.x) / unit.length), y: round((area.y - primaryMonitor.y) / unit.length),
                width: round(area.width / 2 / unit.length), height: round(area.height / unit.length),
            },
            preview: styleOf(preview, unit),
        };
    } finally {
        preview.destroy();
        stand.destroy();
    }
}

// The stock screenshot UI in its selection mode, as board 19 opens it, then its screen
// mode; G2 opens no windows, so a checked window frame is a stand-in.
async function screenshotUI(unit) {
    const ui = Main.screenshotUI;
    await ui.open();
    try {
        await settle();
        global.stage.set_key_focus(null);
        const scene = GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture('screenshot') : null;
        if (scene)
            delete scene.bytes;
        const types = [ui._selectionButton, ui._screenButton, ui._windowButton];
        const typeContent = types[0].get_child();
        const circle = ui._captureButton.get_child();
        const area = ui._areaSelector;
        const measured = {
            scene,
            monitorHeight: round(Main.layoutManager.primaryMonitor.height / unit.length),
            panel: styleOf(ui._panel, unit),
            close: styleOf(ui._closeButton, unit),
            types: types.map(b => ({...styleOf(b, unit), checked: b.checked})),
            typeContent: {
                spacing: lengthOrNull(typeContent.get_theme_node(), 'spacing', unit),
                icon: boxOf(typeContent.get_first_child(), unit),
                labelFont: font(typeContent.get_last_child().get_theme_node(), unit),
            },
            checkedType: underPseudoClass(types[1], 'checked', () => paint(types[1].get_theme_node(), unit)),
            pointer: {
                ...styleOf(ui._showPointerButton, unit),
                checked: underPseudoClass(ui._showPointerButton, 'checked', () => ({
                    ...paint(ui._showPointerButton.get_theme_node(), unit),
                    foreground: hex(ui._showPointerButton.get_theme_node().get_foreground_color()),
                })),
            },
            capture: {
                ...styleOf(ui._captureButton, unit),
                circle: styleOf(circle, unit),
                cast: underPseudoClass(ui._captureButton, 'cast', () => {
                    const node = circle.get_theme_node();
                    return {
                        margin: lengthOrNull(node, 'margin', unit),
                        radius: round(node.get_border_radius(St.Corner.TOPLEFT) / unit.length),
                        background: hex(node.get_background_color()),
                    };
                }),
            },
            switcher: styleOf(ui._shotCastContainer, unit),
            shot: {...styleOf(ui._shotButton, unit), checked: ui._shotButton.checked},
            shade: styleOf(area._areaIndicator._topRect, unit),
            selection: styleOf(area._areaIndicator._selectionRect, unit),
            handle: styleOf(area._topLeftHandle, unit),
        };
        ui._screenButton.checked = true;
        await settle();
        const screen = ui._screenSelectors[Main.layoutManager.primaryIndex];
        measured.screen = {...styleOf(screen, unit), checked: screen.checked};
        measured.windowSelector = styleOf(ui._windowSelectors[Main.layoutManager.primaryIndex], unit);
        const frame = new St.Widget({style_class: 'screenshot-ui-window-selector-window-border'});
        const window = new St.Widget({style_class: 'screenshot-ui-window-selector-window'});
        window.add_child(frame);
        measured.windowFrame = withStyledActor(window, () => underPseudoClass(window, 'checked', () => styleOf(frame, unit)));
        return measured;
    } finally {
        ui.close(true);
        await settle();
    }
}

// Surfaces G2 never opens, as nested stand-ins: each class is the parent of the next.
function nestedStyle(classes, unit, Leaf = St.Widget) {
    const actors = classes.map((styleClass, i) => i === classes.length - 1
        ? new Leaf({style_class: styleClass}) : new St.BoxLayout({style_class: styleClass}));
    actors.slice(1).forEach((actor, i) => actors[i].add_child(actor));
    const leaf = actors[actors.length - 1];
    return withStyledActor(actors[0], () => {
        const node = leaf.get_theme_node();
        return {
            ...paint(node, unit),
            foreground: hex(node.get_foreground_color()),
            border: sides(side => node.get_border_width(side), unit),
            borderColor: hex(node.get_border_color(St.Side.TOP)),
            radius: round(node.get_border_radius(St.Corner.TOPLEFT) / unit.length),
            minHeight: lengthOrNull(node, 'min-height', unit),
            hover: underPseudoClass(leaf, 'hover', () => paint(leaf.get_theme_node(), unit)),
            active: underPseudoClass(leaf, 'active', () => paint(leaf.get_theme_node(), unit)),
            focus: underPseudoClass(leaf, 'focus', () => paint(leaf.get_theme_node(), unit)),
        };
    });
}

function derivedSurfaces(unit) {
    return {
        workspaceSwitcher: nestedStyle(['workspace-switcher'], unit),
        wsIndicator: nestedStyle(['workspace-switcher', 'ws-switcher-indicator'], unit),
        resizePopup: nestedStyle(['resize-popup'], unit),
        candidatePopup: nestedStyle(['candidate-popup-content'], unit),
        candidateBox: nestedStyle(['candidate-popup-content', 'candidate-box'], unit),
        runEntry: nestedStyle(['modal-dialog run-dialog', 'run-dialog-entry'], unit, St.Entry),
        audioDevice: nestedStyle(['modal-dialog audio-device-selection-dialog', 'audio-selection-box', 'audio-selection-device'], unit, St.Button),
        monitorLabel: nestedStyle(['osd-monitor-label'], unit),
    };
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
    const dock = dockReport(unit);
    if (dock)
        dock.appMenu = await dockAppMenu();
    bar.withDot = await withUnreadNotification(unit);
    bar.dnd = await withDoNotDisturb();
    bar.opaque = await withOpaqueBar(unit);
    bar.lockScreen = await withLockScreenPanel(unit);
    bar.largeText = await withLargeText();
    const surfaces = await shellSurfaces(unit);
    surfaces.quickSettings = await quickSettings(unit);
    surfaces.quickSettingsLayer = await quickSettingsLayer();
    surfaces.switcher = await windowSwitcher(unit);
    surfaces.dialog = await modalDialog(unit);
    surfaces.dateMenu = await calendarMenu(unit);
    surfaces.derived = derivedSurfaces(unit);
    surfaces.tilePreview = await tilePreview(unit);
    surfaces.spotlight = await spotlightStyle(unit);
    surfaces.screenshot = await screenshotUI(unit);

    Main.overview.show();
    await settle();
    // The search entry's cursor blinks: without key focus the scene is still.
    global.stage.set_key_focus(null);
    const overviewIdle = await settle();
    const overview = {
        idle: overviewIdle, ...await capture('overview'), thumbnails: thumbnails(), workArea: workArea(unit),
        dockVisible: apexDock()?.visible ?? null,
        dockClearance: dockClearance(unit),
    };
    surfaces.overview = overviewStyle(unit);
    surfaces.overviewSearch = await overviewSearch();
    surfaces.launcher = await launcherSearch(unit);
    surfaces.overviewLayer = await overviewLayer(unit);
    surfaces.appGrid = await appGrid(unit);
    delete overview.bytes;
    Main.overview.hide();

    const primary = Main.layoutManager.primaryMonitor;
    return {
        unit, startedInOverview,
        monitorScale: global.display.get_monitor_scale(primary.index),
        topBar: {...bar, diamond},
        dock,
        surfaces,
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

// An St.Icon counts, not the texture child St gives it once it is first styled.
function actorCensus() {
    const counts = {};
    const visit = actor => {
        const type = actor.constructor.name;
        counts[type] = (counts[type] ?? 0) + 1;
        if (!(actor instanceof St.Icon))
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
    // main.js runs an unmapped actor's deferred work (the overview's hidden dash) 20 s on.
    await Scripting.sleep(DEFERRED_WORK_TIMEOUT_MS);
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
function transitionInfo(transition) {
    if (!transition)
        return null;
    const mode = transition.get_progress_mode();
    const [, c1, c2] = transition.get_cubic_bezier_progress();
    return {
        mode: Object.keys(Clutter.AnimationMode).find(k => Clutter.AnimationMode[k] === mode) ?? mode,
        duration: transition.get_duration(),
        curve: [c1.x, c1.y, c2.x, c2.y].map(round),
    };
}

// The transition the ease created, read right after the call; none when the ease took 0 ms.
async function firstTransition(read) {
    for (let waited = 0; waited < MOTION_SETTLE_MS; waited += 10) {
        const transition = read();
        if (transition)
            return transitionInfo(transition);
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(10);
    }
    return null;
}

async function maximiseTransition(window) {
    const actor = window.get_compositor_private();
    window.maximize();
    // _sizeChangedWindow marks the actor resizing just before it eases the size change.
    const transition = await firstTransition(() =>
        Main.wm._resizing.has(actor) ? actor.get_transition('scale-x') : null);
    await Scripting.sleep(MOTION_SETTLE_MS);
    const maximised = window.is_maximized();
    window.unmaximize();
    await Scripting.sleep(MOTION_SETTLE_MS);
    return {transition, maximised};
}

async function overviewTransition() {
    const adjustment = Main.overview._overview._controls._stateAdjustment;
    Main.overview.show();
    const transition = await firstTransition(() => adjustment.get_transition('value'));
    await Scripting.sleep(MOTION_SETTLE_MS);
    const visible = Main.overview.visible;
    Main.overview.hide();
    await Scripting.sleep(MOTION_SETTLE_MS);
    return {transition, visible};
}

async function motion() {
    Main.overview.hide();
    await Scripting.sleep(MOTION_SETTLE_MS);
    const client = Gio.File.new_for_uri(import.meta.url).get_parent().get_child('window.js').get_path();
    // The shell's environment names no display: the client gets the shell's own, on Wayland.
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.STDERR_PIPE});
    launcher.setenv('WAYLAND_DISPLAY', GLib.getenv('G2_WAYLAND_DISPLAY') ?? 'apex-g2', true);
    launcher.setenv('GDK_BACKEND', 'wayland', true);
    const clientProcess = launcher.spawnv(['gjs', '-m', client]);
    const find = () => global.get_window_actors().map(a => a.meta_window)
        .find(w => w.get_gtk_application_id() === MOTION_WINDOW_ID);
    let window;
    for (let waited = 0; !(window = find()) && waited < MOTION_WAIT_MS; waited += 100)
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(100);
    if (!window) {
        clientProcess.force_exit();
        const [, , stderr] = await clientProcess.communicate_utf8_async(null, null);
        throw new Error(`the test client never mapped (${stderr?.trim() || `no ${MOTION_WINDOW_ID} window in ${MOTION_WAIT_MS} ms`})`);
    }
    // Mutter gives a window's first size change a 0 x 0 old frame, which stock never animates.
    window.maximize();
    await Scripting.sleep(MOTION_SETTLE_MS);
    window.unmaximize();
    await Scripting.sleep(MOTION_SETTLE_MS);
    const interfaceSettings = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
    // main.js inhibits animations without hardware-accelerated rendering, as G2's headless shell has.
    const stSettings = St.Settings.get();
    const uninhibited = interfaceSettings.get_boolean('enable-animations') && !stSettings.enable_animations;
    if (uninhibited)
        stSettings.uninhibit_animations();
    const animated = {maximise: await maximiseTransition(window), overview: await overviewTransition()};
    interfaceSettings.set_boolean('enable-animations', false);
    await Scripting.sleep(MOTION_SETTLE_MS);
    const still = {maximise: await maximiseTransition(window), overview: await overviewTransition()};
    // Locate Pointer's ripples are animationRequired: an a11y aid that animates regardless.
    interfaceSettings.set_boolean('locate-pointer', true);
    await Scripting.sleep(MOTION_SETTLE_MS);
    Main.locatePointer.show();
    still.locatePointer = transitionInfo(Main.locatePointer._ripples?._ripple1.get_transition('scale-x') ?? null);
    interfaceSettings.set_boolean('locate-pointer', false);
    const enableAnimations = stSettings.enable_animations;
    if (uninhibited)
        stSettings.inhibit_animations();
    return {uninhibited, enableAnimations, animated, still};
}

export function init() {
    if (Main.layoutManager._startingUp)
        return;
    console.log('APEXG2-LATE startup completed while main.js imported the probe');
    import(import.meta.url).then(self => Scripting.runPerfScript(self, GLib.getenv('SHELL_PERF_OUTPUT')));
}

function withoutBytes(captured) {
    delete captured.bytes;
    return captured;
}

async function until(condition, timeoutMs = 10000) {
    for (let waited = 0; waited < timeoutMs; waited += 100) {
        if (condition())
            return true;
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(100);
    }
    return condition();
}

function dockHidden() {
    return (apexDock()?.get_parent().translation_y ?? 0) > 0;
}

function maximisedWindow() {
    return global.display.list_all_windows().some(w => w.title === G2_WINDOW_TITLE && w.is_maximized());
}

// A window counts once its actor is mapped, which mutter does at its first frame.
function maximisedWindowShown() {
    return global.get_window_actors().some(a => a.mapped &&
        a.meta_window.title === G2_WINDOW_TITLE && a.meta_window.is_maximized());
}

// The scripted case of ROADMAP S2a: a maximised window hides the dock, the bottom edge under
// it reveals it, and leaving it hides it again.
async function withDockIntellihide() {
    const unit = cssUnit();
    dropStartupNotifications();
    Main.overview.hide();
    await settle();
    const steps = {initial: {hidden: dockHidden()}};
    const here = GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0]);
    const client = Gio.Subprocess.new(['gjs', '-m', GLib.build_filenamev([here, 'maximised-window.js'])],
        Gio.SubprocessFlags.NONE);
    try {
        steps.maximised = {window: await until(maximisedWindowShown)};
        await until(dockHidden, 3000);
        await settle();
        steps.maximised.hidden = dockHidden();
        steps.maximised.barSolid = Main.panel.has_style_class_name('apex-solid-bar');
        steps.maximised.capture = withoutBytes(await capture('maximised'));

        const box = apexDock().get_parent();
        const [boxX] = box.get_transformed_position();
        const monitor = Main.layoutManager.primaryMonitor;
        const seat = global.stage.context.get_backend().get_default_seat();
        const pointer = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
        const now = () => GLib.get_monotonic_time();
        pointer.notify_absolute_motion(now(), boxX + box.width / 2, monitor.y + monitor.height - 1);
        for (let push = 0; push < 5; push++) {
            pointer.notify_relative_motion(now(), 0, 20);
            // eslint-disable-next-line no-await-in-loop
            await Scripting.sleep(50);
        }
        await until(() => !dockHidden(), 3000);
        await settle();
        const underPointer = global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE,
            boxX + box.width / 2, monitor.y + monitor.height - 1);
        steps.revealed = {hidden: dockHidden(), underPointer: box === underPointer || box.contains(underPointer)};
        steps.revealed.capture = withoutBytes(await capture('revealed'));

        pointer.notify_absolute_motion(now(), monitor.x + monitor.width / 2, monitor.y + monitor.height / 2);
        await until(dockHidden, 3000);
        steps.left = {hidden: dockHidden()};

        Main.overview.show();
        await settle();
        steps.overview = {hidden: dockHidden()};
        Main.overview.hide();
        await settle();

        const settings = new Gio.Settings({schema_id: APEX_SCHEMA});
        settings.set_boolean(DOCK_INTELLIHIDE_KEY, false);
        await until(() => !dockHidden(), 3000);
        steps.intellihideOff = {hidden: dockHidden(), window: maximisedWindow()};
        settings.reset(DOCK_INTELLIHIDE_KEY);
        await until(dockHidden, 3000);
        steps.intellihideOn = {hidden: dockHidden()};
    } finally {
        client.force_exit();
    }
    await until(() => !maximisedWindow() && !dockHidden(), 5000);
    steps.closed = {hidden: dockHidden(), window: maximisedWindow()};
    return {unit, steps};
}

// gnome-shell-perf-helper quits after 30 s without a call, and scripting.js's last call to it
// then fails the shell: a probe that runs longer pings it.
function keepPerfHelperAwake() {
    return GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, PERF_HELPER_PING_S, () => {
        Scripting._getPerfHelper().then(helper => helper.DestroyWindowsAsync()).catch(() => {});
        return GLib.SOURCE_CONTINUE;
    });
}

export async function run() {
    const pingId = keepPerfHelperAwake();
    try {
        await runProbe();
    } finally {
        GLib.source_remove(pingId);
    }
}

async function runProbe() {
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

    if (GLib.getenv('G2_MOTION') === '1') {
        let result;
        try {
            result = await motion();
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-MOTION ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_GLASS') === '1') {
        let result;
        try {
            const Glass = await import('./glass.js');
            result = await Glass.glassReport();
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-GLASS ${JSON.stringify(result)}`);
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

    if (GLib.getenv('G2_DOCK') === '1') {
        let result;
        try {
            result = await withDockIntellihide();
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-DOCK ${JSON.stringify(result)}`);
    }

    const wait = Number(GLib.getenv('PROBE_WAIT') ?? '0');
    if (wait > 0) {
        await Scripting.sleep(wait * 1000);
        console.log(`APEXG2-SURVIVED ${wait}s startingMarker=${startingMarker()}`);
    }
}
