// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 34's notification list in the date menu: a flat list of cards, each with its app's
// icon in a 32 px column; Clear always shown on the right; Do Not Disturb as a footer switch.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Hooks from '../hooks.js';
import * as PopupMenu from '../../popupMenu.js';

const NOTIFICATIONS_SCHEMA = 'org.gnome.desktop.notifications';
const SHOW_BANNERS_KEY = 'show-banners';
export const ICON_SIZE = 32;
export const ROW_STYLE_CLASS = 'apex-message-row';
export const DND_STYLE_CLASS = 'apex-dnd-switch';
export const DND_LABEL = 'Do Not Disturb';

let _enabled = false;
let _settings = null;
const _lists = new Set();
const _groups = new Set();
const _appliedLists = new Map();
const _appliedGroups = new Map();
const _appliedMessages = new Map();

function _messages(group) {
    return [...group._notificationToMessage.values()];
}

// The app's icon leaves the header for a column beside the whole card.
function _applyMessage(message) {
    if (_appliedMessages.has(message))
        return;
    const card = message.get_child();
    const header = message._header;
    const icon = header.get_first_child();
    header.remove_child(icon);
    message.set_child(null);
    const row = new St.BoxLayout({style_class: ROW_STYLE_CLASS, x_expand: true});
    icon.set({icon_size: ICON_SIZE, y_align: Clutter.ActorAlign.START});
    row.add_child(icon);
    row.add_child(card);
    message.set_child(row);
    const destroyId = message.connect('destroy', () => _appliedMessages.delete(message));
    _appliedMessages.set(message, {row, card, icon, header, destroyId});
}

function _restoreMessage(message) {
    const {row, card, icon, header, destroyId} = _appliedMessages.get(message);
    _appliedMessages.delete(message);
    message.disconnect(destroyId);
    row.remove_child(icon);
    row.remove_child(card);
    message.set_child(card);
    icon.set({icon_size: -1, y_align: Clutter.ActorAlign.CENTER});
    header.insert_child_at_index(icon, 0);
    row.destroy();
}

// A flat group is always expanded and shows no header: its cards follow one another.
function _applyGroup(group) {
    if (_appliedGroups.has(group))
        return;
    group.expand();
    group._headerBox.hide();
    _messages(group).forEach(_applyMessage);
    const addedId = group.connect('notification-added', () => _messages(group).forEach(_applyMessage));
    _appliedGroups.set(group, addedId);
}

function _restoreGroup(group) {
    group.disconnect(_appliedGroups.get(group));
    _appliedGroups.delete(group);
    _messages(group).filter(m => _appliedMessages.has(m)).forEach(_restoreMessage);
    group.collapse();
}

function _flatHeight(stock, group, forWidth) {
    if (!_appliedGroups.has(group))
        return stock;
    return group.get_children()
        .filter(child => child.visible && child !== group._cover && child !== group._headerBox)
        .map(child => child.get_preferred_height(forWidth))
        .reduce(([min, nat], [m, n]) => [min + m, nat + n], [0, 0]);
}

function _newDndSwitch() {
    const toggle = new PopupMenu.Switch(!_settings.get_boolean(SHOW_BANNERS_KEY));
    toggle.reactive = false;
    const box = new St.BoxLayout({style_class: `${DND_STYLE_CLASS}-box`});
    box.add_child(toggle);
    box.add_child(new St.Label({text: DND_LABEL, y_align: Clutter.ActorAlign.CENTER}));
    const button = new St.Button({
        style_class: DND_STYLE_CLASS,
        toggle_mode: true,
        can_focus: true,
        accessible_name: DND_LABEL,
        child: box,
        checked: toggle.state,
    });
    const sync = () => {
        button.checked = !_settings.get_boolean(SHOW_BANNERS_KEY);
        toggle.state = button.checked;
    };
    const settingsId = _settings.connect(`changed::${SHOW_BANNERS_KEY}`, sync);
    button.connect('clicked', () => _settings.set_boolean(SHOW_BANNERS_KEY, !button.checked));
    button.connect('destroy', () => _settings.disconnect(settingsId));
    return button;
}

function _applyList(list) {
    if (_appliedLists.has(list))
        return;
    const clear = list._clearButton;
    list._clearButtonVisibility?.unbind();
    list._clearButtonVisibility = null;
    clear.set({visible: true, x_align: Clutter.ActorAlign.END});
    const dnd = _newDndSwitch();
    clear.get_parent().insert_child_at_index(dnd, 0);
    _appliedLists.set(list, dnd);
}

function _restoreList(list) {
    _appliedLists.get(list).destroy();
    _appliedLists.delete(list);
    const clear = list._clearButton;
    clear.x_align = Clutter.ActorAlign.START;
    list._clearButtonVisibility = list._placeholder.bind_property('visible',
        clear, 'visible',
        GObject.BindingFlags.SYNC_CREATE | GObject.BindingFlags.INVERT_BOOLEAN);
}

function _forget(set, applied, actor) {
    actor.connect('destroy', () => {
        set.delete(actor);
        applied.delete(actor);
    });
}

function _onMessageList(list) {
    _lists.add(list);
    _forget(_lists, _appliedLists, list);
    if (_enabled)
        _applyList(list);
}

function _onNotificationGroup(group) {
    _groups.add(group);
    _forget(_groups, _appliedGroups, group);
    if (_enabled)
        _applyGroup(group);
}

export function configure(featureName) {
    const schema = Gio.SettingsSchemaSource.get_default()?.lookup(NOTIFICATIONS_SCHEMA, true);
    if (!schema?.has_key(SHOW_BANNERS_KEY))
        throw new Error(`${NOTIFICATIONS_SCHEMA} has no key ${SHOW_BANNERS_KEY}`);
    _settings = new Gio.Settings({settings_schema: schema});
    Hooks.provide(featureName, 'message-list', _onMessageList);
    Hooks.provide(featureName, 'notification-group', _onNotificationGroup);
    Hooks.provide(featureName, 'message-group-expanded-height', _flatHeight);
}

export function enable() {
    _enabled = true;
    _lists.forEach(_applyList);
    _groups.forEach(_applyGroup);
}

export function disable() {
    _enabled = false;
    [..._appliedGroups.keys()].forEach(_restoreGroup);
    [..._appliedLists.keys()].forEach(_restoreList);
}
