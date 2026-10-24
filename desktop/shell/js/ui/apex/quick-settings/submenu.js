// SPDX-License-Identifier: GPL-2.0-or-later

// Board 17's submenus: the header's subtitle at the end of the title's row, the active
// network's row :checked and its lock after the name.

import Clutter from 'gi://Clutter';

export const CHECKED = 'checked';
export const LOCK_STYLE_CLASS = 'apex-network-lock';

const _rows = new Map();
const _menus = new Map();

function _followActive(item) {
    if (item.network.is_active)
        item.add_style_pseudo_class(CHECKED);
    else
        item.remove_style_pseudo_class(CHECKED);
}

export function addRow(item) {
    const lock = item._secureIcon;
    const icons = lock?.get_parent();
    if (_rows.has(item) || !icons || !item._label)
        return;
    const entry = {lock, icons, yAlign: lock.y_align};
    entry.ids = [[item.network, item.network.connect('notify::is-active', () => _followActive(item))],
        [item, item.connect('destroy', () => _forgetRow(item))]];
    _rows.set(item, entry);
    icons.remove_child(lock);
    item.insert_child_above(lock, item._label);
    lock.y_align = Clutter.ActorAlign.CENTER;
    lock.add_style_class_name(LOCK_STYLE_CLASS);
    _followActive(item);
}

function _forgetRow(item) {
    _rows.get(item).ids.forEach(([emitter, id]) => emitter.disconnect(id));
    _rows.delete(item);
}

function _restoreRow(item) {
    const {lock, icons, yAlign} = _rows.get(item);
    _forgetRow(item);
    item.remove_style_pseudo_class(CHECKED);
    lock.remove_style_class_name(LOCK_STYLE_CLASS);
    lock.y_align = yAlign;
    item.remove_child(lock);
    icons.add_child(lock);
}

function _side(menu) {
    return menu.actor.text_direction === Clutter.TextDirection.RTL
        ? Clutter.GridPosition.LEFT : Clutter.GridPosition.RIGHT;
}

export function addMenu(menu) {
    const {_header: header, _headerSubtitle: subtitle, _headerSpacer: spacer} = menu;
    if (_menus.has(menu) || !header || !subtitle || !spacer)
        return;
    _menus.set(menu, {xAlign: subtitle.x_align, destroyId: menu.connect('destroy', () => _menus.delete(menu))});
    header.remove_child(subtitle);
    header.layout_manager.attach_next_to(subtitle, spacer, _side(menu), 1, 1);
    subtitle.x_align = Clutter.ActorAlign.END;
}

function _restoreMenu(menu) {
    const {_header: header, _headerSubtitle: subtitle, _headerTitle: title} = menu;
    const {xAlign, destroyId} = _menus.get(menu);
    menu.disconnect(destroyId);
    _menus.delete(menu);
    subtitle.x_align = xAlign;
    header.remove_child(subtitle);
    header.layout_manager.attach_next_to(subtitle, title, Clutter.GridPosition.BOTTOM, 1, 1);
}

// Menus and rows built before the feature enabled sit in Quick Settings' tree.
export function addExisting(root) {
    const walk = actor => {
        const delegate = actor._delegate;
        if (delegate?._headerSubtitle)
            addMenu(delegate);
        if (actor._secureIcon && actor.network)
            addRow(actor);
        actor.get_children().forEach(walk);
    };
    walk(root);
}

export function restore() {
    [..._rows.keys()].forEach(_restoreRow);
    [..._menus.keys()].forEach(_restoreMenu);
}
