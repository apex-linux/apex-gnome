// SPDX-License-Identifier: GPL-2.0-or-later

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';

import * as Hooks from '../hooks.js';
import * as PopupMenu from '../../popupMenu.js';

export const DND_STYLE_CLASS = 'apex-dnd-button';
export const DND_LABEL = 'Do Not Disturb';
export const SEPARATOR_STYLE_CLASS = 'apex-message-separator';
export const CALENDAR_STYLE_CLASS = 'apex-calendar';
export const EVENT_DOT_STYLE_CLASS = 'apex-event-dot';
export const ROW_STYLE_CLASS = 'apex-message-row';
const NOTIFICATIONS_SCHEMA = 'org.gnome.desktop.notifications';
const STACK_PSEUDO_CLASSES = ['second-in-stack', 'lower-in-stack'];

let _enabled = false;
let _footer = null;
const _headers = new Map();
const _messages = new Map();
const _groups = new Map();
const _calendars = new Map();
const _days = new Map();
const _layouts = new Map();

function _track(map, actor, parts) {
    map.set(actor, parts);
    actor.connect('destroy', () => map.delete(actor));
}

// The header reads "app · time": no source glyph, which the card's own icon column replaces.
function _furnishHeader(parts) {
    const {sourceIcon, content} = parts;
    sourceIcon.hide();
    parts.separator = new St.Label({style_class: SEPARATOR_STYLE_CLASS, text: '·', y_align: Clutter.ActorAlign.END});
    content.insert_child_at_index(parts.separator, 1);
}

function _plainHeader(parts) {
    parts.sourceIcon.show();
    parts.separator?.destroy();
    parts.separator = null;
}

function _messageIcon(icon, message) {
    const parts = _messages.get(message);
    if (parts)
        parts.icon = icon;
    return _enabled ? icon ?? parts?.source?.icon ?? null : icon;
}

// Board 34's card: the icon in its own column, beside the header over the title and body;
// the action row stays under both. Upstream's tree is kept as it was, to be put back.
function _columnize(message) {
    const {_header: header, _icon: icon} = message;
    const vbox = message.get_child();
    const box = icon?.get_parent();
    if (_layouts.has(message) || !box || header?.get_parent() !== vbox)
        return;
    const parts = {vbox, header, icon, box, at: vbox.get_children().indexOf(header), iconAt: box.get_children().indexOf(icon)};
    parts.column = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true});
    parts.row = new St.BoxLayout({style_class: ROW_STYLE_CLASS, x_expand: true});
    vbox.remove_child(header);
    vbox.remove_child(box);
    box.remove_child(icon);
    parts.column.add_child(header);
    parts.column.add_child(box);
    parts.row.add_child(icon);
    parts.row.add_child(parts.column);
    vbox.insert_child_at_index(parts.row, parts.at);
    parts.destroyId = message.connect('destroy', () => _layouts.delete(message));
    _layouts.set(message, parts);
}

function _uncolumnize(message) {
    const parts = _layouts.get(message);
    if (!parts)
        return;
    const {vbox, header, icon, box, row, column} = parts;
    _layouts.delete(message);
    message.disconnect(parts.destroyId);
    row.remove_child(icon);
    column.remove_child(header);
    column.remove_child(box);
    vbox.remove_child(row);
    box.insert_child_at_index(icon, parts.iconAt);
    vbox.insert_child_at_index(header, parts.at);
    vbox.insert_child_at_index(box, parts.at + 1);
    row.destroy();
}

// DESIGN's list is flat: a group lays its cards out one under another, without its header.
function _flatten(group, parts) {
    _cards(group).forEach(_columnize);
    parts.addedId = group.connect('notification-added', () => _cards(group).forEach(_columnize));
    parts.layout = group.layout_manager;
    group.layout_manager = new Clutter.BoxLayout({orientation: Clutter.Orientation.VERTICAL});
    parts.cover.hide();
    parts.header.hide();
    _cards(group).forEach(card => STACK_PSEUDO_CLASSES.forEach(name => card.remove_style_pseudo_class(name)));
    group.notify('expanded');
}

function _cards(group) {
    return group.get_children().map(item => item.child).filter(Boolean);
}

function _restack(group, parts) {
    if (parts.addedId)
        group.disconnect(parts.addedId);
    parts.addedId = null;
    _cards(group).forEach(_uncolumnize);
    group.layout_manager = parts.layout;
    parts.layout = null;
    parts.cover.show();
    if (!group.expanded)
        _cards(group).slice(1).forEach((card, i) => card.add_style_pseudo_class(STACK_PSEUDO_CLASSES[Math.min(i, 1)]));
    group.notify('expanded');
}

