// SPDX-License-Identifier: GPL-2.0-or-later

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

import * as Hooks from './hooks.js';

// Each <name>/feature.js exports configure(name), which may be async, and synchronous
// enable() and disable().
const FEATURES_IN_ENABLE_ORDER = [];

const TEST_FAULT_PHASES = ['configure', 'enable', 'abort-after-enable'];

// Upstream gives every mode 'prefer-dark'; the greeter keeps it.
const LIGHT_SESSION_MODES = new Set(['user', 'unlock-dialog']);

// apex-shell-safe.service acts only while this file exists (ConditionPathExists=).
const CRASH_GUARD_MARKER = 'apex-shell-starting';
const CRASH_GUARD_WINDOW_SECONDS = 60;

const _features = [];
let _settings = null;
let _on = false;

function _sessionMode(params, mode) {
    return LIGHT_SESSION_MODES.has(mode) ? {...params, colorScheme: 'prefer-light'} : params;
}

function _featureNames() {
    const fault = GLib.getenv('APEX_SHELL_TEST_FAULT');
    if (fault === null)
        return FEATURES_IN_ENABLE_ORDER;
    if (!TEST_FAULT_PHASES.includes(fault)) {
        console.warn(`Apex: APEX_SHELL_TEST_FAULT=${fault} names no phase ` +
            `(${TEST_FAULT_PHASES.join(', ')}); no fault injected`);
        return FEATURES_IN_ENABLE_ORDER;
    }
    console.warn(`Apex: APEX_SHELL_TEST_FAULT=${fault}: the fault feature fails in that phase`);
    return [...FEATURES_IN_ENABLE_ORDER, 'fault', 'witness'];
}

async function _configureFeature(name) {
    try {
        const feature = await import(`./${name}/feature.js`);
        // Awaited, so that an async configure that rejects lands in this catch too.
        await feature.configure?.(name);
        _features.push({name, feature});
    } catch (e) {
        Hooks.withdraw(name);
        console.error(`Apex: feature ${name} off for this session (configure: ${e})`);
    }
}

export async function configure(settings) {
    _settings = settings;
    Hooks.provide('core', 'session-mode', _sessionMode);

    const disabled = new Set(settings.get_strv('disabled-features'));
    for (const name of _featureNames()) {
        if (disabled.has(name)) {
            console.log(`Apex: feature ${name} is in disabled-features`);
            continue;
        }
        // eslint-disable-next-line no-await-in-loop
        await _configureFeature(name);
    }
}

function _createCrashGuardMarker() {
    const file = Gio.File.new_for_path(
        GLib.build_filenamev([GLib.get_user_runtime_dir(), CRASH_GUARD_MARKER]));
    try {
        // Not empty: g_file_replace_contents silently refuses an empty array (NULL).
        const contents = new TextEncoder().encode(`${new Date().toISOString()}\n`);
        file.replace_contents(contents, null, false,
            Gio.FileCreateFlags.REPLACE_DESTINATION, null);
    } catch (e) {
        console.warn(`Apex: cannot create ${file.get_path()}: ${e.message}`);
        return;
    }
    const remove = () => {
        try {
            file.delete(null);
        } catch {}
    };
    const shutdownId = global.connect('shutdown', remove);
    GLib.timeout_add_seconds_once(GLib.PRIORITY_DEFAULT, CRASH_GUARD_WINDOW_SECONDS, () => {
        global.disconnect(shutdownId);
        remove();
    });
}

function _enableFeatures() {
    for (const {name, feature} of [..._features]) {
        try {
            feature.enable?.();
            console.log(`Apex: feature ${name} enabled`);
        } catch (e) {
            _features.splice(_features.findIndex(f => f.name === name), 1);
            Hooks.withdraw(name);
            console.error(`Apex: feature ${name} off for this session (enable: ${e})`);
            try {
                feature.disable?.();
            } catch {}
        }
    }
    _on = true;
}

function _disableFeatures() {
    _on = false;
    for (const {name, feature} of [..._features].reverse()) {
        try {
            feature.disable?.();
        } catch (e) {
            console.error(`Apex: feature ${name} did not disable cleanly: ${e}`);
        }
    }
}

// Only _sync recomputes the session mode's colour scheme and makes main.js reload its
// stylesheet, which hooks.safe() now picks.
async function _restyle() {
    try {
        const Main = await import('../main.js');
        Main.sessionMode._sync();
    } catch (e) {
        console.error(`Apex: cannot restyle the shell: ${e}`);
    }
}

async function _followLayerEnabled() {
    const on = _settings.get_boolean('layer-enabled');
    if (on === _on)
        return;
    console.log(`Apex: layer-enabled is ${on}: the ${on ? 'Apex' : 'stock'} shell`);
    if (on)
        _enableFeatures();
    else
        _disableFeatures();
    await _restyle();
}

export function enable() {
    try {
        _createCrashGuardMarker();
        _enableFeatures();
        _settings.connect('changed::layer-enabled', () => _followLayerEnabled());
    } catch (e) {
        console.error(`Apex: enable failed: ${e}`);
    }
}
