// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fake StatusNotifierItems with DBusMenu menus, and a fake watcher, each on its own
// connection to the probe's session bus, as separate apps would be.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const fact = (key, value) => printerr(`probe: ${key}=${value}`);

const WATCHER = 'org.kde.StatusNotifierWatcher';
const WATCHER_PATH = '/StatusNotifierWatcher';
const ITEM_PATH = '/StatusNotifierItem';
const MENU_PATH = '/MenuBar';

const ITEM_XML = `<node><interface name="org.kde.StatusNotifierItem">
  <property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="IconName" type="s" access="read"/>
  <property name="IconPixmap" type="a(iiay)" access="read"/>
  <property name="AttentionIconName" type="s" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <property name="Menu" type="o" access="read"/>
  <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
  <signal name="NewStatus"><arg type="s"/></signal>
  <signal name="NewIcon"/>
  <signal name="NewTitle"/>
</interface></node>`;

const MENU_XML = `<node><interface name="com.canonical.dbusmenu">
  <method name="GetLayout">
    <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
    <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/>
  </method>
  <method name="Event">
    <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/>
  </method>
  <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
  <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
  <signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
</interface></node>`;

const WATCHER_XML = `<node><interface name="${WATCHER}">
  <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
  <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
  <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
  <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
  <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
</interface></node>`;

export function connect() {
    return Gio.DBusConnection.new_for_address_sync(GLib.getenv('DBUS_SESSION_BUS_ADDRESS'),
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        null, null);
}

function variantProps(props) {
    const signatures = {
        label: 's', type: 's', 'toggle-type': 's', 'toggle-state': 'i',
        enabled: 'b', visible: 'b', 'children-display': 's', shortcut: 'aas',
    };
    return Object.fromEntries(Object.entries(props).map(([key, value]) =>
        [key, new GLib.Variant(signatures[key], value)]));
}

function layout(node) {
    return [node.id, variantProps(node.props),
        (node.children ?? []).map(child => new GLib.Variant('(ia{sv}av)', layout(child)))];
}

// One app's item. props are the item's; menu is a tree of {id, props, children}. A real
// item registers again whenever a watcher appears, as libappindicator does.
export class FakeItem {
    constructor(name, props, menu = null, {byName = false} = {}) {
        this.name = name;
        this.conn = connect();
        this.props = {
            Id: name, Title: name, Status: 'Active', IconName: '', IconPixmap: [],
            AttentionIconName: '', ItemIsMenu: false, Menu: menu ? MENU_PATH : '/', ...props,
        };
        this.menu = menu;
        this._item = Gio.DBusExportedObject.wrapJSObject(ITEM_XML, this._itemImplementation());
        this._item.export(this.conn, ITEM_PATH);
        if (menu) {
            this._menu = Gio.DBusExportedObject.wrapJSObject(MENU_XML, this._menuImplementation());
            this._menu.export(this.conn, MENU_PATH);
        }
        this.service = byName ? `org.kde.StatusNotifierItem-${name.replace(/\W/g, '')}-1` : ITEM_PATH;
        const watch = () => {
            this._watchId = Gio.bus_watch_name_on_connection(this.conn, WATCHER,
                Gio.BusNameWatcherFlags.NONE, () => this._register(), null);
        };
        if (byName)
            Gio.bus_own_name_on_connection(this.conn, this.service, Gio.BusNameOwnerFlags.NONE, watch, null);
        else
            watch();
    }

    _register() {
        this.conn.call(WATCHER, WATCHER_PATH, WATCHER, 'RegisterStatusNotifierItem',
            new GLib.Variant('(s)', [this.service]), null, Gio.DBusCallFlags.NONE, -1, null, (conn, res) => {
                try {
                    conn.call_finish(res);
                } catch (e) {
                    fact(`sni.${this.name}.register-error`, e.message);
                }
            });
    }

    _itemImplementation() {
        const item = this;
        const record = method => ([a, b]) => fact(`sni.${item.name}.${method}`, `${a} ${b}`);
        return {
            get Id() {
                return item.props.Id;
            },
            get Title() {
                return item.props.Title;
            },
            get Status() {
                return item.props.Status;
            },
            get IconName() {
                return item.props.IconName;
            },
            get IconPixmap() {
                return new GLib.Variant('a(iiay)', item.props.IconPixmap);
            },
            get AttentionIconName() {
                return item.props.AttentionIconName;
            },
            get ItemIsMenu() {
                return item.props.ItemIsMenu;
            },
            get Menu() {
                return item.props.Menu;
            },
            Activate: (x, y) => record('Activate')([x, y]),
            SecondaryActivate: (x, y) => record('SecondaryActivate')([x, y]),
            ContextMenu: (x, y) => record('ContextMenu')([x, y]),
            Scroll: (delta, orientation) => record('Scroll')([delta, orientation]),
        };
    }

    _menuImplementation() {
        const item = this;
        return {
            GetLayoutAsync(_params, invocation) {
                invocation.return_value(new GLib.Variant('(u(ia{sv}av))', [1, layout(item.menu)]));
            },
            Event: (id, eventId) => fact(`menu.${item.name}.event`, `${id} ${eventId}`),
            AboutToShow: () => false,
        };
    }

    set(props) {
        Object.assign(this.props, props);
        if ('Status' in props)
            this._item.emit_signal('NewStatus', new GLib.Variant('(s)', [props.Status]));
        if ('IconName' in props || 'IconPixmap' in props)
            this._item.emit_signal('NewIcon', null);
        if ('Title' in props)
            this._item.emit_signal('NewTitle', null);
    }

    // As ItemsPropertiesUpdated sends them: [[id, {key: value}]].
    updateMenuProperties(updates) {
        for (const [id, props] of updates) {
            const find = node => node.id === id ? node : (node.children ?? []).map(find).find(Boolean);
            Object.assign(find(this.menu).props, props);
        }
        this._menu.emit_signal('ItemsPropertiesUpdated', new GLib.Variant('(a(ia{sv})a(ias))',
            [updates.map(([id, props]) => [id, variantProps(props)]), []]));
    }

    quit() {
        if (this._watchId)
            Gio.bus_unwatch_name(this._watchId);
        this.conn.close_sync(null);
    }
}

// Another process's watcher, owning the name before the shell asks for it.
export class FakeWatcher {
    constructor(items) {
        this.conn = connect();
        this.items = items;
        const watcher = this;
        this._exported = Gio.DBusExportedObject.wrapJSObject(WATCHER_XML, {
            RegisterStatusNotifierItem: service => fact('fake-watcher.item', service),
            RegisterStatusNotifierHost: service => fact('fake-watcher.host', service),
            get RegisteredStatusNotifierItems() {
                return watcher.items;
            },
        });
        this._exported.export(this.conn, WATCHER_PATH);
        this.owned = new Promise(resolve => Gio.bus_own_name_on_connection(this.conn, WATCHER,
            Gio.BusNameOwnerFlags.NONE, () => resolve(true), () => resolve(false)));
    }

    announce(id) {
        this.items.push(id);
        this._exported.emit_signal('StatusNotifierItemRegistered', new GLib.Variant('(s)', [id]));
    }

    quit() {
        this.conn.close_sync(null);
    }
}

export function watcherOwner(conn) {
    try {
        const reply = conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
            'GetNameOwner', new GLib.Variant('(s)', [WATCHER]), null, Gio.DBusCallFlags.NONE, -1, null);
        return reply.deepUnpack()[0];
    } catch {
        return 'none';
    }
}
