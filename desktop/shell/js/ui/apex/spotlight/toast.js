// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 38's "Copied" toast: a glass pill above the dock, gone after a moment.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Glass from '../glass/registry.js';
import * as Main from '../../main.js';

const SHOWN_MS = 2000;
const CHECK_GLYPH = 'object-select-symbolic';

let _toast = null;
let _timeoutId = 0;

export function hide() {
    if (_timeoutId)
        GLib.source_remove(_timeoutId);
    _timeoutId = 0;
    _toast?.destroy();
    _toast = null;
}

export function show(text) {
    hide();
    const monitor = Main.layoutManager.primaryMonitor;
    const pill = new St.BoxLayout({
        style_class: 'apex-toast',
        accessible_name: text,
        x_align: Clutter.ActorAlign.CENTER,
        y_align: Clutter.ActorAlign.END,
        x_expand: true,
        y_expand: true,
    });
    pill.add_child(new St.Bin({
        style_class: 'apex-toast-check',
        y_align: Clutter.ActorAlign.CENTER,
        child: new St.Icon({
            icon_name: CHECK_GLYPH,
            style_class: 'apex-toast-check-icon',
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
        }),
    }));
    pill.add_child(new St.Label({text, style_class: 'apex-toast-label', y_align: Clutter.ActorAlign.CENTER}));
    _toast = new St.Widget({
        name: 'apexToast',
        layout_manager: new Clutter.BinLayout(),
        x: monitor.x, y: monitor.y, width: monitor.width, height: monitor.height,
    });
    _toast.add_child(pill);
    Main.uiGroup.add_child(_toast);
    Glass.register(pill, {name: 'toast'});
    _timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, SHOWN_MS, () => {
        _timeoutId = 0;
        hide();
        return GLib.SOURCE_REMOVE;
    });
}

export function current() {
    return _toast;
}
