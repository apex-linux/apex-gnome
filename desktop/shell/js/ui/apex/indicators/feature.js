// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's app indicators (owner, 2026-10-24): a StatusNotifierItem host with DBusMenu
// menus in the top bar. There is no XEmbed tray.

import Gio from 'gi://Gio';

import {Bar} from './bar.js';
import {Indicator} from './indicator.js';
import {Host} from './watcher.js';

let _bar = null;
let _host = null;

export function configure() {}

export function enable() {
    const bus = Gio.DBus.session;
    _bar = new Bar();
    _host = new Host(bus, {
        added: (id, busName, path) => _bar.add(new Indicator(bus, id, busName, path)),
        removed: id => _bar.remove(id),
    });
}

export function disable() {
    _host?.destroy();
    _host = null;
    _bar?.destroy();
    _bar = null;
}
