// SPDX-License-Identifier: GPL-3.0-or-later

import Atk from 'gi://Atk';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Graphene from 'gi://Graphene';
import Meta from 'gi://Meta';
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
import * as ShellMountOperation from 'resource:///org/gnome/shell/ui/shellMountOperation.js';
import * as Slider from 'resource:///org/gnome/shell/ui/slider.js';
import * as SwitcherPopup from 'resource:///org/gnome/shell/ui/switcherPopup.js';
import * as UserWidget from 'resource:///org/gnome/shell/ui/userWidget.js';
import * as WindowManager from 'resource:///org/gnome/shell/ui/windowManager.js';
import * as WorkspaceThumbnail from 'resource:///org/gnome/shell/ui/workspaceThumbnail.js';

import {barReport, textColour} from './a11y.js';
import {actionModeName} from './idle.js';
import * as Png from './png.js';

export const METRICS = {};

// Main.actionMode as run() found it, and whether init() had to start the probe itself.
let actionModeAtRun = null;
let startedLate = false;

const APEX_SCHEMA = 'io.github.apex_linux.Apex.Desktop';
const APEX_KEYBINDINGS_SCHEMA = 'io.github.apex_linux.Apex.Desktop.Keybindings';
const WM_KEYBINDINGS_SCHEMA = 'org.gnome.desktop.wm.keybindings';
const SHELL_KEYBINDINGS_SCHEMA = 'org.gnome.shell.keybindings';
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
const IDLE_PAINT_MS = 2000;
const SHADOW_REGISTRY = 'resource:///org/gnome/shell/ui/apex/shadows/registry.js';
const SPOTLIGHT_FEATURE = 'resource:///org/gnome/shell/ui/apex/spotlight/feature.js';
const MOTION_WINDOW_ID = 'io.github.apex_linux.G2Window';
const MOTION_WAIT_MS = 10000;
const MOTION_SETTLE_MS = 1000;
const MOTION_WINDOW_SIZE = {width: 640, height: 400};
const OSD_GLYPH = 'audio-volume-medium-symbolic';
const SWITCHER_APPS = ['Text Editor', 'Terminal', 'Web', 'Files', 'Settings'];
const SWITCHER_ICON_SIZE = 96;
// Nautilus refuses to run as root, as G2 does: Calendar, from the dock, stands in.
const SIGNOFF_APPS = [['gnome-text-editor', '--new-window'], ['gnome-calendar'], ['ptyxis', '--new-window']];
const SIGNOFF_WINDOWS_MS = 30000;
const SIGNOFF_FOCUS_ORDER = ['org.gnome.Calendar.desktop', 'org.gnome.TextEditor.desktop', 'org.gnome.Ptyxis.desktop'];
const SIGNOFF_QUIET_MS = 1500;
const SIGNOFF_FOCUS_ATTEMPTS = 3;
const WIFI_SCAN_MS = 5000;
const TRAY_DRAIN_MS = 3000;
const SHUTDOWN_HISTORY_DELAY_MS = 300;
const SHUTDOWN_BANNER_TIMEOUT_MS = 100;
const AVATAR_SIZE = 32;
const OVERVIEW_WINDOWS = 3;
const FIXTURE_WALLPAPER = {width: 160, height: 100};

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
            sha256BeforeStructure: sha256OfText(text.split(STRUCTURE_MARKER)[0].trimEnd()),
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

const actionModeNames = mask => Object.entries(Shell.ActionMode)
    .filter(([name, bit]) => name !== 'ALL' && bit !== 0 && (mask & bit) === bit)
    .map(([name]) => name);

// windowManager.js keeps each binding's action modes here, and removeKeybinding sets NONE.
function keyBinding(name, schemaId) {
    return {
        modes: actionModeNames(Main.wm._allowedKeybindings[name] ?? Shell.ActionMode.NONE),
        accelerators: setting(schemaId, s => s.get_strv(name)),
    };
}

function spotlightKey() {
    return keyBinding(TOGGLE_SPOTLIGHT, APEX_KEYBINDINGS_SCHEMA);
}

function startingMarker() {
    return GLib.file_test(GLib.build_filenamev([GLib.get_user_runtime_dir(), CRASH_GUARD_MARKER]),
        GLib.FileTest.EXISTS);
}

// Fedora's own shell has no Apex modules, and gjs at times logs a JS ERROR for a failed
// import the probe catches: so an absent one is never imported.
function apexModule(uri) {
    try {
        Gio.resources_get_info(uri.replace('resource://', ''), Gio.ResourceLookupFlags.NONE);
    } catch {
        return Promise.resolve(null);
    }
    return import(uri);
}

