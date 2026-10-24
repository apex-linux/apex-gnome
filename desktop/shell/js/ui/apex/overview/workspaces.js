// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the overview's windows sit on its scrim, with no wallpaper card behind them, and a
// workspace without windows says so. Like window titles, a change shows from the next opening.

import Clutter from 'gi://Clutter';
import St from 'gi://St';

import * as Hooks from '../hooks.js';

const EMPTY_STYLE_CLASS = 'apex-workspace-empty';
const EMPTY_TEXT = 'No open windows';

let _enabled = false;

function _restyle(workspace, layoutManager) {
    if (!_enabled)
        return;
    workspace._background.hide();
    const label = new St.Label({
        style_class: EMPTY_STYLE_CLASS,
        text: EMPTY_TEXT,
        x_align: Clutter.ActorAlign.CENTER,
        y_align: Clutter.ActorAlign.CENTER,
    });
    workspace.add_child(label);
    const windows = workspace._container;
    const syncVisible = () => (label.visible = windows.get_n_children() === 0);
    windows.connectObject('child-added', syncVisible, 'child-removed', syncVisible, label);
    syncVisible();
    const {stateAdjustment} = layoutManager;
    const syncOpacity = () => (label.opacity = Math.round(stateAdjustment.value * 255));
    stateAdjustment.connectObject('notify::value', syncOpacity, label);
    syncOpacity();
}

export function configure(featureName) {
    Hooks.provide(featureName, 'workspace', _restyle);
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
