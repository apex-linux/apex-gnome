// SPDX-License-Identifier: GPL-2.0-or-later
//
// An item's com.canonical.dbusmenu menu as an Apex popup menu: the item's title as its
// header, separators, toggles as switches, radio items, dimmed shortcuts and submenus.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as PopupMenu from '../../popupMenu.js';

Gio._promisify(Gio.DBusConnection.prototype, 'call');

const MENU_INTERFACE = 'com.canonical.dbusmenu';
const ROOT_ID = 0;
const RELOAD_DELAY_MS = 50;
const IN_PLACE_PROPERTIES = new Set(['label', 'enabled', 'visible', 'toggle-state']);
const MODIFIER_NAMES = {Control: 'Ctrl', Super: 'Super', Shift: 'Shift', Alt: 'Alt'};

// "_File" shows "File"; "__" is a literal underscore.
export function menuLabel(label) {
    return (label ?? '').replace(/_(_?)/g, (_match, literal) => literal);
}

export function shortcutText(shortcut) {
    return (shortcut ?? []).map(keys => keys.map(key =>
        MODIFIER_NAMES[key] ?? (key.length === 1 ? key.toUpperCase() : key)).join('+')).join(', ');
}

function _node([id, props, children]) {
    const read = {};
    for (const [key, value] of Object.entries(props))
        read[key] = value.recursiveUnpack();
    return {id, props: read, children: children.map(child => _node(child.deepUnpack()))};
}

export class MenuClient {
    constructor(bus, busName, path, onChange) {
        this._bus = bus;
        this._busName = busName;
        this._path = path;
        this._onChange = onChange;
        this._cancellable = new Gio.Cancellable();
        this._reloadId = 0;
        this.root = {id: ROOT_ID, props: {}, children: []};
        this._nodes = new Map();
        this._signals = [
            this._subscribe('LayoutUpdated', () => this._queueReload()),
            this._subscribe('ItemsPropertiesUpdated', params => this._propertiesUpdated(params)),
        ];
        this.ready = this.reload();
    }

    get path() {
        return this._path;
    }

    _subscribe(member, fn) {
        return this._bus.signal_subscribe(this._busName, MENU_INTERFACE, member, this._path, null,
            Gio.DBusSignalFlags.NONE, (_bus, _sender, _path, _iface, _member, params) => fn(params));
    }

    _callAsync(method, params, replyType = null) {
        return this._bus.call(this._busName, this._path, MENU_INTERFACE, method, params,
            replyType ? new GLib.VariantType(replyType) : null, Gio.DBusCallFlags.NONE, -1, this._cancellable);
    }

    _warn(what, e) {
        if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
            console.warn(`Apex: indicator menu ${this._busName}${this._path}: ${what}: ${e.message}`);
    }

    async reload() {
        try {
            const reply = await this._callAsync('GetLayout',
                new GLib.Variant('(iias)', [ROOT_ID, -1, []]), '(u(ia{sv}av))');
            const [, layout] = reply.deepUnpack();
            this.root = _node(layout);
            this._nodes = new Map();
            const index = node => {
                this._nodes.set(node.id, node);
                node.children.forEach(index);
            };
            index(this.root);
            this._onChange(null);
        } catch (e) {
            this._warn('GetLayout', e);
        }
    }

