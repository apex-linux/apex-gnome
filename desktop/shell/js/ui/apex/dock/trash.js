// SPDX-License-Identifier: GPL-2.0-or-later
//
// The dock's Trash: opens trash:/// in Files; its menu empties it.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Dash from '../../dash.js';
import * as IconGrid from '../../iconGrid.js';
import * as Main from '../../main.js';
import * as PopupMenu from '../../popupMenu.js';

const TRASH_URI = 'trash:///';
const ITEM_COUNT_ATTRIBUTE = 'trash::item-count';

export const TrashItem = GObject.registerClass(
class TrashItem extends Dash.DashItemContainer {
    _init() {
        super._init();
        this._file = Gio.File.new_for_uri(TRASH_URI);
        this._empty = true;

        const button = new St.Button({
            style_class: 'apex-dock-trash',
            track_hover: true,
            can_focus: true,
            button_mask: St.ButtonMask.ONE | St.ButtonMask.THREE,
        });
        this.icon = new IconGrid.BaseIcon('Trash', {
            setSizeManually: true,
            showLabel: false,
            createIcon: size => new St.Icon({
                icon_name: this._empty ? 'user-trash' : 'user-trash-full',
                fallback_icon_name: this._empty ? 'user-trash-symbolic' : 'user-trash-full-symbolic',
                icon_size: size,
            }),
        });
        this.icon.y_align = Clutter.ActorAlign.CENTER;
        button.child = this.icon;
        button._delegate = this;
        button.connect('clicked', (_button, mouseButton) => {
            if (mouseButton === Clutter.BUTTON_SECONDARY)
                this._openMenu();
            else
                this._open();
        });
        this.setChild(button);
        this.setLabelText('Trash');

        this._menu = new PopupMenu.PopupMenu(button, 0.5, St.Side.BOTTOM);
        this._menu.addAction('Open', () => this._open());
        this._emptyItem = this._menu.addAction('Empty Trash', () => this._emptyTrash());
        Main.uiGroup.add_child(this._menu.actor);
        this._menu.actor.hide();
        this._menuManager = new PopupMenu.PopupMenuManager(button);
        this._menuManager.addMenu(this._menu);

        // Without gvfs there is no trash:/// to watch, and the Trash stays empty.
        try {
            this._monitor = this._file.monitor_directory(Gio.FileMonitorFlags.NONE, null);
            this._monitor.connect('changed', () => this._sync());
        } catch {
            this._monitor = null;
        }
        this.connect('destroy', () => {
            this._monitor?.cancel();
            this._menu.destroy();
        });
        this._sync();
    }

    _sync() {
        let empty = true;
        try {
            const info = this._file.query_info(ITEM_COUNT_ATTRIBUTE, Gio.FileQueryInfoFlags.NONE, null);
            empty = info.get_attribute_uint32(ITEM_COUNT_ATTRIBUTE) === 0;
        } catch {}
        this._emptyItem.setSensitive(!empty);
        if (empty === this._empty)
            return;
        this._empty = empty;
        this.icon._createIconTexture(this.icon.iconSize);
    }

    _open() {
        Gio.AppInfo.launch_default_for_uri(TRASH_URI, global.create_app_launch_context(0, -1));
        Main.overview.hide();
    }

    _openMenu() {
        this._sync();
        this._menu.open(true);
    }

    _emptyTrash() {
        Gio.Subprocess.new(['gio', 'trash', '--empty'], Gio.SubprocessFlags.NONE);
    }
});
