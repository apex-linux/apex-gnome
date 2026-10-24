// SPDX-License-Identifier: GPL-2.0-or-later

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';

import * as Hooks from '../hooks.js';
import * as PopupMenu from '../../popupMenu.js';

export const DND_STYLE_CLASS = 'apex-dnd-button';
export const DND_LABEL = 'Do Not Disturb';
export const SEPARATOR_STYLE_CLASS = 'apex-message-separator';
const NOTIFICATIONS_SCHEMA = 'org.gnome.desktop.notifications';
const STACK_PSEUDO_CLASSES = ['second-in-stack', 'lower-in-stack'];

let _enabled = false;
let _footer = null;
const _headers = new Map();
const _messages = new Map();
const _groups = new Map();

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

// DESIGN's list is flat: a group lays its cards out one under another, without its header.
function _flatten(group, parts) {
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
    if (_footer)
        _furnishFooter();
    _refreshIcons();
}

export function disable() {
    _enabled = false;
    _headers.forEach(_plainHeader);
    _groups.forEach((parts, group) => _restack(group, parts));
    if (_footer?.dnd)
        _plainFooter();
    _refreshIcons();
}
