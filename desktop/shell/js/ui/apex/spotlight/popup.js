// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 38's popup: the field over the sections, one selected row across them.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from '../../main.js';
import * as Toast from './toast.js';
import {Search, termsOf} from './search.js';

const HINT = 'Search apps, settings and files, or type a sum';
const SEARCH_GLYPH = 'system-search-symbolic';
const CLEAR_GLYPH = 'edit-clear-symbolic';
const ICON_SIZE = 32;
const TILE_GLYPH_SIZE = 16;
const TYPING_PAUSE_MS = 50;
const ENTER_KEYS = [Clutter.KEY_Return, Clutter.KEY_KP_Enter, Clutter.KEY_ISO_Enter];

export class Popup {
    constructor(loadProviders, toggleAction) {
        this._loadProviders = loadProviders;
        this._toggleAction = toggleAction;
        this._actor = null;
        this._rows = [];
        this._selected = -1;
        this._serial = 0;
        this._typingId = 0;
    }

    get isOpen() {
        return this._actor !== null;
    }

    get rows() {
        return this._rows.map(({row}, index) => ({...row, selected: index === this._selected}));
    }

    toggle() {
        if (this.isOpen)
            this.close();
        else
            this.open();
    }

    open(text = '') {
        if (this.isOpen)
            return;
        Toast.hide();
        this._search = new Search(this._loadProviders());
        this._build();
        Main.uiGroup.add_child(this._actor);
        this._grab = Main.pushModal(this._actor, {actionMode: Shell.ActionMode.POPUP});
        this._entry.grab_key_focus();
        if (text !== '')
            this._entry.set_text(text);
        this._overlayKeyId = global.display.connect('overlay-key', () => {
            this.close();
            Main.overview.show();
        });
    }

    close() {
        if (!this.isOpen)
            return;
        if (this._overlayKeyId)
            global.display.disconnect(this._overlayKeyId);
        this._overlayKeyId = 0;
        if (this._typingId)
            GLib.source_remove(this._typingId);
        this._typingId = 0;
        this._serial++;
        this._search.cancel();
        if (this._grab)
            Main.popModal(this._grab);
        this._grab = null;
        this._actor.destroy();
        this._actor = null;
        this._rows = [];
        this._selected = -1;
        this._shownText = undefined;
    }

    activateSelected() {
        this._activate(this._selected);
    }

    destroy() {
        this.close();
        Toast.hide();
    }

    _build() {
        const monitor = Main.layoutManager.primaryMonitor;
        this._actor = new St.Widget({
            name: 'apexSpotlight',
            reactive: true,
            layout_manager: new Clutter.BinLayout(),
            x: monitor.x, y: monitor.y, width: monitor.width, height: monitor.height,
        });
        const backdrop = new St.Widget({reactive: true, x_expand: true, y_expand: true});
        const outside = new Clutter.ClickGesture();
        outside.connect('recognize', () => this.close());
        backdrop.add_action(outside);
        this._actor.add_child(backdrop);

        this.panel = new St.BoxLayout({
            style_class: 'apex-spotlight',
            orientation: Clutter.Orientation.VERTICAL,
            reactive: true,
            accessible_name: 'Spotlight',
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.START,
            x_expand: true,
            y_expand: true,
        });
        this.panel.add_child(this._buildField());
        this._results = new St.BoxLayout({
            style_class: 'apex-spotlight-results',
            orientation: Clutter.Orientation.VERTICAL,
            visible: false,
        });
        this.panel.add_child(this._results);
        this._emptyLabel = new St.Label({x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER});
        this._empty = new St.Bin({style_class: 'apex-spotlight-empty', child: this._emptyLabel, visible: false});
        this.panel.add_child(this._empty);
        this._actor.add_child(this.panel);
    }