function _dndButton() {
    const settings = new Gio.Settings({schema_id: NOTIFICATIONS_SCHEMA});
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
    const settingsId = settings.connect('changed::show-banners', sync);
    button.connect('destroy', () => settings.disconnect(settingsId));
    sync();
    return button;
}

// The footer: Do Not Disturb on the left, Clear on the right, shown even with nothing to clear.
function _furnishFooter() {
    const {hbox, clear} = _footer;
    _footer.dnd = _dndButton();
    hbox.insert_child_at_index(_footer.dnd, 0);
    _footer.stock = {xAlign: clear.x_align};
    clear.x_align = Clutter.ActorAlign.END;
    _footer.visibleId = clear.connect('notify::visible', () => clear.show());
    clear.show();
}

function _plainFooter() {
    const {clear, placeholder, stock} = _footer;
    clear.disconnect(_footer.visibleId);
    clear.x_align = stock.xAlign;
    clear.visible = !placeholder.visible;
    _footer.dnd.destroy();
    _footer.dnd = null;
}

// Board 34: the month on the left, both chevrons on the right.
function _furnishCalendar(calendar, parts) {
    calendar.add_style_class_name(CALENDAR_STYLE_CLASS);
    parts.xAlign = parts.label.x_align;
    parts.label.x_align = Clutter.ActorAlign.START;
    parts.topBox.set_child_at_index(parts.label, 0);
}

function _plainCalendar(calendar, parts) {
    calendar.remove_style_class_name(CALENDAR_STYLE_CLASS);
    parts.label.x_align = parts.xAlign;
    parts.topBox.set_child_at_index(parts.label, 1);
}

// The number over a dot every day keeps, so the numbers stay put; the sheet colours it on event days.
function _furnishDay(button, parts) {
    parts.label = button.get_child();
    button.set_child(null);
    parts.box = new St.BoxLayout({
        orientation: Clutter.Orientation.VERTICAL,
        x_align: Clutter.ActorAlign.CENTER,
        y_align: Clutter.ActorAlign.CENTER,
    });
    parts.box.add_child(parts.label);
    parts.box.add_child(new St.Widget({style_class: EVENT_DOT_STYLE_CLASS, x_align: Clutter.ActorAlign.CENTER}));
    button.set_child(parts.box);
}

function _plainDay(button, parts) {
    parts.box.remove_child(parts.label);
    button.set_child(parts.label);
    parts.box.destroy();
    parts.box = null;
}

export function configure(featureName) {
    Hooks.provide(featureName, 'message-header', (header, sourceIcon, content) => {
        const parts = {sourceIcon, content};
        _track(_headers, header, parts);
        if (_enabled)
            _furnishHeader(parts);
    });
    Hooks.provide(featureName, 'message', (message, source) => _track(_messages, message, {source}));
    Hooks.provide(featureName, 'message-icon', _messageIcon);
    Hooks.provide(featureName, 'message-group', (group, cover, header) => {
        const parts = {cover, header};
        _track(_groups, group, parts);
        if (_enabled)
            _flatten(group, parts);
    });
    Hooks.provide(featureName, 'message-group-expanded', (expanded, group) =>
        _enabled && _groups.has(group) ? true : expanded);
    Hooks.provide(featureName, 'calendar-header', (calendar, topBox, label) => {
        const parts = {topBox, label};
        _calendars.set(calendar, parts);
        if (_enabled)
            _furnishCalendar(calendar, parts);
    });
    Hooks.provide(featureName, 'calendar-day', button => {
        const parts = {};
        _track(_days, button, parts);
        if (_enabled)
            _furnishDay(button, parts);
    });
    Hooks.provide(featureName, 'message-list-controls', (hbox, clear, placeholder) => {
        _footer = {hbox, clear, placeholder};
        if (_enabled)
            _furnishFooter();
    });
}

function _refreshIcons() {
    _messages.forEach((parts, message) => {
        if ('icon' in parts)
            message.icon = parts.icon;
    });
}

export function enable() {
    _enabled = true;
    _headers.forEach(parts => _furnishHeader(parts));
    _groups.forEach((parts, group) => _flatten(group, parts));
    _calendars.forEach((parts, calendar) => _furnishCalendar(calendar, parts));
    _days.forEach((parts, button) => _furnishDay(button, parts));
    if (_footer)
        _furnishFooter();
    _refreshIcons();
}

export function disable() {
    _enabled = false;
    _headers.forEach(_plainHeader);
    _groups.forEach((parts, group) => _restack(group, parts));
    _calendars.forEach((parts, calendar) => _plainCalendar(calendar, parts));
    _days.forEach((parts, button) => _plainDay(button, parts));
    if (_footer?.dnd)
        _plainFooter();
    _refreshIcons();
}
