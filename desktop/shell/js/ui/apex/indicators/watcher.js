// SPDX-License-Identifier: GPL-2.0-or-later
//
// The StatusNotifierItem watcher and host: the shell owns org.kde.StatusNotifierWatcher
// while nobody else does, and otherwise registers as a host with the watcher that does.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const WATCHER_NAME = 'org.kde.StatusNotifierWatcher';
const WATCHER_PATH = '/StatusNotifierWatcher';
const WATCHER_INTERFACE = 'org.kde.StatusNotifierWatcher';
const ITEM_PATH = '/StatusNotifierItem';
const PROTOCOL_VERSION = 0;

Gio._promisify(Gio.DBusConnection.prototype, 'call');

const WATCHER_XML = `<node>
  <interface name="${WATCHER_INTERFACE}">
    <method name="RegisterStatusNotifierItem"><arg type="s" direction="in" name="service"/></method>
    <method name="RegisterStatusNotifierHost"><arg type="s" direction="in" name="service"/></method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    <signal name="StatusNotifierHostRegistered"/>
    <signal name="StatusNotifierHostUnregistered"/>
  </interface>
</node>`;

// An item registers its bus name, or only its object path; a watcher lists it as
// "<bus name><path>", and a bare name means the spec's default path.
export function parseItemId(id) {
    const slash = id.indexOf('/');
    return slash < 0 ? {busName: id, path: ITEM_PATH} : {busName: id.slice(0, slash), path: id.slice(slash)};
}

export class Host {
    constructor(bus, {added, removed}) {
        this._bus = bus;
        this._added = added;
        this._removed = removed;
        this._items = new Map();
        this._owning = false;
        this._remoteSignals = [];
        this.hostName = `org.kde.StatusNotifierHost-apex-${new Gio.Credentials().get_unix_pid()}`;

        this._exported = Gio.DBusExportedObject.wrapJSObject(WATCHER_XML, this);
        this._exported.export(bus, WATCHER_PATH);
        this._hostNameId = Gio.bus_own_name_on_connection(bus, this.hostName,
            Gio.BusNameOwnerFlags.NONE, null, null);
        // Queued: a watcher that leaves hands the name to the shell.
        this._watcherNameId = Gio.bus_own_name_on_connection(bus, WATCHER_NAME,
            Gio.BusNameOwnerFlags.NONE, () => this._ownWatcher(), () => this._useRemoteWatcher());
    }

    get owningWatcher() {
        return this._owning;
    }

    get itemIds() {
        return [...this._items.keys()];
    }

    _add(id, busName, path) {
        if (this._items.has(id))
            return false;
        const entry = {busName, path, watchId: 0};
        this._items.set(id, entry);
        if (this._owning) {
            entry.watchId = Gio.bus_watch_name_on_connection(this._bus, busName,
                Gio.BusNameWatcherFlags.NONE, null, () => this._remove(id));
        }
        this._added(id, busName, path);
        return true;
    }

    _remove(id) {
        const entry = this._items.get(id);
        if (!entry)
            return;
        this._items.delete(id);
        if (entry.watchId)
            Gio.bus_unwatch_name(entry.watchId);
        this._removed(id);
        if (this._owning) {
            this._exported.emit_signal('StatusNotifierItemUnregistered', new GLib.Variant('(s)', [id]));
            this._itemsChanged();
        }
    }

    _clear() {
        for (const id of [...this._items.keys()])
            this._remove(id);
    }

    _ownWatcher() {
        this._dropRemoteWatcher();
        this._clear();
        this._owning = true;
        this._exported.emit_signal('StatusNotifierHostRegistered', null);
    }

    _useRemoteWatcher() {
        const wasOwning = this._owning;
        this._owning = false;
        if (wasOwning)
            this._clear();
        this._dropRemoteWatcher();
        const subscribe = (member, fn) => this._remoteSignals.push(this._bus.signal_subscribe(
            WATCHER_NAME, WATCHER_INTERFACE, member, WATCHER_PATH, null, Gio.DBusSignalFlags.NONE,
            (_bus, _sender, _path, _iface, _member, params) => fn(params.deepUnpack()[0])));
        subscribe('StatusNotifierItemRegistered', id => this._addRemote(id));
        subscribe('StatusNotifierItemUnregistered', id => this._remove(id));
        this._bus.call(WATCHER_NAME, WATCHER_PATH, WATCHER_INTERFACE, 'RegisterStatusNotifierHost',
            new GLib.Variant('(s)', [this.hostName]), null, Gio.DBusCallFlags.NONE, -1, null)
            .catch(e => console.warn(`Apex: the StatusNotifierWatcher refused the host: ${e.message}`));
        this._bus.call(WATCHER_NAME, WATCHER_PATH, 'org.freedesktop.DBus.Properties', 'Get',
            new GLib.Variant('(ss)', [WATCHER_INTERFACE, 'RegisteredStatusNotifierItems']),
            null, Gio.DBusCallFlags.NONE, -1, null)
            .then(reply => {
                if (!this._owning)
                    reply.deepUnpack()[0].deepUnpack().forEach(id => this._addRemote(id));
            })
            .catch(e => console.warn(`Apex: cannot list the StatusNotifierWatcher's items: ${e.message}`));
    }

    _addRemote(id) {
        const {busName, path} = parseItemId(id);
        this._add(id, busName, path);
    }

    _dropRemoteWatcher() {
        this._remoteSignals.forEach(id => this._bus.signal_unsubscribe(id));
        this._remoteSignals = [];
    }

    _itemsChanged() {
        this._exported.emit_property_changed('RegisteredStatusNotifierItems',
            new GLib.Variant('as', this.RegisteredStatusNotifierItems));
    }

    // org.kde.StatusNotifierWatcher, while the shell owns it.
    RegisterStatusNotifierItemAsync([service], invocation) {
        const sender = invocation.get_sender();
        const busName = service.startsWith('/') ? sender : service;
        const path = service.startsWith('/') ? service : ITEM_PATH;
        const id = `${busName}${path}`;
        if (this._owning && this._add(id, busName, path)) {
            this._exported.emit_signal('StatusNotifierItemRegistered', new GLib.Variant('(s)', [id]));
            this._itemsChanged();
        }
        invocation.return_value(null);
    }

    RegisterStatusNotifierHostAsync(_params, invocation) {
        this._exported.emit_signal('StatusNotifierHostRegistered', null);
        invocation.return_value(null);
    }

    get RegisteredStatusNotifierItems() {
        return this._owning ? this.itemIds : [];
    }

    get IsStatusNotifierHostRegistered() {
        return true;
    }

    get ProtocolVersion() {
        return PROTOCOL_VERSION;
    }

    destroy() {
        this._dropRemoteWatcher();
        const owning = this._owning;
        this._owning = false;
        for (const [id, entry] of this._items) {
            if (entry.watchId)
                Gio.bus_unwatch_name(entry.watchId);
            this._removed(id);
        }
        this._items.clear();
        if (owning)
            this._exported.emit_signal('StatusNotifierHostUnregistered', null);
        Gio.bus_unown_name(this._watcherNameId);
        Gio.bus_unown_name(this._hostNameId);
        this._exported.unexport();
    }
}