    _buildField() {
        const field = new St.BoxLayout({style_class: 'apex-spotlight-field'});
        field.add_child(new St.Icon({
            icon_name: SEARCH_GLYPH,
            style_class: 'apex-spotlight-glyph',
            y_align: Clutter.ActorAlign.CENTER,
        }));
        this._entry = new St.Entry({
            style_class: 'apex-spotlight-entry',
            hint_text: HINT,
            accessible_name: 'Search',
            can_focus: true,
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._entry.clutter_text.connect('text-changed', () => this._queueSearch());
        const keys = new Clutter.KeyController();
        keys.connect('key-press', () => this._onKeyPress(keys));
        this._entry.add_action_full('apex-spotlight-keys', Clutter.EventPhase.CAPTURE, keys);
        field.add_child(this._entry);
        this._clear = new St.Button({
            style_class: 'apex-spotlight-clear',
            accessible_name: 'Clear',
            child: new St.Icon({icon_name: CLEAR_GLYPH}),
            visible: false,
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._clear.connect('clicked', () => this._entry.set_text(''));
        field.add_child(this._clear);
        return field;
    }

    _onKeyPress(keys) {
        const [, symbol, keycode] = keys.get_key();
        const [, pressed, latched, locked] = keys.get_state();
        if (symbol === Clutter.KEY_Escape ||
            global.display.get_keybinding_action(keycode, pressed | latched | locked) === this._toggleAction) {
            this.close();
        } else if (symbol === Clutter.KEY_Down || symbol === Clutter.KEY_Up) {
            const step = symbol === Clutter.KEY_Down ? 1 : -1;
            this._moved = true;
            this._select(Math.max(0, Math.min(this._rows.length - 1, this._selected + step)));
        } else if (ENTER_KEYS.includes(symbol)) {
            this.activateSelected();
        } else {
            return Clutter.EVENT_PROPAGATE;
        }
        return Clutter.EVENT_STOP;
    }

    _queueSearch() {
        const text = this._entry.get_text();
        this._clear.visible = text !== '';
        if (this._typingId)
            GLib.source_remove(this._typingId);
        this._typingId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, TYPING_PAUSE_MS, () => {
            this._typingId = 0;
            this._runSearch(text).catch(e => console.error(`Apex: Spotlight search failed: ${e}`));
            return GLib.SOURCE_REMOVE;
        });
    }

    _runSearch(text) {
        const serial = ++this._serial;
        return this._search.run(termsOf(text), (sections, done) => {
            const rows = sections.reduce((n, section) => n + section.rows.length, 0);
            if (serial === this._serial && this.isOpen && (rows > 0 || done))
                this._show(sections, text.trim());
        });
    }

    // Until the user moves it, the selection is the first row; then a section that arrives
    // later never moves it. A new query starts at the top.
    _show(sections, text) {
        if (text !== this._shownText)
            this._moved = false;
        const selectedKey = this._moved ? this._rows[this._selected]?.row.key : undefined;
        this._shownText = text;
        this._results.destroy_all_children();
        this._rows = [];
        for (const section of sections) {
            const header = new St.Bin({
                style_class: 'apex-spotlight-header',
                child: new St.Label({
                    text: section.name.toUpperCase(),
                    x_align: Clutter.ActorAlign.START,
                    y_align: Clutter.ActorAlign.END,
                }),
            });
            this._results.add_child(header);
            for (const row of section.rows)
                this._results.add_child(this._buildRow(row, this._rows.length));
        }
        this._results.visible = this._rows.length > 0;
        this._empty.visible = text !== '' && this._rows.length === 0;
        this._emptyLabel.text = `No results for “${text}”`;
        const kept = this._rows.findIndex(({row}) => row.key === selectedKey);
        if (kept >= 0)
            this._select(kept);
        else
            this._select(this._rows.length > 0 ? 0 : -1);
    }

    // Settings rows draw the provider's symbolic icon on a tile of the panel's colour.
    _buildIcon(row) {
        const tiled = row.tile !== undefined;
        const icon = new St.Bin({
            style_class: tiled ? 'apex-spotlight-icon apex-spotlight-tile' : 'apex-spotlight-icon',
            y_align: Clutter.ActorAlign.CENTER,
            child: row.gicon
                ? new St.Icon({gicon: row.gicon, icon_size: ICON_SIZE})
                : row.createIcon(tiled ? TILE_GLYPH_SIZE : ICON_SIZE),
        });
        if (row.tile === 'accent') {
            icon.add_style_class_name('apex-spotlight-tile-accent');
        } else if (row.tile) {
            icon.add_style_class_name('apex-spotlight-tile-coloured');
            icon.set_style(`background-color: ${row.tile};`);
        }
        return icon;
    }

    _buildRow(row, index) {
        const actor = new St.BoxLayout({
            style_class: 'apex-spotlight-row',
            reactive: true,
            track_hover: true,
            accessible_name: row.title,
        });
        actor.add_child(this._buildIcon(row));
        const text = new St.BoxLayout({
            style_class: 'apex-spotlight-text',
            orientation: Clutter.Orientation.VERTICAL,
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        });
        const titleClass = row.copyText === null ? 'apex-spotlight-title' : 'apex-spotlight-title apex-spotlight-result';
        text.add_child(new St.Label({style_class: titleClass, text: row.title}));
        text.add_child(new St.Label({style_class: 'apex-spotlight-subtitle', text: row.subtitle}));
        actor.add_child(text);
        const action = new St.BoxLayout({style_class: 'apex-spotlight-action', visible: false, y_align: Clutter.ActorAlign.CENTER});
        action.add_child(new St.Label({text: row.copyText === null ? 'Open' : 'Copy', y_align: Clutter.ActorAlign.CENTER}));
        action.add_child(new St.Bin({
            style_class: 'apex-spotlight-chip',
            y_align: Clutter.ActorAlign.CENTER,
            child: new St.Label({text: 'Enter', y_align: Clutter.ActorAlign.CENTER}),
        }));
        actor.add_child(action);
        actor.connect('notify::hover', () => {
            if (!actor.hover)
                return;
            this._moved = true;
            this._select(index);
        });
        const click = new Clutter.ClickGesture();
        click.connect('recognize', () => this._activate(index));
        actor.add_action(click);
        this._rows.push({row, actor, action});
        return actor;
    }

    _select(index) {
        this._selected = index;
        this._rows.forEach(({actor, action}, i) => {
            if (i === index)
                actor.add_style_pseudo_class('selected');
            else
                actor.remove_style_pseudo_class('selected');
            action.visible = i === index;
        });
    }

    _activate(index) {
        const row = this._rows[index]?.row;
        if (!row)
            return;
        this.close();
        if (row.copyText === null) {
            Main.overview.hide();
            row.activate();
            return;
        }
        St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, row.copyText);
        Toast.show(`Copied ${row.copyText}`);
    }
}
