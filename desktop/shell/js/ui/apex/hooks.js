// SPDX-License-Identifier: GPL-2.0-or-later
//
// Upstream files import this module statically: it imports only GLib and Gio, does
// nothing at load and never throws.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const SCHEMA_ID = 'io.github.apex_linux.Apex.Desktop';
const KERNEL_SWITCH = 'apex.safe=1';
const GREETER_MODE = 'gdm';
const RUN_STOCK_CODE = undefined;

const _providerByHook = new Map();
let _safe = null;
let _settings = null;

function _kernelSafe() {
    const [, bytes] = GLib.file_get_contents('/proc/cmdline');
    return new TextDecoder().decode(bytes).trim().split(/\s+/).includes(KERNEL_SWITCH);
}

// The greeter ignores layer-enabled, so one user turning the layer off keeps the Apex
// CSS there.
function _safeReason() {
    if (GLib.getenv('APEX_SHELL_SAFE') === '1')
        return 'APEX_SHELL_SAFE=1';
    if (_kernelSafe())
        return KERNEL_SWITCH;
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(SCHEMA_ID, true);
    if (!schema)
        return `schema ${SCHEMA_ID} is not installed`;
    _settings = new Gio.Settings({settings_schema: schema});
    if (global.session_mode !== GREETER_MODE && !_settings.get_boolean('layer-enabled'))
        return 'layer-enabled is false';
    return '';
}

// A shell that started stock stays stock until the next login, so the crash guard's switch holds.
function _turnedOff() {
    return global.session_mode !== GREETER_MODE && !_settings.get_boolean('layer-enabled');
}

/**
 * @returns {boolean} whether the shell runs stock
 */
export function safe() {
    if (_safe === null) {
        let reason;
        try {
            reason = _safeReason();
        } catch (e) {
            reason = `the safe-mode check failed: ${e.message}`;
        }
        _safe = reason !== '';
        if (_safe)
            console.warn(`Apex: safe mode (${reason})`);
    }
    try {
        return _safe || _turnedOff();
    } catch {
        return true;
    }
}

function _drop(name, e) {
    _providerByHook.delete(name);
    console.error(`Apex: hook ${name} threw; stock for the rest of the session: ${e}`);
}

/**
 * @param {string} name
 * @param {*} stock
 * @param {...*} args
 * @returns {*} the provider's value, or stock
 */
export function value(name, stock, ...args) {
    const provider = _providerByHook.get(name);
    if (!provider || safe())
        return stock;
    try {
        return provider.fn(stock, ...args);
    } catch (e) {
        _drop(name, e);
        return stock;
    }
}

/**
 * @param {string} name
 * @param {...*} args
 * @returns {*} the provider's result, or undefined for the stock code
 */
export function run(name, ...args) {
    const provider = _providerByHook.get(name);
    if (!provider || safe())
        return RUN_STOCK_CODE;
    try {
        return provider.fn(...args);
    } catch (e) {
        _drop(name, e);
        return RUN_STOCK_CODE;
    }
}

/**
 * @param {string} owner
 * @param {string} name
 * @param {Function} fn
 */
export function provide(owner, name, fn) {
    if (!safe())
        _providerByHook.set(name, {owner, fn});
}

/**
 * @param {string} owner
 */
export function withdraw(owner) {
    for (const [name, provider] of _providerByHook) {
        if (provider.owner === owner)
            _providerByHook.delete(name);
    }
}

/**
 * Never rejects, because init.js would end the shell. importLayer comes from main.js so
 * that its import() specifier resolves next to main.js.
 *
 * @param {() => Promise<object>} importLayer
 * @returns {Promise<object|null>} the configured layer, or null
 */
export async function loadLayer(importLayer) {
    try {
        if (global.session_mode === GREETER_MODE || safe())
            return null;
        const layer = await importLayer();
        await layer.configure(_settings);
        return layer;
    } catch (e) {
        _providerByHook.clear();
        console.error(`Apex: the layer did not load; stock shell for this session: ${e}`);
        return null;
    }
}
