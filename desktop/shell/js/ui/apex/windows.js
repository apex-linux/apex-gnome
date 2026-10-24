// SPDX-License-Identifier: GPL-2.0-or-later
//
// "A window on the primary monitor is maximised": the solid bar and the dock's intellihide.

import Meta from 'gi://Meta';

import * as Main from '../main.js';

export function maximisedOnPrimary() {
    return global.workspace_manager.get_active_workspace().list_windows().some(w =>
        w.is_on_primary_monitor() && w.showing_on_its_workspace() && w.is_maximized() &&
        w.get_window_type() !== Meta.WindowType.DESKTOP);
}

// The changes that can make maximisedOnPrimary() or the overview change; disconnect with
// disconnectAll().
export function connectWindowChanges(fn) {
    return [
        [global.display, 'restacked'],
        [global.window_manager, 'size-changed'],
        [global.window_manager, 'minimize'],
        [global.window_manager, 'unminimize'],
        [global.workspace_manager, 'active-workspace-changed'],
        [Main.overview, 'showing'],
        [Main.overview, 'hidden'],
    ].map(([emitter, signal]) => [emitter, emitter.connect(signal, fn)]);
}

export function disconnectAll(connections) {
    for (const [emitter, id] of connections)
        emitter.disconnect(id);
}
