// SPDX-License-Identifier: GPL-2.0-or-later
//
// The user's initial in place of the generic avatar icon, wherever the shell shows an
// avatar without a picture: the lock screen, the user menu, the authentication dialog.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Hooks from '../hooks.js';

const INITIAL_SIZE_FRACTION = 0.39;

let _enabled = false;

export function initialOf(realName, userName) {
    for (const name of [realName, userName]) {
        const first = [...(name ?? '').trim()][0];
        if (first)
            return first.toLocaleUpperCase();
    }
    return null;
}

function _fallback(stockIcon, user, iconSize) {
    if (!_enabled)
        return stockIcon;
    const initial = initialOf(user?.get_real_name?.(), user?.get_user_name?.() ?? GLib.get_user_name());
    if (!initial)
        return stockIcon;
    stockIcon.destroy();
    return new St.Label({
        style_class: 'apex-avatar-initial',
        style: `font-size: ${Math.round(iconSize * INITIAL_SIZE_FRACTION)}px;`,
        text: initial,
        x_expand: true,
        y_expand: true,
        x_align: Clutter.ActorAlign.CENTER,
        y_align: Clutter.ActorAlign.CENTER,
    });
}

export function configure(featureName) {
    Hooks.provide(featureName, 'avatar-fallback', _fallback);
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
