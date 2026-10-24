// SPDX-License-Identifier: GPL-3.0-or-later
//
// gjs -m sni-items.js LOG NAME...: per NAME a StatusNotifierItem and DBusMenu on its own
// connection, as separate apps are; each call it gets is a "<name> <method> <args>" line in LOG.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const WATCHER = 'org.kde.StatusNotifierWatcher';
const WATCHER_PATH = '/StatusNotifierWatcher';
const ITEM_PATH = '/StatusNotifierItem';
const MENU_PATH = '/MenuBar';

// 16 x 16, a red square inside a transparent 3 px border, as ARGB32 in network byte order.
const PIXMAP_SIZE = 16;
const PIXMAP_BORDER = 3;
const PIXMAP = [[PIXMAP_SIZE, PIXMAP_SIZE, Uint8Array.from({length: PIXMAP_SIZE * PIXMAP_SIZE * 4}, (_, i) => {
    const pixel = Math.floor(i / 4);
    const [x, y] = [pixel % PIXMAP_SIZE, Math.floor(pixel / PIXMAP_SIZE)];
    const inside = Math.min(x, y, PIXMAP_SIZE - 1 - x, PIXMAP_SIZE - 1 - y) >= PIXMAP_BORDER;
    return inside ? [0xff, 0xe0, 0x1b, 0x24][i % 4] : 0;
})]];

// Board 39's apps, with icons Adwaita has: Chat names its symbolic icon itself, and the
// password manager sends only a pixmap.
const ITEMS = {
    'File sync': {IconName: 'folder-remote'},
    'Chat': {IconName: 'mail-unread-symbolic', Status: 'NeedsAttention'},
    'Game launcher': {IconName: 'input-gaming'},
    'Password manager': {IconPixmap: PIXMAP},
    'Media player': {IconName: 'audio-x-generic'},
};

const CHAT_MENU = [
    {id: 1, label: 'Show Chat', shortcut: [['Control', 'Shift', 'c']]},
    {id: 2, label: 'Do Not Disturb', 'toggle-type': 'checkmark', 'toggle-state': 0},
    {id: 3, label: 'Start at Login', 'toggle-type': 'checkmark', 'toggle-state': 1},
    {id: 4, type: 'separator'},
    {id: 5, label: 'Mute for 1 Hour'},
    {id: 6, type: 'separator'},
    {id: 7, label: 'Quit Chat'},
];
const MENU = [{id: 1, label: 'Open'}, {id: 2, type: 'separator'}, {id: 3, label: 'Quit'}];

const ITEM_XML = `<node><interface name="org.kde.StatusNotifierItem">
  <property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="IconName" type="s" access="read"/>
  <property name="IconPixmap" type="a(iiay)" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <property name="Menu" type="o" access="read"/>
  <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
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

const SIGNATURES = {label: 's', type: 's', 'toggle-type': 's', 'toggle-state': 'i', shortcut: 'aas'};

const [logPath, ...names] = ARGV;
const log = Gio.File.new_for_path(logPath);

function record(line) {
    const stream = log.append_to(Gio.FileCreateFlags.NONE, null);
    stream.write_all(new TextEncoder().encode(`${line}\n`), null);
    stream.close(null);
}

function layout(rows) {
    const children = rows.map(({id, ...props}) => new GLib.Variant('(ia{sv}av)', [id,
        Object.fromEntries(Object.entries(props).map(([k, v]) => [k, new GLib.Variant(SIGNATURES[k], v)])), []]));
    return [0, {'children-display': new GLib.Variant('s', 'submenu')}, children];
}

function exportItem(name) {
    const conn = Gio.DBusConnection.new_for_address_sync(
        Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, null),
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        null, null);
    const props = {
        Id: name, Title: name, Status: 'Active', IconName: '', IconPixmap: [], ItemIsMenu: false,
        Menu: MENU_PATH, ...ITEMS[name],
    };
    const calls = method => (...args) => record(`${name} ${method} ${args.join(' ')}`);
    Gio.DBusExportedObject.wrapJSObject(ITEM_XML, {
        ...props,
        IconPixmap: new GLib.Variant('a(iiay)', props.IconPixmap),
        Activate: calls('Activate'),
        SecondaryActivate: calls('SecondaryActivate'),
        ContextMenu: calls('ContextMenu'),
        Scroll: calls('Scroll'),
    }).export(conn, ITEM_PATH);
    const rows = name === 'Chat' ? CHAT_MENU : MENU;
    Gio.DBusExportedObject.wrapJSObject(MENU_XML, {
        GetLayoutAsync(_params, invocation) {
            invocation.return_value(new GLib.Variant('(u(ia{sv}av))', [1, layout(rows)]));
        },
        Event: (id, eventId) => record(`${name} Event ${id} ${eventId}`),
        AboutToShow: () => false,
    }).export(conn, MENU_PATH);
    // As libappindicator does: register with every watcher that appears.
    Gio.bus_watch_name_on_connection(conn, WATCHER, Gio.BusNameWatcherFlags.NONE, () => {
        conn.call(WATCHER, WATCHER_PATH, WATCHER, 'RegisterStatusNotifierItem',
            new GLib.Variant('(s)', [ITEM_PATH]), null, Gio.DBusCallFlags.NONE, -1, null,
            (c, res) => {
                try {
                    c.call_finish(res);
                    record(`${name} registered`);
                } catch (e) {
                    record(`${name} register-error ${e.message}`);
                }
            });
    }, null);
    return conn;
}

const connections = names.map(exportItem);
new GLib.MainLoop(null, false).run();
connections.forEach(conn => conn.close_sync(null));
