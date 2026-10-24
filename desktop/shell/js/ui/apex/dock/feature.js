// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's dock: ApexDock floats centred above the primary monitor's bottom edge, with
// no strut, under fullscreen windows hidden, and stands in for the overview's own dash.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';

import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';
import {ApexDock} from './dock.js';

const SCHEMA_ID = 'io.github.apex_linux.Apex.Desktop';
const ICON_SIZE_KEY = 'dock-icon-size';
const SHOW_TRASH_KEY = 'dock-show-trash';
const RUNNING_INDICATORS_KEY = 'dock-running-indicators';
const ICON_SIZES = {small: 46, medium: 54, large: 62};
const BOTTOM_GAP_PROPERTY = '-apex-bottom-gap';
const SHOW_APPS_ICON = 'view-app-grid';

let _settings = null;
let _box = null;
let _dock = null;
let _connections = [];

function _iconSize() {
    return ICON_SIZES[_settings.get_string(ICON_SIZE_KEY)] ?? ICON_SIZES.medium;
}

function _place() {
    const monitor = Main.layoutManager.primaryMonitor;
    if (!monitor)
        return;
    const gap = _dock.get_stage() ? _dock.get_theme_node().get_length(BOTTOM_GAP_PROPERTY) : 0;
    _box.set_position(
        Math.round(monitor.x + (monitor.width - _box.width) / 2),
        Math.round(monitor.y + monitor.height - _box.height - gap));
    // The overview lays its views out above its own dash's height, hidden or not.
    Main.overview.dash.height = _box.height + gap;
}

function _syncSettings() {
    _dock.setIconSize(_iconSize());
    _dock.setTrashVisible(_settings.get_boolean(SHOW_TRASH_KEY));
    _dock.setRunningIndicators(_settings.get_boolean(RUNNING_INDICATORS_KEY));
}

function _syncLock() {
    _dock.visible = !Main.sessionMode.isLocked;
}

// The overview's dash stays hidden, and its Show Apps button follows the dock's.
function _dockShowAppsToggled() {
    const {checked} = _dock.showAppsButton;
    const overviewButton = Main.overview.dash.showAppsButton;
    if (checked === overviewButton.checked)
        return;
    if (checked && !Main.overview.visible)
        Main.overview.showApps();
    else
        overviewButton.checked = checked;
}

function _overviewShowAppsToggled() {
    _dock.showAppsButton.checked = Main.overview.dash.showAppsButton.checked;
}

function _inDock(actor) {
    return actor.get_parent()?.get_parent() instanceof ApexDock;
}

export function configure(featureName) {
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(SCHEMA_ID, true);
    const missing = [ICON_SIZE_KEY, SHOW_TRASH_KEY, RUNNING_INDICATORS_KEY]
        .filter(key => !schema?.has_key(key));
    if (missing.length > 0)
        throw new Error(`${SCHEMA_ID} has no key ${missing.join(', ')}`);
    _settings = new Gio.Settings({settings_schema: schema});
    Hooks.provide(featureName, 'dash-favorites-separator',
        (stock, dash) => dash instanceof ApexDock ? false : stock);
    Hooks.provide(featureName, 'show-apps-icon-name',
        (stock, showAppsIcon) => _inDock(showAppsIcon) ? SHOW_APPS_ICON : stock);
}

export function enable() {
    _dock = new ApexDock(_iconSize());
    _box = new St.Widget({name: 'apexDockBox', layout_manager: new Clutter.BinLayout()});
    _box.add_child(_dock);
    Main.layoutManager.addChrome(_box, {trackFullscreen: true});
    Main.overview.dash.hide();

    _connections = [
        [_settings, `changed::${ICON_SIZE_KEY}`, _syncSettings],
        [_settings, `changed::${SHOW_TRASH_KEY}`, _syncSettings],
        [_settings, `changed::${RUNNING_INDICATORS_KEY}`, _syncSettings],
        [_box, 'notify::width', _place],
        [_box, 'notify::height', _place],
        [_dock, 'style-changed', _place],
        [Main.layoutManager, 'monitors-changed', _place],
        [Main.sessionMode, 'updated', _syncLock],
        [_dock.showAppsButton, 'notify::checked', _dockShowAppsToggled],
        [Main.overview.dash.showAppsButton, 'notify::checked', _overviewShowAppsToggled],
        [Main.overview, 'hidden', _overviewShowAppsToggled],
    ].map(([emitter, signal, fn]) => [emitter, emitter.connect(signal, fn)]);
    _syncSettings();
    _syncLock();
    _place();
}

export function disable() {
    for (const [emitter, id] of _connections)
        emitter.disconnect(id);
    _connections = [];
    if (Main.overview.dash) {
        Main.overview.dash.height = -1;
        Main.overview.dash.show();
    }
    _box?.destroy();
    _box = null;
    _dock = null;
}