async function apexHooks() {
    try {
        return await apexModule('resource:///org/gnome/shell/ui/apex/hooks.js');
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

// panel.js hides a button it has nothing to show for, not its container.
function panelItems(boxActor, unit) {
    return boxActor.get_children().filter(c => c.visible && c.get_first_child()?.visible !== false).map(container => {
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
// other GPU while switcheroo-control reports two, and builds its items once per icon.
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

// A banner over a scene that did not open it is a race; signoff.sh fails the board that caught one.
function bannerShown() {
    const tray = Main.messageTray;
    return tray._banner?.mapped ? {source: tray._notification?.source?.title ?? null, title: tray._notification?.title ?? null} : null;
}

async function capture(scene, live = [], record = {}) {
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
    console.log(`APEXG2-CAPTURE ${JSON.stringify({file: name, banner: bannerShown(), live, ...record})}`);
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
        root: menu.box,
        measure: unit => {
            const line = separator.get_children().find(c => c.has_style_class_name('popup-separator-menu-item-separator'));
            return {
                content: styleOf(menu.box, unit),
                rows: [...rows, iconRow].map(row => ({
                    ...styleOf(row, unit),
                    hover: underPseudoClass(row, 'hover', () => paint(row.get_theme_node(), unit)),
                    checked: underPseudoClass(row, 'checked', () => paint(row.get_theme_node(), unit)),
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
        root: window._hbox,
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

// The connected network's row and another, at rest: the menu opens with the first row, the
// connected one, under key focus.
function networkRows(wifi, unit) {
    const rows = findAll(wifi.menu.box, a => a.constructor.name === 'NMWirelessNetworkItem' && a.visible);
    const connected = rows.find(r => r.network.is_active);
    const other = rows.find(r => !r.network.is_active);
    const focus = global.stage.key_focus;
    global.stage.set_key_focus(wifi.menu.box);
    try {
        return {
            connected: connected ? {
                ...styleOf(connected, unit),
                hover: underPseudoClass(connected, 'hover', () => paint(connected.get_theme_node(), unit)),
            } : null,
            other: styleOf(other, unit),
        };
    } finally {
        global.stage.set_key_focus(focus);
    }
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
        // The menu scans as it opens, and again every 15 s: board 17 is the menu after a scan, without its spinner.
        const scanning = () => Boolean(wifi?._scanningSpinner?.content);
        const scanned = await until(() => !scanning(), WIFI_SCAN_MS);
        await settle();
        const scene = GLib.getenv('G2_SURFACE_SCENES') === '1'
            ? await capture('quick-settings', scanning() ? ['wifi-scan-spinner'] : [])
            : null;
        if (scene)
            delete scene.bytes;
        const system = byType('SystemItem');
        const wifiToggle = wifi && findDescendant(wifi, a => a.has_style_class_name?.('quick-toggle'));
        const menuButton = wifi && findDescendant(wifi, a => a.has_style_class_name?.('quick-toggle-menu-button'));
        const header = wifi && findDescendant(wifi.menu.box, a => a.has_style_class_name?.('header'));
        const find = (root, styleClass) => findDescendant(root, a => a.has_style_class_name?.(styleClass));
        return {
            scene, scanned,
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
                ...networkRows(wifi, unit),
            } : null,
        };
    } finally {
        wifi?.menu.close(BoxPointer.PopupAnimation.NONE);
        menu.close(BoxPointer.PopupAnimation.NONE);
        await settle();
    }
}

function findAll(actor, matches) {
    return actor.get_children().flatMap(child => [...matches(child) ? [child] : [], ...findAll(child, matches)]);
}

// Board 17's Wi-Fi menu: the header subtitle's grid cell and each network row, the lock read
// where it is, after the name or in the signal icon's box.
async function wifiMenuRows(unit) {
    const {menu} = Main.panel.statusArea.quickSettings;
    const wifi = findDescendant(menu.box, a => a.constructor.name === 'NMWirelessToggle');
    if (!wifi)
        return null;
    menu.open(BoxPointer.PopupAnimation.NONE);
    wifi.menu.open(BoxPointer.PopupAnimation.NONE);
    try {
        await settle();
        const {_header: header, _headerSubtitle: subtitle} = wifi.menu;
        const meta = header.layout_manager.get_child_meta(header, subtitle);
        const rows = findAll(wifi.menu.box, a => a.constructor.name === 'NMWirelessNetworkItem');
        return {
            subtitle: {column: meta.left_attach, row: meta.top_attach, xAlign: subtitle.x_align, end: Clutter.ActorAlign.END},
            rows: rows.map(row => {
                const lock = row._secureIcon;
                const children = row.get_children();
                return {
                    ssid: row._label.text,
                    active: row.network.is_active,
                    checked: row.has_style_pseudo_class('checked'),
                    accessibleName: row.accessible_name ?? null,
                    accessibleChecked: row.get_accessible().ref_state_set().contains_state(Atk.StateType.CHECKED),
                    strength: row.network.signal_strength,
                    secure: !!lock.icon_name,
                    lockAfterName: children.indexOf(lock) === children.indexOf(row._label) + 1,
                    box: boxOf(row, unit), label: boxOf(row._label, unit), signal: boxOf(row._signalIcon, unit),
                    lockBox: lock.icon_name ? boxOf(lock, unit) : null,
                    lockSize: lengthOrNull(lock.get_theme_node(), 'icon-size', unit),
                    lockColor: hex(lock.get_theme_node().get_foreground_color()),
                };
            }),
        };
    } finally {
        wifi.menu.close(BoxPointer.PopupAnimation.NONE);
        menu.close(BoxPointer.PopupAnimation.NONE);
        await settle();
    }
}

// The quick-settings feature: the toggles' order, Power Mode lit, On/Off subtitles; then two
// clicks on Power Mode, which stock answers by switching to the last profile and back.
async function quickSettingsLayer(unit) {
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
        wifiMenu: await wifiMenuRows(unit),
    };
    if (power?.visible) {
        state.switched = await clickPower();
        state.back = await clickPower();
    }
    return state;
}

// Each layer under a registered surface: its shadow, its allocation and the box the surface's own allocation
// gives, rounded as registry.js rounds it; natural is the surface's preferred size, which a min-width outgrows.
function layerReport(Registry, surface, unit) {
    const natural = [surface.get_preferred_width(-1)[1], surface.get_preferred_height(-1)[1]].map(Math.round);
    return Registry.layersOf(surface).map(layer => {
        const corner = (x, y) => surface.apply_relative_transform_to_point(layer.get_parent(), new Graphene.Point3D({x, y, z: 0}));
        const [from, to] = [corner(0, 0), corner(surface.allocation.get_width(), surface.allocation.get_height())];
        const [x, y] = [Math.round(from.x), Math.round(from.y)];
        const box = layer.get_allocation_box();
        return {
            shown: layer.mapped,
            boxShadow: shadow(layer.get_theme_node(), unit),
            radius: round(layer.get_theme_node().get_border_radius(St.Corner.TOPLEFT) / unit.length),
            box: [box.x1, box.y1, box.x2, box.y2],
            surfaceBox: [x, y, x + Math.round(to.x - from.x), y + Math.round(to.y - from.y)],
            natural,
        };
    });
}

async function shadowLayers(unit) {
    const Registry = await import(SHADOW_REGISTRY);
    const result = {};
    for (const [name, menu] of [['quickSettings', Main.panel.statusArea.quickSettings.menu],
        ['dateMenu', Main.panel.statusArea.dateMenu.menu]]) {
        menu.open(BoxPointer.PopupAnimation.NONE);
        // eslint-disable-next-line no-await-in-loop
        await settle();
        result[name] = layerReport(Registry, menu.box, unit);
        menu.close(BoxPointer.PopupAnimation.NONE);
        // eslint-disable-next-line no-await-in-loop
        await settle();
    }
    // Short items leave the menu at $apex_menu_min_width, wider than their natural width (board 16).
    const source = new St.Widget({x: 400, y: 300, width: 40, height: 20, reactive: true});
    Main.uiGroup.add_child(source);
    const popup = new PopupMenu.PopupMenu(source, 0.5, St.Side.TOP);
    ['Open', 'Pin'].forEach(label => popup.addAction(label, () => {}));
    Main.uiGroup.add_child(popup.actor);
    // Opened again, as the dock's menu is, it keeps its allocation: no notify::allocation follows its relayout.
    for (let opening = 0; opening < 2; opening++) {
        popup.open(BoxPointer.PopupAnimation.NONE);
        // eslint-disable-next-line no-await-in-loop
        await settle();
        result.popupMenu = layerReport(Registry, popup.box, unit);
        if (opening === 0) {
            popup.close(BoxPointer.PopupAnimation.NONE);
            // eslint-disable-next-line no-await-in-loop
            await settle();
        }
    }
    popup.destroy();
    source.destroy();
    await settle();
    // A ModalDialog keeps its lightbox right under its box's ancestor, so the layer must sit beside the box.
    const dialog = new ModalDialog.ModalDialog();
    dialog.contentLayout.add_child(new St.Label({text: 'Shadow'}));
    dialog.open();
    await settle();
    const surface = dialog.dialogLayout._dialog;
    result.dialog = layerReport(Registry, surface, unit)
        .map((layer, i) => ({...layer, besideBox: Registry.layersOf(surface)[i].get_parent() === surface.get_parent()}));
    dialog.close();
    await settle();
    return result;
}

async function stagePaints() {
    let paints = 0;
    const id = global.stage.connect('after-paint', () => paints++);
    await Scripting.sleep(IDLE_PAINT_MS);
    global.stage.disconnect(id);
    return paints;
}

// An idle desktop repaints no more with the shadow layers than without them. A lone stray
// paint lands in either state now and then, so each takes the quieter of two windows.
async function idleRepaints() {
    const apex = new Gio.Settings({schema_id: APEX_SCHEMA});
    const disabled = apex.get_strv('disabled-features');
    apex.set_strv('disabled-features', [...disabled, 'shadows']);
    await settle();
    const withoutShadows = Math.min(await stagePaints(), await stagePaints());
    apex.set_strv('disabled-features', disabled);
    await settle();
    const withShadows = Math.min(await stagePaints(), await stagePaints());
    return {withShadows, withoutShadows};
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

// The shell's own power-off dialog, opened as gnome-session opens it, so that patch 0018's
// hook runs: Cancel, the end-session feature's Restart, then Power Off.
async function endSessionDialog(unit) {
    try {
        return await openEndSessionDialog(unit);
    } catch (e) {
        return {error: e.message};
    }
}

async function openShellEndSession() {
    await Gio.DBus.session.call('org.gnome.Shell', '/org/gnome/SessionManager/EndSessionDialog',
        'org.gnome.SessionManager.EndSessionDialog', 'Open', new GLib.Variant('(uuuao)', [1, 0, 60, []]),
        null, Gio.DBusCallFlags.NONE, -1, null);
    return Main.layoutManager.modalDialogGroup.get_children()
        .find(c => c.dialogLayout?._dialog?.has_style_class_name('end-session-dialog'));
}

async function openEndSessionDialog(unit) {
    const dialog = await openShellEndSession();
    try {
        await settle();
        global.stage.set_key_focus(null);
        const find = styleClass => findDescendant(dialog.contentLayout, a => a.has_style_class_name?.(styleClass));
        const title = find('message-dialog-title');
        const icon = find('apex-end-session-icon');
        const row = dialog.buttonLayout;
        return {
            box: styleOf(dialog.dialogLayout._dialog, unit),
            contentSpacing: lengthOrNull(dialog.contentLayout.get_theme_node(), 'spacing', unit),
            icon: icon ? {
                ...styleOf(icon, unit),
                glyph: lengthOrNull(icon.child.get_theme_node(), 'icon-size', unit),
                iconName: icon.child.icon_name,
                above: icon.get_next_sibling() === find('message-dialog-content'),
            } : null,
            title: {...styleOf(title, unit), tracking: round(title.get_theme_node().get_letter_spacing() / unit.length)},
            description: styleOf(find('message-dialog-description'), unit),
            rowSpacing: round(row.layout_manager.spacing / unit.length),
            buttons: row.get_children().filter(b => b.visible).map(b => ({
                ...styleOf(b, unit),
                text: b.label,
                hover: underPseudoClass(b, 'hover', () => paint(b.get_theme_node(), unit)),
            })),
        };
    } finally {
        dialog?.cancel();
        await settle();
    }
}

const UPDATE1 = ['io.github.apex_linux.Apex.Update1', '/io/github/apex_linux/Apex/Update1'];
const STAGED_UPDATE = {
    digest: new GLib.Variant('s', 'sha256:9e41aa07c3b2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c80c2b'),
    version: new GLib.Variant('s', '45.20261010.133'),
    'download-only': new GLib.Variant('b', true),
};
const UPDATE_CARD_WAIT_MS = 2000;

// update1-mock.py's state, through python-dbusmock's own interface.
function setUpdateState(state, staged) {
    return Gio.DBus.system.call(...UPDATE1, 'org.freedesktop.DBus.Mock', 'UpdateProperties',
        new GLib.Variant('(sa{sv})', [UPDATE1[0], {State: new GLib.Variant('s', state), Staged: new GLib.Variant('a{sv}', staged)}]),
        null, Gio.DBusCallFlags.NONE, -1, null);
}

function updateCardOf(dialog, unit) {
    const card = findDescendant(dialog.contentLayout, a => a.has_style_class_name?.('apex-update-card'));
    if (!card)
        return null;
    const find = styleClass => findDescendant(card, a => a.has_style_class_name?.(styleClass));
    const icon = find('apex-update-card-icon');
    const toggle = find('toggle-switch');
    return {
        ...styleOf(card, unit),
        below: card.get_previous_sibling()?.has_style_class_name('message-dialog-content') ?? false,
        icon: {iconName: icon.icon_name, size: lengthOrNull(icon.get_theme_node(), 'icon-size', unit)},
        textSpacing: lengthOrNull(find('apex-update-card-text').get_theme_node(), 'spacing', unit),
        title: {...styleOf(find('apex-update-card-title'), unit), text: find('apex-update-card-title').text},
        subtitle: {...styleOf(find('apex-update-card-subtitle'), unit), text: find('apex-update-card-subtitle').text},
        toggle: {
            ...styleOf(toggle, unit), on: toggle.state, sensitive: toggle.get_parent().reactive,
            knob: styleOf(find('handle'), unit), opacity: round(toggle.get_parent().opacity / 255),
            focusable: toggle.get_parent().can_focus,
            a11ySensitive: toggle.get_accessible().ref_state_set().contains_state(Atk.StateType.SENSITIVE),
        },
        buttons: dialog.buttonLayout.get_children().filter(b => b.visible).map(b => b.label),
    };
}

// Board 14's update card in the restart dialog: staged, then ready-for-reboot, each captured.
async function updateCard(unit) {
    const open = async (state, scene) => {
        await setUpdateState(state, STAGED_UPDATE);
        await Gio.DBus.session.call('org.gnome.Shell', '/org/gnome/SessionManager/EndSessionDialog',
            'org.gnome.SessionManager.EndSessionDialog', 'Open', new GLib.Variant('(uuuao)', [2, 0, 60, []]),
            null, Gio.DBusCallFlags.NONE, -1, null);
        const dialog = Main.layoutManager.modalDialogGroup.get_children()
            .find(c => c.dialogLayout?._dialog?.has_style_class_name('end-session-dialog'));
        try {
            await Scripting.sleep(UPDATE_CARD_WAIT_MS);
            await settle();
            global.stage.set_key_focus(null);
            return {...updateCardOf(dialog, unit), capture: withoutBytes(await capture(scene)).file};
        } finally {
            dialog?.cancel();
            await settle();
        }
    };
    try {
        return {staged: await open('staged', 'end-session-update'), ready: await open('ready-for-reboot', 'end-session-ready')};
    } catch (e) {
        return {error: e.message};
    } finally {
        await setUpdateState('up-to-date', {}).catch(() => {});
    }
}

// A stock ModalDialog shaped like polkit's: title, description, password entry, two buttons.
function promptDialog() {
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
    return {dialog, content, entry, buttons};
}

// With polkit's user row too: the avatar of a user without a picture, which draws the initial.
function openPromptDialog({avatar = false} = {}) {
    const {dialog} = promptDialog();
    if (avatar) {
        const row = new St.BoxLayout({style_class: 'polkit-dialog-user-layout apex-polkit-user'});
        const user = {get_icon_file: () => null, get_real_name: () => 'Apex', get_user_name: () => 'apex'};
        const picture = new UserWidget.Avatar(user, {iconSize: AVATAR_SIZE});
        picture.update();
        row.add_child(picture);
        const scope = new St.BoxLayout({style_class: 'apex-polkit'});
        scope.add_child(row);
        dialog.contentLayout.add_child(scope);
    }
    dialog.open();
    return {
        root: dialog.dialogLayout._dialog,
        close: () => {
            dialog.close();
            dialog.destroy();
        },
    };
}

async function modalDialog(unit) {
    const {dialog, content, entry, buttons} = promptDialog();
    dialog.open();
    try {
        await settle();
        global.stage.set_key_focus(null);
        const scene = GLib.getenv('G2_SURFACE_SCENES') === '1' ? await capture('dialog') : null;
        if (scene)
            delete scene.bytes;
        const find = styleClass => findDescendant(content, a => a.has_style_class_name?.(styleClass));
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
        };
    } finally {
        dialog.close();
        dialog.destroy();
        await settle();
    }
}

// The mount password dialog, as a mount's ask-password opens it: its Remember Password is a check box.
function openMountPasswordDialog() {
    const operation = new ShellMountOperation.ShellMountOperation({get_drive: () => null});
    operation.mountOp.emit('ask-password', 'Password Required\nEnter the password for the G2 share', 'apex', 'WORKGROUP',
        Gio.AskPasswordFlags.NEED_PASSWORD | Gio.AskPasswordFlags.SAVING_SUPPORTED);
    const dialog = operation._dialog;
    return {
        root: dialog.dialogLayout._dialog,
        check: dialog._rememberChoice,
        close: () => operation.close(),
    };
}

async function checkBoxDialog(unit) {
    const opened = openMountPasswordDialog();
    const {check} = opened;
    const state = checked => {
        check.checked = checked;
        return {
            ...styleOf(check._check, unit),
            hover: underPseudoClass(check, 'hover', () => ({borderColor: hex(check._check.get_theme_node().get_border_color(St.Side.TOP))})),
        };
    };
    try {
        await settle();
        global.stage.set_key_focus(null);
        return {background: styleOf(opened.root, unit).background, label: check.getLabelActor().text, unchecked: state(false), checked: state(true)};
    } finally {
        opened.close();
        await settle();
    }
}

// The calendar's day buttons, and the colour each one's number is drawn in, which St gives a
// Clutter.Text only as the button's own child.
function calendarDays(calendar, unit) {
    const days = calendar.get_children().filter(a => a.has_style_class_name?.('calendar-day'));
    const day = classes => days.find(d => classes.every(c => d.has_style_class_name(c)) &&
        !d.has_style_class_name('calendar-today') && (classes.includes('calendar-other-month') || !d.has_style_class_name('calendar-other-month')));
    const ink = dayButton => {
        const label = findDescendant(dayButton, a => a instanceof St.Label);
        const text = label?.clutter_text ?? findDescendant(dayButton, a => a instanceof Clutter.Text);
        return text ? hex(textColour(text)) : null;
    };
    const dayStyle = dayButton => dayButton ? {...styleOf(dayButton, unit), ink: ink(dayButton)} : null;
    return {days, day, dayStyle};
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
        const {days, day, dayStyle} = calendarDays(calendar, unit);
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
            day: dayStyle(day(['calendar-weekday'])),
            weekend: dayStyle(day(['calendar-weekend'])),
            otherMonth: dayStyle(day(['calendar-other-month'])),
            today: dayStyle(days.find(d => d.has_style_class_name('calendar-today'))),
            events: styleOf(events, unit),
            eventsTitle: styleOf(find(events, 'events-title'), unit),
            clocks: styleOf(find(box, 'world-clocks-button'), unit),
            clocksHeader: styleOf(find(box, 'world-clocks-header'), unit),
            weather: styleOf(find(box, 'weather-button'), unit),
            weatherHeader: styleOf(find(box, 'weather-header'), unit),
        };
    } finally {
        menu.close(BoxPointer.PopupAnimation.NONE);
        source.destroy();
        await settle();
    }
}

// The notifications feature: three notifications from one app, the footer, then an empty list.
// A card's tree by each actor's first style class, down to the header, icon, text and actions.
const CARD_LEAVES = ['message-header', 'message-icon', 'message-content', 'message-action-bin'];
function cardTree(actor) {
    const name = actor.get_style_class_name?.()?.split(' ')[0] || 'box';
    if (CARD_LEAVES.includes(name))
        return name;
    const children = actor.get_children();
    return children.length ? `${name}[${children.map(cardTree).join(',')}]` : name;
}

// Board 34's card, in boxes: the icon's column, the header over the title, the close button, the actions.
function cardLayout(message, unit) {
    const find = styleClass => findDescendant(message, a => a.has_style_class_name?.(styleClass));
    return {
        card: boxOf(message, unit), icon: boxOf(message._icon, unit), header: boxOf(find('message-header-content'), unit),
        title: boxOf(message.titleLabel, unit), close: boxOf(find('message-close-button'), unit),
        actions: message._actionBin.visible ? boxOf(message._actionBin, unit) : null,
    };
}

async function notificationsLayer(unit) {
    const source = new MessageTray.Source({title: 'G2 Chat', iconName: 'mail-unread-symbolic'});
    Main.messageTray.add(source);
    for (const title of ['Lunch?', 'Standup moved', 'Build passed']) {
        const notification = new MessageTray.Notification({source, title, body: 'Just now.', urgency: MessageTray.Urgency.LOW});
        notification.addAction('Reply', () => {});
        source.addNotification(notification);
    }
    const {menu, _messageList: list} = Main.panel.statusArea.dateMenu;
    const notifications = new Gio.Settings({schema_id: 'org.gnome.desktop.notifications'});
    menu.open(BoxPointer.PopupAnimation.NONE);
    try {
        await settle();
        const group = findDescendant(menu.box, a => a.constructor.name === 'NotificationMessageGroup');
        const messages = group.get_children().map(c => c.child).filter(m => m?.constructor.name === 'NotificationMessage');
        const footer = list._clearButton.get_parent();
        const dnd = footer.get_children().find(c => c.has_style_class_name('apex-dnd-button')) ?? null;
        const trees = messages.map(m => cardTree(m.get_child()));
        const layout = {collapsed: cardLayout(messages[0], unit)};
        // A stock stack would expand the whole group: only a flat group's card expands alone.
        if (group.expanded) {
            messages[0].expand(false);
            await settle();
            layout.expanded = {...cardLayout(messages[0], unit), tree: cardTree(messages[0].get_child())};
            messages[0].unexpand(false);
            await settle();
            layout.collapsedAgain = {...cardLayout(messages[0], unit), tree: cardTree(messages[0].get_child())};
        }
        const header = findDescendant(messages[0], a => a.has_style_class_name?.('message-header'));
        const line = findDescendant(header, a => a.has_style_class_name?.('message-header-content'));
        const result = {
            header: group._headerBox.visible,
            cardHeader: {
                sourceIcon: findDescendant(header, a => a.has_style_class_name?.('message-source-icon')).visible,
                line: line.get_children().filter(c => c.visible).map(c => c.text).join(' '),
            },
            icon: messages[0].icon?.to_string() ?? null,
            messages: messages.map(m => boxOf(m, unit)),
            trees, layout,
            footer: boxOf(footer, unit),
            clear: {...boxOf(list._clearButton, unit), visible: list._clearButton.visible},
            dnd: dnd && {
                ...boxOf(dnd, unit), label: findDescendant(dnd, a => a instanceof St.Label)?.text ?? null,
                labelBox: boxOf(findDescendant(dnd, a => a instanceof St.Label), unit),
                switch: boxOf(findDescendant(dnd, a => a.has_style_class_name?.('toggle-switch')), unit),
            },
        };
        const calendar = findDescendant(menu.box, a => a.has_style_class_name?.('calendar'));
        const find = styleClass => findDescendant(calendar, a => a.has_style_class_name?.(styleClass));
        const days = calendar.get_children().filter(a => a.has_style_class_name?.('calendar-day'));
        const dots = days.map(d => findDescendant(d, a => a.has_style_class_name?.('apex-event-dot'))).filter(Boolean);
        result.calendar = {
            label: boxOf(find('calendar-month-label'), unit),
            back: boxOf(find('calendar-change-month-back'), unit),
            forward: boxOf(find('calendar-change-month-forward'), unit),
            days: days.length,
            dots: dots.map(d => boxOf(d, unit)),
        };
        if (dnd) {
            dnd.emit('clicked', Clutter.BUTTON_PRIMARY);
            result.dndClick = {showBanners: notifications.get_boolean('show-banners'), checked: dnd.checked};
            dnd.emit('clicked', Clutter.BUTTON_PRIMARY);
        }
        Main.messageTray.getSources().filter(s => s === source).forEach(s => s.destroy());
        await settle();
        result.empty = {
            placeholder: list._placeholder.visible,
            clearVisible: list._clearButton.visible,
            clearReactive: list._clearButton.reactive,
        };
        return result;
    } finally {
        menu.close(BoxPointer.PopupAnimation.NONE);
        notifications.reset('show-banners');
        Main.messageTray.getSources().filter(s => s === source).forEach(s => s.destroy());
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
        {id: 'removable-media', name: 'Removable Media', description: 'Apps · what happens when a disk is plugged in', icon: 'media-removable-symbolic'},
        {id: 'disk-encryption', name: 'Disk Encryption', description: 'Privacy & Security', icon: 'drive-harddisk-symbolic'},
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

// What the sheet asks of an actor's glass, and the blur the glass feature gave it.
function glassOf(actor, unit) {
    const node = actor.get_theme_node();
    const [, saturation] = node.lookup_double('-apex-glass-saturation', false);
    const effect = actor.get_effect('apex-glass');
    return {
        blur: lengthOrNull(node, '-apex-glass-blur', unit), saturation: round(saturation),
        effect: effect ? {radius: effect.radius, saturation: round(effect.saturation), enabled: effect.enabled} : null,
    };
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
            const tile = icon.has_style_class_name('apex-spotlight-tile')
                ? {...styleOf(icon, unit), glyph: lengthOrNull(icon.get_child().get_theme_node(), 'icon-size', unit)} : null;
            return {
                ...styleOf(actor, unit), icon: styleOf(icon, unit), tile, text: styleOf(text, unit),
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
        const panelBeforeCopy = glassOf(popup.panel, unit);
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
        measured.glass = {panelBeforeCopy, toast: pill ? glassOf(pill, unit) : null};
        return {scenes: captured, ...measured};
    } finally {
        popup.destroy();
        await settle();
    }
}

// S3a's exit items in the real shell: a provider past the budget holds back no section, and
// real key presses move one selection across the sections, open a row and close the popup.
const SLOW_SETTINGS_MS = 1600;
const ASK_WAIT_MS = 1000;
const SECTIONS_EARLY_MS = 300;
const CANCEL_GRACE_MS = 400;
const CANCEL_SETTLE_MS = 50;
const NO_KEYBINDING_ACTION = -1;

function slowSpotlightProviders(started, settings) {
    const providers = spotlightProviders();
    const fast = providers.get('org.gnome.Settings.desktop');
    providers.set('org.gnome.Settings.desktop', {
        ...fast,
        getInitialResultSet: (terms, cancellable) => new Promise(resolve => {
            settings.askedMs = msSince(started.at);
            cancellable?.connect(() => {
                settings.cancelledMs = msSince(started.at);
            });
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, SLOW_SETTINGS_MS, () => {
                resolve(fast.getInitialResultSet(terms));
                return GLib.SOURCE_REMOVE;
            });
        }),
    });
    for (const [id, provider] of providers)
        provider.activateResult = (resultId, terms) => settings.activated.push({provider: id, id: resultId, terms});
    return providers;
}

function msSince(start) {
    return Math.round((GLib.get_monotonic_time() - start) / 1000);
}

function spotlightSections(popup) {
    if (!popup.isOpen)
        return {open: false, sections: [], rows: 0, selected: null};
    const results = popup.panel.get_children()[1];
    const headers = results.get_children().filter(a => a.has_style_class_name('apex-spotlight-header'));
    const selected = popup.rows.find(r => r.selected);
    return {
        sections: headers.map(h => h.get_child().get_text()),
        rows: popup.rows.length,
        selected: selected ? selected.key : null,
    };
}

async function pressKeys(keyboard, keyval, times) {
    for (let i = 0; i < times; i++) {
        keyboard.notify_keyval(GLib.get_monotonic_time(), keyval, Clutter.KeyState.PRESSED);
        keyboard.notify_keyval(GLib.get_monotonic_time(), keyval, Clutter.KeyState.RELEASED);
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(20);
    }
    await settle();
}

async function spotlightKeys() {
    if ((await apexHooks())?.safe() !== false)
        return null;
    let Popup, BUDGET_MS;
    try {
        ({Popup} = await import('resource:///org/gnome/shell/ui/apex/spotlight/popup.js'));
        ({BUDGET_MS} = await import('resource:///org/gnome/shell/ui/apex/spotlight/search.js'));
    } catch {
        return null;
    }
    const started = {at: 0};
    const settings = {askedMs: null, cancelledMs: null, activated: []};
    // Unbound keys map to keybinding action 0, so the toggle action here must match none.
    const popup = new Popup(() => slowSpotlightProviders(started, settings), NO_KEYBINDING_ACTION);
    const seat = global.stage.context.get_backend().get_default_seat();
    const keyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    const keys = {budgetMs: BUDGET_MS, slowMs: SLOW_SETTINGS_MS, modalBefore: Main.modalCount};
    try {
        popup.open();
        keys.modalOpen = Main.modalCount;
        started.at = GLib.get_monotonic_time();
        popup.panel.get_children()[0].get_children()[1].set_text('disk');
        // The budget runs from the slow provider's ask, which can come a few frames late; both reads follow it.
        await until(() => settings.askedMs !== null, ASK_WAIT_MS);
        await Scripting.sleep(Math.max(0, (settings.askedMs ?? 0) + SECTIONS_EARLY_MS - msSince(started.at)));
        keys.early = {ms: msSince(started.at), ...spotlightSections(popup)};
        await until(() => settings.cancelledMs !== null,
            Math.max(0, (settings.askedMs ?? 0) + BUDGET_MS + CANCEL_GRACE_MS - msSince(started.at)));
        await Scripting.sleep(CANCEL_SETTLE_MS);
        keys.late = {ms: msSince(started.at), ...spotlightSections(popup)};
        keys.settings = {askedMs: settings.askedMs, cancelledMs: settings.cancelledMs};
        await pressKeys(keyboard, Clutter.KEY_Down, 4);
        keys.down4 = spotlightSections(popup).selected;
        await pressKeys(keyboard, Clutter.KEY_Up, 1);
        keys.up1 = spotlightSections(popup).selected;
        await pressKeys(keyboard, Clutter.KEY_Down, 20);
        keys.down20 = spotlightSections(popup).selected;
        await pressKeys(keyboard, Clutter.KEY_Return, 1);
        keys.enter = {open: popup.isOpen, modal: Main.modalCount, activated: settings.activated};
        popup.open();
        popup.panel.get_children()[0].get_children()[1].set_text('disk');
        await settle();
        await pressKeys(keyboard, Clutter.KEY_Escape, 1);
        keys.escape = {open: popup.isOpen, modal: Main.modalCount};
        return keys;
    } finally {
        popup.destroy();
        await settle();
    }
}

// Modifiers held down, the key pressed and released, then the modifiers let go: a person's chord.
async function chord(keyboard, modifiers, keyval) {
    const at = () => GLib.get_monotonic_time();
    modifiers.forEach(m => keyboard.notify_keyval(at(), m, Clutter.KeyState.PRESSED));
    if (keyval !== null) {
        keyboard.notify_keyval(at(), keyval, Clutter.KeyState.PRESSED);
        keyboard.notify_keyval(at(), keyval, Clutter.KeyState.RELEASED);
    }
    [...modifiers].reverse().forEach(m => keyboard.notify_keyval(at(), m, Clutter.KeyState.RELEASED));
    await settle();
}

// The session's keys, each as registered and then pressed, from the desktop with nothing open.
async function keysCase() {
    const bindings = {
        inputSource: keyBinding('switch-input-source', WM_KEYBINDINGS_SCHEMA),
        inputSourceBackward: keyBinding('switch-input-source-backward', WM_KEYBINDINGS_SCHEMA),
        panels: keyBinding('switch-panels', WM_KEYBINDINGS_SCHEMA),
        appView: keyBinding('toggle-application-view', SHELL_KEYBINDINGS_SCHEMA),
        overlay: {
            modes: actionModeNames(Main.wm._allowedKeybindings['overlay-key'] ?? Shell.ActionMode.NONE),
            key: setting('org.gnome.mutter', s => s.get_string('overlay-key')),
        },
    };
    const allModes = actionModeNames(Shell.ActionMode.ALL);
    const {getInputSourceManager} = await import('resource:///org/gnome/shell/ui/status/keyboard.js');
    const sources = getInputSourceManager();
    const source = () => sources.currentSource?.id ?? null;
    const spotlight = (await apexModule(SPOTLIGHT_FEATURE).catch(() => null))?.popup() ?? null;
    const seat = global.stage.context.get_backend().get_default_seat();
    const keyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    const pressed = {sources: Object.values(sources.inputSources).map(s => s.id), first: source()};

    await chord(keyboard, [Clutter.KEY_Super_L], Clutter.KEY_space);
    pressed.superSpace = {spotlight: spotlight?.isOpen ?? null, source: source()};
    spotlight?.close();
    await settle();
    await chord(keyboard, [Clutter.KEY_Super_L, Clutter.KEY_Alt_L], Clutter.KEY_space);
    pressed.superAltSpace = {source: source()};
    await chord(keyboard, [Clutter.KEY_Shift_L, Clutter.KEY_Super_L, Clutter.KEY_Alt_L], Clutter.KEY_space);
    pressed.shiftSuperAltSpace = {source: source()};

    // SwitcherPopup reads no held modifier from a virtual keyboard and finishes at once, but adds
    // itself to uiGroup first: its items are read there.
    const dock = apexDock();
    const groups = [];
    const addedId = Main.uiGroup.connect('child-added', (_group, child) => {
        if (child.constructor.name === 'CtrlAltTabPopup')
            groups.push(...child._items);
    });
    await chord(keyboard, [Clutter.KEY_Control_L, Clutter.KEY_Alt_L], Clutter.KEY_Tab);
    Main.uiGroup.disconnect(addedId);
    const dockGroup = groups.find(item => dock && item.root === dock);
    if (dockGroup)
        Main.ctrlAltTabManager.focusGroup(dockGroup, global.get_current_time());
    await settle();
    const focus = global.stage.get_key_focus();
    pressed.ctrlAltTab = {
        groups: groups.map(item => ({name: item.name, dock: item === dockGroup})),
        dockFocused: !!dock && !!focus && dock.contains(focus),
    };
    global.stage.set_key_focus(null);
    await settle();

    await chord(keyboard, [], Clutter.KEY_Super_L);
    pressed.superTap = {overview: Main.overview.visible, apps: Main.overview.dash.showAppsButton.checked};
    Main.overview.hide();
    await settle();
    await chord(keyboard, [Clutter.KEY_Super_L], Clutter.KEY_a);
    pressed.superA = {overview: Main.overview.visible, apps: Main.overview.dash.showAppsButton.checked};
    Main.overview.hide();
    await settle();
    return {bindings, allModes, pressed, modals: Main.modalCount};
}

// Spotlight's popup, and its toast once a calculation is copied, for G2_A11Y.
async function withSpotlight(read) {
    if ((await apexHooks())?.safe() !== false)
        return null;
    const {Popup} = await import('resource:///org/gnome/shell/ui/apex/spotlight/popup.js');
    const Toast = await import('resource:///org/gnome/shell/ui/apex/spotlight/toast.js');
    const popup = new Popup(spotlightProviders, 0);
    popup.open();
    try {
        return await read(popup, async () => {
            popup.panel.get_children()[0].get_children()[1].set_text('2880 / 1.5');
            await settle();
            popup.activateSelected();
            await settle();
            return Toast.current()?.get_first_child() ?? null;
        });
    } finally {
        popup.destroy();
        await settle();
    }
}

// Text typed in the overview reaches its search entry; patch 0013 hands it to Spotlight.
async function overviewSearch() {
    const feature = await apexModule(SPOTLIGHT_FEATURE).catch(() => null);
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
    const feature = await apexModule(SPOTLIGHT_FEATURE).catch(() => null);
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

// A diagonal gradient, so a thumbnail that draws the wallpaper is never one flat colour.
function fixtureWallpaper() {
    const {width, height} = FIXTURE_WALLPAPER;
    const rgba = new Uint8Array(width * height * 4);
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            const t = (x / width + y / height) / 2;
            rgba.set([40 + 180 * t, 80 + 150 * t, 160 + 80 * t, 255], (y * width + x) * 4);
        }
    }
    const path = GLib.build_filenamev([GLib.get_user_runtime_dir(), 'g2-wallpaper.png']);
    GLib.file_set_contents(path, Png.encode({width, height, rgba}));
    return Gio.File.new_for_path(path).get_uri();
}

// The 5th to 95th percentile of luminance over the box's central half, from 0 to 1.
function luminanceSpread(image, box, scale) {
    const values = [];
    for (let y = Math.round((box.y + box.height / 4) * scale); y < (box.y + box.height * 3 / 4) * scale; y++) {
        for (let x = Math.round((box.x + box.width / 4) * scale); x < (box.x + box.width * 3 / 4) * scale; x++) {
            const at = (y * image.width + x) * 4;
            values.push((0.2126 * image.rgba[at] + 0.7152 * image.rgba[at + 1] + 0.0722 * image.rgba[at + 2]) / 255);
        }
    }
    values.sort((a, b) => a - b);
    return round(values[Math.floor(values.length * 0.95)] - values[Math.floor(values.length * 0.05)]);
}

// Board 35 with windows: three test windows' previews, their captions and the thumbnails,
// then a fixture wallpaper set while they show; the windows and the wallpaper go afterwards.
async function overviewWithWindows(unit) {
    const background = new Gio.Settings({schema_id: 'org.gnome.desktop.background'});
    const keys = ['picture-uri', 'picture-uri-dark', 'picture-options'];
    const saved = keys.map(key => background.get_value(key));
    const client = Gio.File.new_for_uri(import.meta.url).get_parent().get_child('window.js').get_path();
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
    launcher.setenv('WAYLAND_DISPLAY', GLib.getenv('G2_WAYLAND_DISPLAY') ?? 'apex-g2', true);
    launcher.setenv('GDK_BACKEND', 'wayland', true);
    // The sign-off's apps bring xdg-desktop-portal, whose first answers can outlast the wait.
    launcher.setenv('GDK_DEBUG', 'no-portals', true);
    launcher.setenv('GTK_A11Y', 'none', true);
    const windows = () => global.get_window_actors().filter(a => a.meta_window.get_gtk_application_id() === MOTION_WINDOW_ID);
    // The first client stays as the application; each later one asks it for another window.
    const primary = launcher.spawnv(['gjs', '-m', client]);
    try {
        for (let n = 1; n <= OVERVIEW_WINDOWS; n++) {
            if (n > 1)
                launcher.spawnv(['gjs', '-m', client]);
            // eslint-disable-next-line no-await-in-loop
            if (!await until(() => windows().length >= n, MOTION_WAIT_MS))
                return {error: `${windows().length} of ${OVERVIEW_WINDOWS} test windows mapped`};
        }
        Main.overview.show();
        const previews = () => {
            const found = [];
            const walk = actor => actor.get_children().forEach(child => {
                if (child.constructor.name === 'WindowPreview' && child.mapped)
                    found.push(child);
                walk(child);
            });
            walk(Main.layoutManager.overviewGroup);
            return found;
        };
        await until(() => previews().length >= OVERVIEW_WINDOWS, MOTION_WAIT_MS);
        await settle();
        // Changed with the thumbnails already up: their background managers must follow it.
        const uri = fixtureWallpaper();
        background.set_string('picture-uri', uri);
        background.set_string('picture-uri-dark', uri);
        background.set_string('picture-options', 'zoom');
        await settle();
        global.stage.set_key_focus(null);
        await settle();
        const captured = await capture('overview-windows');
        const image = Png.decode(captured.bytes);
        const scale = image.width / global.stage.width;
        const workspaceThumbnails = Main.overview._overview._controls._thumbnailsBox._thumbnails ?? [];
        const monitor = Main.layoutManager.primaryMonitor;
        const stockBottom = monitor.y + monitor.height;
        const hooks = await apexHooks();
        const Registry = await apexModule(SHADOW_REGISTRY).catch(() => null);
        const result = {
            previews: previews().map(preview => ({
                window: boxOf(preview.windowContainer, unit),
                caption: {...boxOf(preview._title, unit), visible: preview._title.visible && preview._title.opacity > 0},
                styled: preview.has_style_class_name('apex-window-preview'),
                radius: round(preview.get_theme_node().get_border_radius(St.Corner.TOPLEFT) / unit.length),
                layers: Registry ? layerReport(Registry, preview, unit) : null,
            })),
            dock: apexDock() ? boxOf(apexDock()._background, unit) : null,
            dockBox: apexDock() ? boxOf(apexDock().get_parent(), unit) : null,
            bottom: {
                stock: round(stockBottom / unit.length),
                hook: hooks ? round(hooks.value('workspace-bottom', stockBottom, monitor) / unit.length) : null,
            },
            thumbnails: workspaceThumbnails.map(t => {
                const [x, y] = t.get_transformed_position();
                const [width, height] = t.get_transformed_size();
                return {...boxOf(t, unit), spread: luminanceSpread(image, {x, y, width, height}, scale)};
            }),
        };
        // The bar over the fixture wallpaper, in the overview and then on the desktop.
        result.bar = {overview: await barReport(settle, unit)};
        Main.overview.hide();
        result.bar.desktop = await barReport(settle, unit);
        return result;
    } finally {
        Main.overview.hide();
        primary.force_exit();
        await until(() => windows().length === 0, MOTION_WAIT_MS);
        keys.forEach((key, i) => background.set_value(key, saved[i]));
        await settle();
    }
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
        // Stock IconGridLayout._calculateSpacing spreads the columns over the page: the launcher's own pitch.
        const tileSize = appDisplay._grid.layout_manager._getChildrenMaxSize();
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
            scrim: paint(Main.layoutManager.overviewGroup.get_theme_node(), unit),
            grid: {
                columns: appDisplay._grid.layout_manager.columns_per_page,
                rows: appDisplay._grid.layout_manager.rows_per_page,
                iconSize: app?.icon.iconSize ?? null,
            },
            spacing: (([, , h, v]) => ({tile: round(tileSize / unit.length), h: round(h / unit.length), v: round(v / unit.length)}))(
                appDisplay._grid.layout_manager._calculateSpacing(tileSize)),
            tiles: appDisplay._grid.getItemsAtPage(0).map(t => boxOf(t, unit)),
            runningDot: standInStyle('app-grid-running-dot', null, unit),
            pageIndicator: standInStyle('page-indicator-icon', 'page-indicator', unit),
            pageHint: standInStyle('page-navigation-hint next', null, unit),
        };
        // Board 36 is the grid itself, with no folder open: signoff.sh's capture.
        measured.launcherScene = GLib.getenv('G2_SURFACE_SCENES') === '1' ? withoutBytes(await capture('launcher')) : null;
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
            glass: (sibling => sibling?.name === 'apexTilePreviewGlass' ? styleOf(sibling, unit) : null)(preview.get_previous_sibling()),
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

// The desktop alone, as scenes() captures it first: a dock-off case's side of the Fedora comparison.
async function desktopScene() {
    dropStartupNotifications();
    Main.overview.hide();
    const idle = await settle();
    const desktop = {idle, ...await capture('desktop')};
    delete desktop.bytes;
    return {desktopOnly: true, dock: apexDock() ? dockReport(cssUnit()) : null, scenes: {desktop}};
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
    surfaces.quickSettingsLayer = await quickSettingsLayer(unit);
    // Fedora's own shell, in smoke.sh, has no Apex layer to draw shadows.
    if (await apexHooks()) {
        surfaces.shadowLayers = await shadowLayers(unit);
        surfaces.idleRepaints = await idleRepaints();
    }
    surfaces.switcher = await windowSwitcher(unit);
    surfaces.dialog = {
        ...await modalDialog(unit), endSession: await endSessionDialog(unit), updateCard: await updateCard(unit),
        checkBox: await checkBoxDialog(unit),
    };
    surfaces.dateMenu = await calendarMenu(unit);
    surfaces.notificationsLayer = await notificationsLayer(unit);
    surfaces.derived = derivedSurfaces(unit);
    surfaces.tilePreview = await tilePreview(unit);
    surfaces.spotlight = await spotlightStyle(unit);
    surfaces.spotlightKeys = await spotlightKeys();
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
    surfaces.overviewWindows = await overviewWithWindows(unit);

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

function countDescendants(actor, matches) {
    return actor.get_children().reduce((n, child) => n + (matches(child) ? 1 : 0) + countDescendants(child, matches), 0);
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
    // The calendar built in the dark: its day numbers must take the light colours too.
    const {menu} = Main.panel.statusArea.dateMenu;
    menu.open(BoxPointer.PopupAnimation.NONE);
    let calendar;
    try {
        await settle();
        const unit = cssUnit();
        const {days, day, dayStyle} = calendarDays(findDescendant(menu.box, a => a.has_style_class_name?.('calendar')), unit);
        const colours = dayButton => (({foreground, ink}) => ({foreground, ink}))(dayStyle(dayButton));
        calendar = {
            day: colours(day(['calendar-weekday'])),
            otherMonth: colours(day(['calendar-other-month'])),
            today: colours(days.find(d => d.has_style_class_name('calendar-today'))),
        };
    } finally {
        menu.close(BoxPointer.PopupAnimation.NONE);
        await settle();
    }
    return {
        toggle: {title: toggle.title, checkedBefore, checkedAfter: toggle.checked},
        stylesheet, sheet, markerColor, sessionColorScheme, variant, colorSchemeSetting, calendar,
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

// A maximise animates only from a shown frame, so each one waits for the window to rest:
// mapped, maximised or at window.js's size, no size change pending or easing, two still frames.
async function restAt(window, maximised, failure) {
    const actor = window.get_compositor_private();
    const atRest = () => {
        const {width, height} = window.get_frame_rect();
        return actor.mapped && window.is_maximized() === maximised &&
            (maximised || (width === MOTION_WINDOW_SIZE.width && height === MOTION_WINDOW_SIZE.height)) &&
            !Main.wm._resizePending.has(actor) && !Main.wm._resizing.has(actor);
    };
    if (!await settledOverTwoFrames(actor, atRest, MOTION_WAIT_MS))
        throw new Error(failure);
}

async function maximiseTransition(window) {
    const actor = window.get_compositor_private();
    window.maximize();
    // _sizeChangedWindow marks the actor resizing just before it eases the size change.
    const transition = await firstTransition(() =>
        Main.wm._resizing.has(actor) ? actor.get_transition('scale-x') : null);
    await restAt(window, true, 'the maximise never settled');
    const maximised = window.is_maximized();
    window.unmaximize();
    await restAt(window, false, 'the restore never settled');
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

async function previewShadows() {
    const Registry = await import(SHADOW_REGISTRY);
    const unit = cssUnit();
    Main.overview.show();
    await settle();
    const find = actor => actor.get_children().flatMap(c => c.window_container !== undefined ? [c] : find(c));
    const previews = find(Main.layoutManager.overviewGroup).map(preview => ({
        styled: preview.has_style_class_name('apex-window-preview'),
        layers: Registry.layersOf(preview).map(layer => ({
            shown: layer.mapped,
            boxShadow: shadow(layer.get_theme_node(), unit),
            radius: round(layer.get_theme_node().get_border_radius(St.Corner.TOPLEFT) / unit.length),
        })),
    }));
    Main.overview.hide();
    await settle();
    return previews;
}

const EASE_PARAMS = new Set(['duration', 'mode', 'delay', 'onComplete', 'onStopped', 'animationRequired',
    'repeatCount', 'autoReverse']);

// environment.js puts every ease on these prototypes: each call is recorded with the transitions
// it left, named by the canonical property (translation-y), and whether a ui/apex/ frame made it.
function recordEases(calls) {
    const wrap = (proto, method, read) => {
        const original = proto[method];
        proto[method] = function (...args) {
            const result = original.apply(this, args);
            const {names, params} = read(args);
            const frames = new Error().stack.split('\n').slice(1);
            const apexFrame = frames.find(f => f.includes('/ui/apex/'));
            calls.push({
                apex: !!apexFrame,
                where: (apexFrame ?? frames[1] ?? '').replace(/^.*@/, '').replace(/^resource:\/\/\/org\/gnome\/shell\//, ''),
                required: params?.animationRequired === true,
                durations: names.map(name => this.get_transition(name.replaceAll('_', '-'))?.get_duration() ?? 0),
            });
            return result;
        };
        return () => (proto[method] = original);
    };
    const actor = ([params]) => ({names: Object.keys(params ?? {}).filter(k => !EASE_PARAMS.has(k)), params});
    const property = ([name, , params]) => ({names: [name], params});
    const adjustment = ([, params]) => ({names: ['value'], params});
    const restores = [
        wrap(Clutter.Actor.prototype, 'ease', actor),
        wrap(Clutter.Actor.prototype, 'easeAsync', actor),
        wrap(Clutter.Actor.prototype, 'ease_property', property),
        wrap(Clutter.Actor.prototype, 'ease_property_async', property),
        wrap(St.Adjustment.prototype, 'ease', adjustment),
        wrap(St.Adjustment.prototype, 'easeAsync', adjustment),
    ];
    return () => restores.forEach(restore => restore());
}

// Each Apex surface opened and closed once: the dock's lift and intellihide, the overview's
// thumbnails, Spotlight, Quick Settings, the calendar and a dialog with its shadow layer.
async function surfaceEases(window) {
    const calls = [];
    const steps = [];
    const restore = recordEases(calls);
    const step = async (name, open, close) => {
        const before = calls.length;
        await open();
        await Scripting.sleep(MOTION_SETTLE_MS);
        await close();
        await Scripting.sleep(MOTION_SETTLE_MS);
        steps.push({name, eases: calls.length - before, apexEases: calls.slice(before).filter(c => c.apex).length});
    };
    try {
        const icon = findDescendant(apexDock() ?? new St.Widget(), a => a._delegate?.app && a.icon);
        await step('dock-lift', () => icon && (icon.hover = true), () => icon && (icon.hover = false));
        await step('intellihide', () => window.maximize(), () => window.unmaximize());
        await step('overview', () => Main.overview.show(), () => Main.overview.hide());
        const spotlight = (await apexModule(SPOTLIGHT_FEATURE).catch(() => null))?.popup();
        await step('spotlight', () => spotlight?.open(), () => spotlight?.close());
        for (const [name, indicator] of [['quick-settings', 'quickSettings'], ['calendar', 'dateMenu']]) {
            const {menu} = Main.panel.statusArea[indicator];
            // eslint-disable-next-line no-await-in-loop
            await step(name, () => menu.open(BoxPointer.PopupAnimation.FULL), () => menu.close(BoxPointer.PopupAnimation.FULL));
        }
        // Closed, a stock dialog destroys itself, before the recorder reads its transitions.
        const dialog = new ModalDialog.ModalDialog({destroyOnClose: false});
        await step('dialog', () => dialog.open(), () => dialog.close());
        dialog.destroy();
    } finally {
        restore();
    }
    const lasting = calls.filter(c => !c.required && c.durations.some(d => d > 0));
    return {
        steps,
        eases: calls.length,
        apexEases: calls.filter(c => c.apex).length,
        lasting: lasting.map(({apex, where, durations}) => ({apex, where, durations})),
    };
}

// The bar as a maximised window turns it solid and as un-maximising it turns it back.
async function solidBar(unit) {
    Main.overview.hide();
    await settle();
    const client = Gio.File.new_for_uri(import.meta.url).get_parent().get_child('window.js').get_path();
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
    launcher.setenv('WAYLAND_DISPLAY', GLib.getenv('G2_WAYLAND_DISPLAY') ?? 'apex-g2', true);
    launcher.setenv('GDK_BACKEND', 'wayland', true);
    const find = () => global.get_window_actors().map(a => a.meta_window)
        .find(w => w.get_gtk_application_id() === MOTION_WINDOW_ID);
    const read = () => {
        const node = Main.panel.get_theme_node();
        const glass = Main.panel.get_effect('apex-glass');
        return {
            solid: Main.panel.has_style_class_name('apex-solid-bar'), background: hex(node.get_background_color()),
            boxShadow: shadow(node, unit), glass: glass ? {enabled: glass.enabled} : null,
        };
    };
    const clientProcess = launcher.spawnv(['gjs', '-m', client]);
    try {
        if (!await until(() => find(), MOTION_WAIT_MS))
            return {error: `no ${MOTION_WINDOW_ID} window in ${MOTION_WAIT_MS} ms`};
        const window = find();
        await restAt(window, false, 'the window never showed');
        await settle();
        const steps = {unmaximised: read()};
        window.maximize();
        await restAt(window, true, 'the maximise never settled');
        await settle();
        steps.maximised = read();
        window.unmaximize();
        await restAt(window, false, 'the restore never settled');
        await settle();
        steps.restored = read();
        return {steps};
    } finally {
        clientProcess.force_exit();
        await until(() => !find(), MOTION_WAIT_MS);
        await settle();
    }
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
    await restAt(window, false, 'the window never showed');
    window.maximize();
    await restAt(window, true, 'the warm-up maximise never settled');
    window.unmaximize();
    await restAt(window, false, 'the restore never settled');
    const interfaceSettings = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
    // main.js inhibits animations without hardware-accelerated rendering, as G2's headless shell has.
    const stSettings = St.Settings.get();
    const uninhibited = interfaceSettings.get_boolean('enable-animations') && !stSettings.enable_animations;
    if (uninhibited)
        stSettings.uninhibit_animations();
    const animated = {maximise: await maximiseTransition(window), overview: await overviewTransition()};
    animated.surfaces = await surfaceEases(window);
    const previews = await previewShadows();
    interfaceSettings.set_boolean('enable-animations', false);
    await Scripting.sleep(MOTION_SETTLE_MS);
    const still = {maximise: await maximiseTransition(window), overview: await overviewTransition()};
    still.surfaces = await surfaceEases(window);
    // Locate Pointer's ripples are animationRequired: an a11y aid that animates regardless.
    interfaceSettings.set_boolean('locate-pointer', true);
    await Scripting.sleep(MOTION_SETTLE_MS);
    Main.locatePointer.show();
    still.locatePointer = transitionInfo(Main.locatePointer._ripples?._ripple1.get_transition('scale-x') ?? null);
    interfaceSettings.set_boolean('locate-pointer', false);
    const enableAnimations = stSettings.enable_animations;
    if (uninhibited)
        stSettings.inhibit_animations();
    return {uninhibited, enableAnimations, animated, still, previews};
}

// main.js connects to startup-complete only after importing this module, right after init(). A startup
// that completed during the import gets the signal again then, so main.js's handler runs, and runs the probe.
export function init() {
    if (Main.layoutManager._startingUp)
        return;
    startedLate = true;
    console.log('APEXG2-LATE startup completed while main.js imported the probe; startup-complete again');
    GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
        Main.layoutManager.emit('startup-complete');
        return GLib.SOURCE_REMOVE;
    });
}

function withoutBytes(captured) {
    delete captured.bytes;
    return captured;
}

// Boards 15 and 35 have windows: three real apps for the owner's sign-off (G2_SIGNOFF=1).
async function signoffWindows() {
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
    launcher.setenv('WAYLAND_DISPLAY', GLib.getenv('G2_WAYLAND_DISPLAY') ?? 'apex-g2', true);
    launcher.setenv('GDK_BACKEND', 'wayland', true);
    const scopeless = Gio.File.new_for_uri(import.meta.url).get_parent().get_child('scopeless').get_path();
    launcher.setenv('PATH', `${scopeless}:${GLib.getenv('PATH')}`, true);
    const sourcesBefore = new Set(Main.messageTray.getSources());
    for (const argv of SIGNOFF_APPS)
        launcher.spawnv(argv);
    const tracker = Shell.WindowTracker.get_default();
    const appsShown = () => [...new Set(global.get_window_actors().map(a => tracker.get_window_app(a.meta_window)?.get_id()))]
        .filter(Boolean);
    const shown = await until(() => appsShown().length >= SIGNOFF_APPS.length, SIGNOFF_WINDOWS_MS);
    // Calendar presents itself once it has loaded; unfocused, that posts "Calendar is ready". So the apps settle
    // first, and each window then gets the focus in a fixed order, which also fixes the switcher's order and the bar.
    const loaded = await windowsQuiet(SIGNOFF_QUIET_MS, SIGNOFF_WINDOWS_MS);
    // Calendar's own present can still land between two of these, so the order is read back, and redone until it holds.
    // The switcher sorts apps by their windows' user time, not the tab list: equal timestamps leave a tie in hash order.
    const expectedOrder = [...SIGNOFF_FOCUS_ORDER].reverse();
    const order = () => global.display.get_tab_list(Meta.TabList.NORMAL, null).map(w => tracker.get_window_app(w)?.get_id());
    const byUserTime = () => Shell.AppSystem.get_default().get_running().map(app => app.get_id())
        .filter(id => expectedOrder.includes(id));
    // A window draws its focused or backdrop state in its next frame: one whose last frame came before its last
    // focus change shows the other state, and a capture of the dark boards caught Text Editor drawn focused.
    const drawn = new FocusFrames(expectedOrder.map(id => global.get_window_actors()
        .find(a => tracker.get_window_app(a.meta_window)?.get_id() === id)).filter(Boolean));
    const ordered = () => [order(), byUserTime()].every(ids => JSON.stringify(ids) === JSON.stringify(expectedOrder)) &&
        drawn.stale().length === 0;
    const keepOrder = what => {
        if (!ordered()) {
            throw new Error(`${what} focus order is ${order().join(', ')}, by user time ${byUserTime().join(', ')}, ` +
                `not ${expectedOrder.join(', ')}; not drawn since their focus changed: ${drawn.stale().join(', ') || 'none'}`);
        }
    };
    let quiet = loaded, focusAttempts = 0;
    while (!ordered() && focusAttempts < SIGNOFF_FOCUS_ATTEMPTS) {
        focusAttempts++;
        let time = 0;
        for (const id of SIGNOFF_FOCUS_ORDER) {
            const window = global.get_window_actors().map(a => a.meta_window).find(w => tracker.get_window_app(w)?.get_id() === id);
            // eslint-disable-next-line no-await-in-loop
            time = await timeAfter(time);
            if (window)
                Main.activateWindow(window, time);
            // On top, it draws its focused frame before the next window covers it.
            // eslint-disable-next-line no-await-in-loop
            await until(() => !drawn.stale().includes(id), SIGNOFF_WINDOWS_MS);
        }
        // eslint-disable-next-line no-await-in-loop
        quiet = await windowsQuiet(SIGNOFF_QUIET_MS, SIGNOFF_WINDOWS_MS);
    }
    keepOrder("the sign-off windows'");
    const notified = Main.messageTray.getSources().filter(source => !sourcesBefore.has(source))
        .map(source => source.title);
    if (notified.length > 0)
        throw new Error(`the sign-off windows brought notifications from ${notified.join(', ')}`);
    // Off every window preview and the bar's pills; a new device can drop one axis of its first motion.
    const monitor = Main.layoutManager.primaryMonitor;
    const pointer = global.stage.context.get_backend().get_default_seat()
        .create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
    const target = [monitor.x + monitor.width - 1, monitor.y + monitor.height / 4];
    const pointerPlaced = await until(() => {
        const [x, y] = global.get_pointer();
        if (x === target[0] && y === target[1])
            return true;
        pointer.notify_absolute_motion(GLib.get_monotonic_time(), ...target);
        return false;
    }, 3000);
    await settle();
    Main.overview.show();
    // A window still mapping joins the overview's workspace late: wait for its preview.
    const previews = await until(() => countDescendants(Main.layoutManager.overviewGroup,
        a => a.constructor.name === 'WindowPreview' && a.mapped) >= SIGNOFF_APPS.length, SIGNOFF_WINDOWS_MS);
    await settle();
    await windowsRedrawn("the overview's");
    global.stage.set_key_focus(null);
    const [pointerX, pointerY] = global.get_pointer();
    const panelStates = Object.entries(Main.panel.statusArea)
        .map(([name, item]) => [name, item.get_style_pseudo_class?.()])
        .filter(([, states]) => states);
    keepOrder("the overview's");
    const overview = withoutBytes(await capture('signoff-overview'));
    Main.overview.hide();
    await settle();
    const {AppSwitcherPopup} = await import('resource:///org/gnome/shell/ui/altTab.js');
    const popup = new AppSwitcherPopup();
    // No modifier mask: nothing held down, so the popup stays until it is destroyed.
    popup.show(false, 'switch-applications', 0);
    await settle();
    keepOrder("the switcher's");
    const altTab = withoutBytes(await capture('signoff-alt-tab', [], {switcher: popup._items.map(item => item.app.get_id())}));
    popup.destroy();
    await settle();
    drawn.destroy();
    return {
        shown, previews, apps: appsShown(), overview: overview.file, altTab: altTab.file,
        loaded, quiet, focusAttempts, pointerPlaced, notified, drawn: drawn.report(),
        atOverview: {pointer: [pointerX, pointerY], panelStates: Object.fromEntries(panelStates)},
    };
}

// When each window's focus state last changed and when it last drew a frame, in ms from the watch's start.
class FocusFrames {
    constructor(actors) {
        this._start = GLib.get_monotonic_time();
        this._tracker = Shell.WindowTracker.get_default();
        this._windows = actors.map(actor => {
            const entry = {actor, id: this._tracker.get_window_app(actor.meta_window)?.get_id(), focusUs: 0, frameUs: 0};
            entry.handlers = [
                [actor, actor.connect('damaged', () => (entry.frameUs = this._now()))],
                [actor.meta_window, actor.meta_window.connect('notify::appears-focused', () => (entry.focusUs = this._now()))],
            ];
            return entry;
        });
    }

    _now() {
        return Math.max(1, GLib.get_monotonic_time() - this._start);
    }

    stale() {
        return this._windows.filter(w => w.frameUs < w.focusUs).map(w => w.id);
    }

    report() {
        return Object.fromEntries(this._windows.map(w => [w.id,
            {focusMs: Math.round(w.focusUs / 1000), frameMs: Math.round(w.frameUs / 1000)}]));
    }

    destroy() {
        this._windows.forEach(w => w.handlers.forEach(([object, id]) => object.disconnect(id)));
    }
}

async function timeAfter(previous) {
    await until(() => global.display.get_current_time_roundtrip() > previous, 1000);
    return global.display.get_current_time_roundtrip();
}

// A window hidden behind another draws its backdrop state only once the overview shows it, and keeps it
// for the switcher, which cannot wait as long: with no modifier held it activates its selection after 1.5 s.
async function windowsRedrawn(what) {
    if (!await windowsQuiet(SIGNOFF_QUIET_MS, SIGNOFF_WINDOWS_MS))
        throw new Error(`${what} windows still repaint after ${SIGNOFF_WINDOWS_MS} ms`);
}

// Text Editor retitles its new document a draft after it maps; a preview shows whatever frame came last.
async function windowsQuiet(quietMs, timeoutMs) {
    let last = GLib.get_monotonic_time();
    const handlers = global.get_window_actors().map(a => [a, a.connect('damaged', () => (last = GLib.get_monotonic_time()))]);
    try {
        return await until(() => GLib.get_monotonic_time() - last > quietMs * 1000, timeoutMs);
    } finally {
        handlers.forEach(([actor, id]) => actor.disconnect(id));
    }
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

function runningDots() {
    return (apexDock()?._box.get_children() ?? []).map(item => item.child?._delegate)
        .filter(icon => icon?.app?.state === Shell.AppState.RUNNING && icon._dot)
        .map(icon => ({app: icon.app.get_name(), colour: hex(icon._dot.get_theme_node().get_background_color())}));
}

// ROADMAP S2a: each bar and dock key changes the running shell, and its reset changes it back.
async function liveKeys(settings, unit) {
    const read = () => {
        const dock = dockReport(unit);
        const focused = Main.panel.statusArea['apex-focused-app'];
        return {
            focusedApp: focused ? {visible: focused.container.visible, name: focused.accessible_name} : null,
            iconSizes: dock.items.filter(item => item.iconSize != null).map(item => item.iconSize),
            kinds: dock.items.map(item => item.kind),
            dots: runningDots(),
        };
    };
    const steps = {};
    for (const [name, key, value] of [['focusedAppOff', 'show-focused-app-name', false],
        ['small', 'dock-icon-size', 'small'], ['large', 'dock-icon-size', 'large'],
        ['dotsOff', 'dock-running-indicators', false], ['trashOff', 'dock-show-trash', false]]) {
        if (typeof value === 'boolean')
            settings.set_boolean(key, value);
        else
            settings.set_string(key, value);
        // eslint-disable-next-line no-await-in-loop
        await settle();
        steps[name] = {set: read()};
        settings.reset(key);
        // eslint-disable-next-line no-await-in-loop
        await settle();
        steps[name].reset = read();
    }
    return steps;
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
        steps.liveKeys = await liveKeys(settings, unit);
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

// The surfaces G2's scenes open, as they open them, for session-defaults.js's icon walk: board 34's date
// menu, 35, 36, Spotlight's results (38), the switcher (15), board 16's three, 13's dialog, 14 and 19.
function iconSurfaces() {
    const overview = async state => {
        Main.overview.show();
        await settle();
        Main.overview.dash.showAppsButton.checked = state === 'apps';
        return {
            root: Main.overview._overview,
            close: () => {
                Main.overview.dash.showAppsButton.checked = false;
                Main.overview.hide();
            },
        };
    };
    return {
        // Do Not Disturb's switch draws its on and off glyphs only with Show Status Shapes on.
        dateMenu: () => {
            const a11y = new Gio.Settings({schema_id: 'org.gnome.desktop.a11y.interface'});
            const shapes = a11y.get_boolean('show-status-shapes');
            a11y.set_boolean('show-status-shapes', true);
            const source = new MessageTray.Source({title: 'G2 Updates', iconName: 'software-update-available-symbolic'});
            Main.messageTray.add(source);
            source.addNotification(new MessageTray.Notification({
                source, title: 'Update ready', body: 'Starts after the next restart.', urgency: MessageTray.Urgency.LOW,
            }));
            const {menu} = Main.panel.statusArea.dateMenu;
            menu.open(BoxPointer.PopupAnimation.NONE);
            return {
                root: menu.box,
                close: () => {
                    menu.close(BoxPointer.PopupAnimation.NONE);
                    source.destroy();
                    a11y.set_boolean('show-status-shapes', shapes);
                },
            };
        },
        overview: () => overview('windows'),
        launcher: () => overview('apps'),
        spotlight: async () => {
            if ((await apexHooks())?.safe() !== false)
                return null;
            const {Popup} = await import('resource:///org/gnome/shell/ui/apex/spotlight/popup.js');
            const popup = new Popup(spotlightProviders, 0);
            popup.open();
            popup.panel.get_children()[0].get_children()[1].set_text('disk');
            return {root: popup.panel, close: () => popup.destroy()};
        },
        switcher: () => {
            const list = new SwitcherPopup.SwitcherList(true);
            for (const name of SWITCHER_APPS) {
                const app = new St.BoxLayout({style_class: 'alt-tab-app', orientation: Clutter.Orientation.VERTICAL});
                app.add_child(new St.Icon({icon_name: 'application-x-executable', icon_size: SWITCHER_ICON_SIZE}));
                app.add_child(new St.Label({text: name}));
                list.addItem(app, app.get_last_child());
            }
            Main.uiGroup.add_child(list);
            return {root: list, close: () => list.destroy()};
        },
        surfaces: async () => {
            const opened = [openPopupMenu(), await openOsd(), openBanner()];
            return {
                roots: [opened[0].root, opened[1].root, () => Main.messageTray._banner],
                close: () => opened.forEach(o => o.close()),
            };
        },
        dialog: () => openPromptDialog({avatar: true}),
        endSession: async () => {
            const dialog = await openShellEndSession();
            return {root: dialog.dialogLayout._dialog, close: () => dialog.cancel()};
        },
        screenshot: async () => {
            await Main.screenshotUI.open();
            return {root: Main.screenshotUI, close: () => Main.screenshotUI.close(true)};
        },
    };
}

// gnome-shell 51's shutdown destroys the tray, then runs a main loop that fires any banner timeout
// still armed; every case but shutdown-banner exits with the tray idle, Apex's notifications or not.
async function drainMessageTray() {
    dropStartupNotifications();
    const idle = await until(() => Main.messageTray._banner === null, TRAY_DRAIN_MS);
    Main.messageTray._updateNotificationTimeout(0);
    Main.messageTray._resetNotificationLeftTimeout();
    return idle;
}

// That loop also reaches the date menu's destroyed events section whenever the calendar server or the app
// list signals in it: the event source's changes (dateMenu.js:297), its HasCalendars (:326), the apps (:322).
const DATE_MENU_SIGNALS = [['source', 'changed'], ['source', 'notify', 'has-calendars'], ['apps', 'installed-changed']];

function dateMenuSources() {
    return {source: Main.panel.statusArea.dateMenu._eventSource, apps: Shell.AppSystem.get_default()};
}

// Every case blocks each handler on those paths before the shell exits, so none can run in that loop.
function cutDateMenu() {
    const objects = dateMenuSources();
    return Object.fromEntries(DATE_MENU_SIGNALS.map(([object, signalId, detail]) => [
        detail ? `${signalId}::${detail}` : signalId,
        GObject.signal_handlers_block_matched(objects[object], detail ? {signalId, detail} : {signalId}),
    ]));
}

// The races made certain: the tray's timeout due in a slowed shutdown loop, each date-menu signal sent in it.
// The shell exits here, not after scripting.js's helper round trip, which could outlast the timeout.
async function shutdownWithBanner() {
    const cut = cutDateMenu();
    Main.notify('G2 banner', 'shown as the shell exits');
    await settle();
    const {source, apps} = dateMenuSources();
    const writeHistory = Main.timeLimitsManager.shutdown.bind(Main.timeLimitsManager);
    Main.timeLimitsManager.shutdown = async () => {
        await Scripting.sleep(SHUTDOWN_HISTORY_DELAY_MS);
        source.emit('changed');
        source.notify('has-calendars');
        apps.emit('installed-changed');
        await writeHistory();
    };
    Main.messageTray._updateNotificationTimeout(SHUTDOWN_BANNER_TIMEOUT_MS);
    const tray = Main.messageTray;
    console.log(`APEXG2-SHUTDOWN-BANNER ${JSON.stringify({
        pending: tray._banner !== null || tray._notificationQueue.length > 0, armed: tray._notificationTimeoutId !== 0, cut,
    })}`);
    global.context.terminate();
}

export async function run() {
    actionModeAtRun = actionModeName();
    const pingId = keepPerfHelperAwake();
    try {
        await runProbe();
    } finally {
        GLib.source_remove(pingId);
    }
    if (GLib.getenv('G2_SHUTDOWN_BANNER') === '1')
        await shutdownWithBanner();
    else
        console.log(`APEXG2-EXIT ${JSON.stringify({tray: await drainMessageTray(), cut: cutDateMenu()})}`);
}

async function runProbe() {
    await Scripting.sleep(REPORT_AFTER_MS);
    console.log(`APEXG2 ${JSON.stringify(await report())}`);
    let backdrop;
    try {
        backdrop = await (await import('./backdrop.js')).backdropReport({settle});
    } catch (e) {
        backdrop = {error: `${e.message}\n${e.stack}`};
    }
    console.log(`APEXG2-BACKDROP ${JSON.stringify(backdrop)}`);
    let defaults;
    try {
        defaults = (await import('./session-defaults.js')).sessionDefaultsReport({apexDock});
    } catch (e) {
        defaults = {error: `${e.message}\n${e.stack}`};
    }
    console.log(`APEXG2-SESSION ${JSON.stringify(defaults)}`);

    if (GLib.getenv('G2_SCENES') === '1') {
        let result;
        try {
            result = await scenes();
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-SCENES ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_DESKTOP') === '1') {
        let result;
        try {
            result = await desktopScene();
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-SCENES ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_OVERVIEW_WINDOWS') === '1') {
        let result;
        try {
            dropStartupNotifications();
            result = await overviewWithWindows(cssUnit());
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-OVERVIEW-WINDOWS ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_ONE_GPU') === '1') {
        let result;
        try {
            // A startup banner's timeout could otherwise fire as the shell exits, after dateMenu.js went.
            dropStartupNotifications();
            result = await dockAppMenu();
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-GPU ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_A11Y') === '1') {
        let result;
        try {
            const A11y = await import('./a11y.js');
            result = await A11y.a11yReport({
                settle, unit: cssUnit(), apexDock, findDescendant, openPopupMenu, openOsd, openBanner,
                openModalDialog: () => openPromptDialog({avatar: true}), openEndSessionDialog: openShellEndSession, withSpotlight,
                openMountPasswordDialog,
            });
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-A11Y ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_SOLID_BAR') === '1') {
        let result;
        try {
            result = await solidBar(cssUnit());
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-SOLID-BAR ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_INDICATORS') === '1') {
        let result;
        try {
            const Indicators = await import('./indicators.js');
            result = await Indicators.indicatorsReport({cssUnit, settle, capture, dropStartupNotifications});
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-INDICATORS ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_SIGNOFF') === '1') {
        let result;
        try {
            result = await signoffWindows();
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-SIGNOFF ${JSON.stringify(result)}`);
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

    if (GLib.getenv('G2_KEYS') === '1') {
        let result;
        try {
            result = await keysCase();
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-KEYS ${JSON.stringify(result)}`);
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

    if (GLib.getenv('G2_IDLE') === '1') {
        let result;
        try {
            const Idle = await import('./idle.js');
            result = await Idle.idleReport({settle, dropStartupNotifications, apexDock});
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-IDLE ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_GLASS_LOAD') === '1') {
        let result;
        try {
            const GlassLoad = await import('./glass-load.js');
            result = await GlassLoad.glassLoadReport({dropStartupNotifications});
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-GLASS-LOAD ${JSON.stringify(result)}`);
    }

    const loadStress = Number(GLib.getenv('G2_GLASS_LOAD_STRESS') ?? '0');
    if (loadStress > 0) {
        let result;
        try {
            const GlassLoad = await import('./glass-load.js');
            result = await GlassLoad.realBoxStress(loadStress, {dropStartupNotifications});
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-GLASS-LOAD-STRESS ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_DOCK_PIN') === '1') {
        let result;
        try {
            const DockPin = await import('./dock-pin.js');
            result = await DockPin.dockPinReport({settle, dropStartupNotifications, apexDock});
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-DOCK-PIN ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_DOCK_DND') === '1') {
        let result;
        try {
            const DockDnd = await import('./dock-dnd.js');
            result = await DockDnd.dockDndReport({settle, dropStartupNotifications, apexDock});
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-DOCK-DND ${JSON.stringify(result)}`);
    }

    if (GLib.getenv('G2_DOCK_EXTERNAL') === '1') {
        let result;
        try {
            const DockExternal = await import('./dock-external.js');
            result = await DockExternal.dockExternalReport({
                settle, dropStartupNotifications, apexDock, dockReport: () => dockReport(cssUnit()),
            });
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-DOCK-EXTERNAL ${JSON.stringify(result)}`);
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

    if (GLib.getenv('G2_SCENES') === '1') {
        let result;
        try {
            result = await (await import('./session-defaults.js')).surfaceIconsReport({settle, surfaces: iconSurfaces()});
        } catch (e) {
            result = {error: `${e.message}\n${e.stack}`};
        }
        console.log(`APEXG2-SESSION-SURFACES ${JSON.stringify(result)}`);
    }

    console.log(`APEXG2-MODES ${JSON.stringify({
        late: startedLate, atRun: actionModeAtRun, atEnd: actionModeName(), modals: Main.modalCount, overview: Main.overview.visible,
    })}`);

    const wait = Number(GLib.getenv('PROBE_WAIT') ?? '0');
    if (wait > 0) {
        await Scripting.sleep(wait * 1000);
        console.log(`APEXG2-SURVIVED ${wait}s startingMarker=${startingMarker()}`);
    }
}
