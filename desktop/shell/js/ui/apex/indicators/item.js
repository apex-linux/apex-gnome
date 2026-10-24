// SPDX-License-Identifier: GPL-2.0-or-later
//
// One StatusNotifierItem: the properties a bar button shows, re-read on the item's New*
// signals (the protocol has no PropertiesChanged), and the calls a click makes.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const ITEM_INTERFACE = 'org.kde.StatusNotifierItem';
const CHANGE_SIGNALS = ['NewTitle', 'NewIcon', 'NewAttentionIcon', 'NewOverlayIcon',
    'NewToolTip', 'NewStatus', 'NewIconThemePath', 'NewMenu'];
const REFRESH_DELAY_MS = 50;

Gio._promisify(Gio.DBusConnection.prototype, 'call');

const DEFAULTS = {
    Id: '', Title: '', Status: 'Active', IconName: '', IconPixmap: [], AttentionIconName: '',
    AttentionIconPixmap: [], IconThemePath: '', ToolTip: null, ItemIsMenu: false, Menu: '',
};

export class Item {
    constructor(bus, busName, path, onChange) {
        this._bus = bus;
        this.busName = busName;
        this.path = path;
        this._onChange = onChange;
        this._refreshId = 0;
        this._cancellable = new Gio.Cancellable();
        this.props = {...DEFAULTS};
        this._signalId = bus.signal_subscribe(busName, ITEM_INTERFACE, null, path, null,
            Gio.DBusSignalFlags.NONE, (_bus, _sender, _path, _iface, member) => {
                if (CHANGE_SIGNALS.includes(member))
                    this._queueRefresh();
            });
        this.ready = this._refresh();
    }

    get title() {
        return this.props.Title || this.props.Id || this.busName;
    }

    _queueRefresh() {
        if (this._refreshId)
            return;
        this._refreshId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, REFRESH_DELAY_MS, () => {
            this._refreshId = 0;
            this._refresh();
            return GLib.SOURCE_REMOVE;
        });
    }

    async _refresh() {
        try {
            const reply = await this._bus.call(this.busName, this.path, 'org.freedesktop.DBus.Properties',
                'GetAll', new GLib.Variant('(s)', [ITEM_INTERFACE]), null, Gio.DBusCallFlags.NONE, -1,
                this._cancellable);
            const [props] = reply.deepUnpack();
            const read = {};
            for (const [key, value] of Object.entries(props))
                read[key] = value.recursiveUnpack();
            this.props = {...DEFAULTS, ...read};
            this._onChange(this);
        } catch (e) {
            if (!e.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                console.warn(`Apex: cannot read the indicator ${this.busName}${this.path}: ${e.message}`);
        }
    }

    async _call(method, params) {
        try {
            await this._bus.call(this.busName, this.path, ITEM_INTERFACE, method, params, null,
                Gio.DBusCallFlags.NONE, -1, this._cancellable);
        } catch (e) {
            if (!e.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                console.warn(`Apex: the indicator ${this.title} refused ${method}: ${e.message}`);
        }
    }

    activate(x, y) {
        this._call('Activate', new GLib.Variant('(ii)', [x, y]));
    }

    secondaryActivate(x, y) {
        this._call('SecondaryActivate', new GLib.Variant('(ii)', [x, y]));
    }

    contextMenu(x, y) {
        this._call('ContextMenu', new GLib.Variant('(ii)', [x, y]));
    }

    scroll(delta, orientation) {
        this._call('Scroll', new GLib.Variant('(is)', [delta, orientation]));
    }

    destroy() {
        this._cancellable.cancel();
        this._bus.signal_unsubscribe(this._signalId);
        if (this._refreshId)
            GLib.source_remove(this._refreshId);
        this._refreshId = 0;
    }
}