    _queueReload() {
        if (this._reloadId)
            return;
        this._reloadId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, RELOAD_DELAY_MS, () => {
            this._reloadId = 0;
            this.reload();
            return GLib.SOURCE_REMOVE;
        });
    }

    _propertiesUpdated(params) {
        const [updated, removed] = params.deepUnpack();
        const changed = new Map();
        for (const [id, props] of updated) {
            const node = this._nodes.get(id);
            if (!node)
                continue;
            for (const [key, value] of Object.entries(props)) {
                node.props[key] = value.recursiveUnpack();
                changed.set(id, [...changed.get(id) ?? [], key]);
            }
        }
        for (const [id, keys] of removed) {
            const node = this._nodes.get(id);
            if (!node)
                continue;
            for (const key of keys) {
                delete node.props[key];
                changed.set(id, [...changed.get(id) ?? [], key]);
            }
        }
        if (changed.size > 0)
            this._onChange(changed);
    }

    aboutToShow(id) {
        this._callAsync('AboutToShow', new GLib.Variant('(i)', [id]), '(b)')
            .then(reply => reply.deepUnpack()[0] && this._queueReload())
            .catch(e => this._warn('AboutToShow', e));
    }

    event(id, eventId) {
        this._callAsync('Event', new GLib.Variant('(isvu)',
            [id, eventId, new GLib.Variant('i', 0), Clutter.get_current_event_time()]))
            .catch(e => this._warn(`Event ${eventId}`, e));
    }

    node(id) {
        return this._nodes.get(id) ?? null;
    }

    destroy() {
        this._cancellable.cancel();
        this._signals.forEach(id => this._bus.signal_unsubscribe(id));
        if (this._reloadId)
            GLib.source_remove(this._reloadId);
        this._reloadId = 0;
    }
}

function _syncItem(item, props) {
    item.visible = props.visible !== false;
    item.setSensitive(props.enabled !== false);
    if (item.label)
        item.label.text = menuLabel(props.label);
    if (props['toggle-type'] === 'checkmark' && item.setToggleState)
        item.setToggleState(props['toggle-state'] === 1);
    else if (props['toggle-type'] === 'radio')
        item.setOrnament(props['toggle-state'] === 1 ? PopupMenu.Ornament.DOT : PopupMenu.Ornament.NO_DOT);
}

function _newSubmenu(client, node, label, items) {
    const item = new PopupMenu.PopupSubMenuMenuItem(label);
    node.children.forEach(child => _addNode(item.menu, client, child, items));
    item.menu.connect('open-state-changed', (_menu, open) => {
        if (open)
            client.aboutToShow(node.id);
        client.event(node.id, open ? 'opened' : 'closed');
    });
    return item;
}

function _newItem(client, node, items) {
    const {props} = node;
    if (props.type === 'separator')
        return new PopupMenu.PopupSeparatorMenuItem();
    const label = menuLabel(props.label);
    if (props['children-display'] === 'submenu' || node.children.length > 0)
        return _newSubmenu(client, node, label, items);
    const item = props['toggle-type'] === 'checkmark'
        ? new PopupMenu.PopupSwitchMenuItem(label, props['toggle-state'] === 1)
        : new PopupMenu.PopupMenuItem(label);
    const shortcut = shortcutText(props.shortcut);
    if (shortcut) {
        item.label.x_expand = true;
        item.add_child(new St.Label({
            text: shortcut,
            style_class: 'apex-indicator-menu-shortcut',
            y_align: Clutter.ActorAlign.CENTER,
        }));
    }
    item.connect('activate', () => client.event(node.id, 'clicked'));
    return item;
}

function _addNode(menu, client, node, items) {
    const item = _newItem(client, node, items);
    _syncItem(item, node.props);
    items.set(node.id, item);
    menu.addMenuItem(item);
}

// Fills menu from the client's layout; returns the update for an ItemsPropertiesUpdated.
export function fillMenu(menu, title, client) {
    menu.removeAll();
    const header = new PopupMenu.PopupMenuItem(title, {reactive: false, can_focus: false});
    header.add_style_class_name('apex-indicator-menu-header');
    menu.addMenuItem(header);
    const items = new Map();
    client.root.children.forEach(node => _addNode(menu, client, node, items));
    return changed => {
        for (const [id, keys] of changed) {
            if (keys.some(key => !IN_PLACE_PROPERTIES.has(key)))
                return false;
            const item = items.get(id);
            if (item)
                _syncItem(item, client.node(id).props);
        }
        return true;
    };
}
