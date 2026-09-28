// SPDX-License-Identifier: GPL-2.0-or-later
//
// Fault injection for the safety-net tests; layer.js loads it only when
// APEX_SHELL_TEST_FAULT names a phase.

import GLib from 'gi://GLib';

import * as Hooks from '../hooks.js';

// Well inside the crash guard's 60 s, and long enough for the session to come up.
const ABORT_SECONDS = 5;

let _abortId = 0;

function _phase() {
    return GLib.getenv('APEX_SHELL_TEST_FAULT');
}

/**
 * @param {string} name - the feature's name, which owns its hooks
 */
export function configure(name) {
    Hooks.provide(name, 'test-fault', () => 'fault');
    if (_phase() === 'configure')
        throw new Error('injected fault in configure (APEX_SHELL_TEST_FAULT=configure)');
}

export function enable() {
    const phase = _phase();
    if (phase === 'enable')
        throw new Error('injected fault in enable (APEX_SHELL_TEST_FAULT=enable)');
    if (phase !== 'abort-after-enable' || _abortId)
        return;
    console.warn('Apex: APEX_SHELL_TEST_FAULT=abort-after-enable: ' +
        `the shell aborts in ${ABORT_SECONDS} s`);
    _abortId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, ABORT_SECONDS, () => {
        // A message at the error level is fatal: GLib aborts the process with SIGABRT,
        // as a crash in the shell would.
        GLib.log_structured('Apex', GLib.LogLevelFlags.LEVEL_ERROR,
            {MESSAGE: 'Apex: APEX_SHELL_TEST_FAULT=abort-after-enable: aborting the shell'});
        return GLib.SOURCE_REMOVE;
    });
}

export function disable() {
    if (_abortId) {
        GLib.source_remove(_abortId);
        _abortId = 0;
    }
}
