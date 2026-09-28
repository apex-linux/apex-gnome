// SPDX-License-Identifier: GPL-2.0-or-later
//
// The Apex layer (ADR 0014). main.js loads it through hooks.loadLayer(), which runs
// configure() before the session mode exists, and calls enable() at startup-prepared.
// It is never loaded in safe mode or in the gdm mode. Each feature is its own module,
// ui/apex/<name>/feature.js, in its own try/catch: one that throws is off for the
// session and its hooks give stock values, while the rest of the layer runs.

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

import * as Hooks from './hooks.js';

// The features, in enable order. Their names are those of the disabled-features key
// (design/SPEC.md 6.2). S1a ships the empty layer; S2a adds 'panel' and 'dock'. A
// feature module exports configure(name), which may be async, and enable() and
// disable(), which are synchronous.
const FEATURES = [];

// Fault injection for the safety net's tests: when APEX_SHELL_TEST_FAULT names one of
// these phases, the 'fault' feature (fault/feature.js) is enabled last and fails in that
// phase. Any other value injects nothing. The image never sets the variable (G1).
const FAULT_PHASES = ['configure', 'enable', 'abort-after-enable'];

// GNOME's 'default' colour scheme draws a light shell in these modes (ADR 0014;
// design/SPEC.md 6.2). Upstream sets 'prefer-dark' for every mode; the gdm mode keeps
// it.
const LIGHT_MODES = new Set(['user', 'unlock-dialog']);

// The crash guard's marker (ADR 0014): it exists from enable() until the shell has run
// for this long, or until shutdown, as extensionSystem.js does with its own file.
const STARTING_FILE = 'apex-shell-starting';
const STARTING_SECONDS = 60;

const _features = [];

function _sessionMode(params, mode) {
    return LIGHT_MODES.has(mode) ? {...params, colorScheme: 'prefer-light'} : params;
}

// FEATURES, plus 'fault' when APEX_SHELL_TEST_FAULT names a phase.
function _featureNames() {
    const fault = GLib.getenv('APEX_SHELL_TEST_FAULT');
    if (fault === null)
        return FEATURES;
    if (!FAULT_PHASES.includes(fault)) {
        console.warn(`Apex: APEX_SHELL_TEST_FAULT=${fault} names no phase ` +
            `(${FAULT_PHASES.join(', ')}); no fault injected`);
        return FEATURES;
    }
    console.warn(`Apex: APEX_SHELL_TEST_FAULT=${fault}: the fault feature fails in that phase`);
    return [...FEATURES, 'fault'];
}

/**
 * The configure phase: value providers only, before the UI exists.
 *
 * @param {Gio.Settings} settings - io.github.sekirokenjii.Apex.Desktop
 */
export async function configure(settings) {
    Hooks.provide('core', 'session-mode', _sessionMode);

    const disabled = new Set(settings.get_strv('disabled-features'));
    for (const name of _featureNames()) {
        if (disabled.has(name)) {
            console.log(`Apex: feature ${name} is in disabled-features`);
            continue;
        }
        try {
            // eslint-disable-next-line no-await-in-loop
            const feature = await import(`./${name}/feature.js`);
            // Awaited, so that an async configure that rejects lands in this catch too.
            // eslint-disable-next-line no-await-in-loop
            await feature.configure?.(name);
            _features.push({name, feature});
        } catch (e) {
            Hooks.withdraw(name);
            console.error(`Apex: feature ${name} off for this session (configure: ${e})`);
        }
    }
}

function _markStarting() {
    const file = Gio.File.new_for_path(
        GLib.build_filenamev([GLib.get_user_runtime_dir(), STARTING_FILE]));
    try {
        // Not empty: an empty array reaches g_file_replace_contents as NULL, which it
        // refuses without an exception.
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
    GLib.timeout_add_seconds_once(GLib.PRIORITY_DEFAULT, STARTING_SECONDS, () => {
        global.disconnect(shutdownId);
        remove();
    });
}

/**
 * The enable phase, at startup-prepared: features build their actors. It never throws.
 */
export function enable() {
    try {
        _markStarting();
        for (const {name, feature} of _features) {
            try {
                feature.enable?.();
                console.log(`Apex: feature ${name} enabled`);
            } catch (e) {
                Hooks.withdraw(name);
                console.error(`Apex: feature ${name} off for this session (enable: ${e})`);
                try {
                    feature.disable?.();
                } catch {}
            }
        }
    } catch (e) {
        console.error(`Apex: enable failed: ${e}`);
    }
}
