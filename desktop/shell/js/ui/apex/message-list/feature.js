// SPDX-License-Identifier: GPL-2.0-or-later

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';

import * as Main from '../../main.js';
import * as MessageList from '../../messageList.js';
import * as PopupMenu from '../../popupMenu.js';

export const FLAT_STYLE_CLASS = 'apex-flat';
export const DND_STYLE_CLASS = 'apex-dnd-button';
export const DND_LABEL = 'Do Not Disturb';
const NOTIFICATIONS_SCHEMA = 'org.gnome.desktop.notifications';

let _list = null;
const _groups = new Map();

function _items(group) {
    return group.get_children().filter(c => c instanceof St.Bin);
}

// DESIGN's list is flat: every group stays as stock shows an expanded one, without its header.
function _flatten(group) {
    if (_groups.has(group))
        return;
    _groups.set(group, group.connect('destroy', () => _groups.delete(group)));
    group._expanded = true;
    group._cover.hide();
    group._headerBox.hide();
    group._headerBox.set_height(0);
    group.layout_manager.expansion = 1;
    _items(group).forEach(item => (item.layout_manager.scalingEnabled = true));
    group._updateStackedMessagesFade();
    group.add_style_class_name(FLAT_STYLE_CLASS);
    group.notify('expanded');
}

function _restack(destroyId, group) {
    group.disconnect(destroyId);
    group._expanded = false;
    group._cover.show();
    group._headerBox.set_height(-1);
    group.layout_manager.expansion = 0;
    _items(group).forEach(item => (item.layout_manager.scalingEnabled = false));
    group._updateStackedMessagesFade();
    group.remove_style_class_name(FLAT_STYLE_CLASS);
    group.notify('expanded');
}

function _flattenItem(item) {
    if (item.child instanceof MessageList.NotificationMessageGroup)
        _flatten(item.child);
}

function _dndButton(settings) {
    const toggle = new PopupMenu.Switch(false);
    const box = new St.BoxLayout({x_expand: true});
    box.add_child(new St.Label({text: DND_LABEL, y_align: Clutter.ActorAlign.CENTER, x_expand: true}));
    box.add_child(toggle);
    const button = new St.Button({style_class: DND_STYLE_CLASS, child: box, can_focus: true, accessible_name: DND_LABEL});
    const sync = () => {
        toggle.state = !settings.get_boolean('show-banners');
        button.checked = toggle.state;
    };
    button.connect('clicked', () => settings.set_boolean('show-banners', toggle.state));
    _list.settingsId = settings.connect('changed::show-banners', sync);
    sync();
    return button;
}

// The footer: Do Not Disturb on the left, Clear on the right, shown even with nothing to clear.
function _furnishFooter() {
    const {clear} = _list;
    _list.dnd = _dndButton(_list.settings);
    clear.get_parent().insert_child_at_index(_list.dnd, 0);
    _list.clearPlace = {xExpand: clear.x_expand, xAlign: clear.x_align};
    clear.x_expand = true;
    clear.x_align = Clutter.ActorAlign.END;
    _list.clearId = clear.connect('notify::visible', () => clear.show());
    clear.show();
}

function _clearFooter() {
    const {clear, clearPlace, placeholder, settings} = _list;
    clear.disconnect(_list.clearId);
    settings.disconnect(_list.settingsId);
    Object.assign(clear, {x_expand: clearPlace.xExpand, x_align: clearPlace.xAlign, visible: !placeholder.visible});
    _list.dnd.destroy();
}

export function enable() {
    const messageList = Main.panel.statusArea.dateMenu?._messageList;
    if (!messageList)
        throw new Error('no calendar message list');
    _list = {
        view: messageList._messageView,
        clear: messageList._clearButton,
        placeholder: messageList._placeholder,
        settings: new Gio.Settings({schema_id: NOTIFICATIONS_SCHEMA}),
    };
    _list.view.get_children().forEach(_flattenItem);
    _list.viewId = _list.view.connect('child-added', (_view, item) => _flattenItem(item));
    _furnishFooter();
}

export function disable() {
    if (!_list)
        return;
    _list.view.disconnect(_list.viewId);
    _groups.forEach(_restack);
    _groups.clear();
    _clearFooter();
    _list = null;
}
