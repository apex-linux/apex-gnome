// SPDX-License-Identifier: GPL-2.0-or-later
//
// The only Apex module that upstream files import (ADR 0014; patch 0002-loader). It
// imports GLib and Gio only, does nothing at load, and never throws. A hook with no
// provider, or whose provider threw, gives the stock value. Safe mode, where no
// provider is ever registered and the stylesheets come from theme/stock/, is decided
// once per process.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const SCHEMA_ID = 'io.github.sekirokenjii.Apex.Desktop';
const KERNEL_SWITCH = 'apex.safe=1';

const _providers = new Map(); // hook name -> {owner, fn}
let _safe = null;
let _settings = null;

function _kernelSafe() {
    const [, bytes] = GLib.file_get_contents('/proc/cmdline');
    return new TextDecoder().decode(bytes).trim().split(/\s+/).includes(KERNEL_SWITCH);
}

// The reason for safe mode, or '' when the layer may run. The greeter (the gdm mode)
// ignores layer-enabled: one user turning the layer off keeps the Apex CSS there.
function _safeReason() {
    if (GLib.getenv('APEX_SHELL_SAFE') === '1')
        return 'APEX_SHELL_SAFE=1';
    if (_kernelSafe())
        return KERNEL_SWITCH;
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(SCHEMA_ID, true);
    if (!schema)
        return `schema ${SCHEMA_ID} is not installed`;
    _settings = new Gio.Settings({settings_schema: schema});
    if (global.session_mode !== 'gdm' && !_settings.get_boolean('layer-enabled'))
        return 'layer-enabled is false';
    return '';
}

/**
 * Safe mode: no layer, every hook stock, upstream's stylesheets. Decided once per
 * process, from APEX_SHELL_SAFE=1, apex.safe=1 on the kernel command line, a missing
 * Apex schema, or layer-enabled=false.
 *
 * @returns {boolean}
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
    return _safe;
}

function _drop(name, e) {
    _providers.delete(name);
    console.error(`Apex: hook ${name} threw; stock for the rest of the session: ${e}`);
}

/**
 * A value hook: the provider's value, or the stock value.
 *
 * @param {string} name - the hook
 * @param {*} stock - upstream's value
 * @param {...*} args - context for the provider
 * @returns {*}
 */
export function value(name, stock, ...args) {
    const p = _providers.get(name);
    if (!p)
        return stock;
    try {
        return p.fn(stock, ...args);
    } catch (e) {
        _drop(name, e);
        return stock;
    }
}

/**
 * A behaviour hook: the provider's result, or undefined when the caller runs its
 * stock code.
 *
 * @param {string} name - the hook
 * @param {...*} args - context for the provider
 * @returns {*}
 */
export function run(name, ...args) {
    const p = _providers.get(name);
    if (!p)
        return undefined;
    try {
        return p.fn(...args);
    } catch (e) {
        _drop(name, e);
        return undefined;
    }
}

/**
 * Registers a provider (the layer only). Nothing is registered in safe mode.
 *
 * @param {string} owner - the feature, or 'core'
 * @param {string} name - the hook
 * @param {Function} fn - the provider
 */
export function provide(owner, name, fn) {
    if (!safe())
        _providers.set(name, {owner, fn});
}

/**
 * Removes every provider of one owner (the layer only): its hooks give stock values.
 *
 * @param {string} owner - the feature, or 'core'
 */
export function withdraw(owner) {
    for (const [name, p] of _providers) {
        if (p.owner === owner)
            _providers.delete(name);
    }
}

/**
 * Loads the layer and runs its configure phase, before the session mode exists. It
 * never rejects: init.js would end the shell. It resolves to the layer, or to null in
 * the gdm mode (no Apex JS runs in the greeter), in safe mode, or when loading or
 * configuring threw.
 *
 * @param {Function} importLayer - `() => import('./apex/layer.js')`, from main.js, so
 *   that the specifier resolves next to main.js
 * @returns {Promise<?object>}
 */
export async function loadLayer(importLayer) {
    try {
        if (global.session_mode === 'gdm' || safe())
            return null;
        const layer = await importLayer();
        await layer.configure(_settings);
        return layer;
    } catch (e) {
        _providers.clear();
        console.error(`Apex: the layer did not load; stock shell for this session: ${e}`);
        return null;
    }
}
