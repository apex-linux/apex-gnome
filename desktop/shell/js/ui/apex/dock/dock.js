// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's dock: upstream's Dash at a fixed icon size, its apps, a separator, a full-colour Show
// Apps tile and Trash, each icon lifted while hovered and named while hovered or key focused.

import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Dash from '../../dash.js';
import * as Main from '../../main.js';
import {TrashItem} from './trash.js';

const LIFT_PX = 6;
const LIFT_MS = 180;
const SHOW_APPS_FALLBACK_ICON = 'view-app-grid-symbolic';
const NO_INDICATORS_STYLE_CLASS = 'apex-dock-no-indicators';

export const ApexDock = GObject.registerClass(
class ApexDock extends Dash.Dash {
    _init(iconSize) {
        this._fixedIconSize = iconSize;
        this._focusItem = null;
        this._focusShowing = null;
        this._menuItem = null;
        this._slidOut = false;
        super._init();
        this.name = 'apexDock';
        this._dashContainer.add_style_class_name('apex-dock-items');

        this._tailSeparator = new St.Widget({
            style_class: 'apex-dock-separator',
            y_align: Clutter.ActorAlign.END,
        });
        this._dashContainer.insert_child_below(this._tailSeparator, this._showAppsIcon);

        this._trash = new TrashItem();
        this._hookUpLabel(this._trash);
        this._dashContainer.add_child(this._trash);
        this._trash.show(false);

        this._showAppsIcon.icon._iconBin.connect('notify::child', bin => {
            if (bin.child)
                bin.child.fallback_icon_name = SHOW_APPS_FALLBACK_ICON;
        });
        for (const item of [this._showAppsIcon, this._trash]) {
            this._liftOnHover(item.child, item.child._delegate.icon);
            item.label.add_style_class_name('apex-dock-label');
            this._nameOnFocus(item);
        }
        this._trash._menu.connect('open-state-changed', (_menu, open) =>
            this._itemMenuStateChanged(this._trash, open));
        this._adjustIconSize();
    }

    // Intellihide slides the dock's box below the screen, with the dock still mapped.
    setSlidOut(slidOut) {
        this._slidOut = slidOut;
        this._syncFocusLabel();
    }

    // The dock moved to a new primary: the focused item's label follows it, without fading in again.
    replaceFocusLabel() {
        if (this._focusShowing)
            this._placeLabel(this._focusShowing);
    }

    // Where upstream's showLabel puts the label (dash.js), but clamped to the item's monitor, not the stage.
    _placeLabel(item) {
        const [x, y] = item.get_transformed_position();
        const {width, height} = item.label;
        const monitor = Main.layoutManager.findMonitorForActor(item) ?? {x: 0, width: global.stage.width};
        const left = Math.floor(x + (item.allocation.get_width() - width) / 2);
        item.label.set_position(Math.max(monitor.x, Math.min(left, monitor.x + monitor.width - width)),
            y - height - item.label.get_theme_node().get_length('-y-offset'));
    }

    _keepLabelOnMonitor(item) {
        const showLabel = item.showLabel.bind(item);
        item.showLabel = () => {
            showLabel();
            this._placeLabel(item);
        };
    }

    // Upstream's dash names an item on hover only (dash.js _syncLabel).
    _nameOnFocus(item) {
        this._keepLabelOnMonitor(item);
        item.child.connect('key-focus-in', () => {
            this._focusItem = item;
            this._syncFocusLabel();
        });
        item.child.connect('key-focus-out', () => {
            if (this._focusItem === item)
                this._focusItem = null;
            if (this._focusShowing === item) {
                this._focusShowing = null;
                if (!item.child.hover)
                    item.hideLabel();
            }
        });
        item.child.connect('notify::mapped', () => this._syncFocusLabel());
        // Upstream hides the label on activation; the item keeps the key focus.
        item.child.connect('clicked', () => {
            if (this._focusShowing === item)
                this._focusShowing = null;
            this._syncFocusLabel();
        });
        item.child.connect('key-press-event', (_child, event) => this._onKeyPress(event));
        // An unpinned app's item goes with no key-focus-out.
        item.connect('destroy', () => {
            for (const key of ['_focusItem', '_focusShowing', '_menuItem']) {
                if (this[key] === item)
                    this[key] = null;
            }
        });
    }

    // As the panel's Escape: key focus leaves the dock, and with it the name; the overview still closes.
    _onKeyPress(event) {
        if (event.get_key_symbol() !== Clutter.KEY_Escape)
            return Clutter.EVENT_PROPAGATE;
        global.stage.set_key_focus(null);
        return Main.overview.visible ? Clutter.EVENT_PROPAGATE : Clutter.EVENT_STOP;
    }

    // One name at a time: a hover elsewhere, an open menu or a hidden dock takes the focused item's.
    _syncFocusLabel() {
        const item = this._focusItem;
        if (!item)
            return;
        const hovered = this._labelledItems().find(i => i.child.hover) ?? null;
        const shown = item.child.mapped && !this._slidOut;
        if ((hovered && hovered !== item) || this._menuItem || !shown) {
            if (this._focusShowing === item)
                item.hideLabel();
            this._focusShowing = null;
        } else if (this._focusShowing !== item && hovered !== item) {
            this._focusShowing = item;
            item.showLabel();
        }
    }

    _labelledItems() {
        return [...this._box.get_children(), this._showAppsIcon, this._trash].filter(i => i.child && i.label);
    }

    // A hover on the focused item leaves its label up as it is: no second fade in, none out.
    _syncLabel(item, appIcon) {
        if (item !== this._focusShowing)
            super._syncLabel(item, appIcon);
        this._syncFocusLabel();
    }

    _itemMenuStateChanged(item, opened) {
        super._itemMenuStateChanged(item, opened);
        this._menuItem = opened ? item : null;
        this._syncFocusLabel();
    }

    get tailItems() {
        return {separator: this._tailSeparator, showApps: this._showAppsIcon, trash: this._trash};
    }

    setIconSize(size) {
        this._fixedIconSize = size;
        this._adjustIconSize();
    }

    setTrashVisible(visible) {
        this._trash.visible = visible;
    }

    setRunningIndicators(shown) {
        if (shown)
            this.remove_style_class_name(NO_INDICATORS_STYLE_CLASS);
        else
            this.add_style_class_name(NO_INDICATORS_STYLE_CLASS);
    }

    _liftOnHover(hoverActor, iconActor) {
        hoverActor.connect('notify::hover', () => {
            const {scaleFactor} = St.ThemeContext.get_for_stage(global.stage);
            iconActor.ease({
                translation_y: hoverActor.hover ? -LIFT_PX * scaleFactor : 0,
                duration: LIFT_MS,
                mode: Clutter.AnimationMode.EASE_OUT_CUBIC,
            });
        });
    }

    _createAppItem(app) {
        const item = super._createAppItem(app);
        this._liftOnHover(item.child, item.child.icon);
        item.label.add_style_class_name('apex-dock-label');
        this._nameOnFocus(item);
        return item;
    }

    // Upstream fits the icons to the overview's width; the dock's size is the user's.
    _adjustIconSize() {
        if (!this._trash)
            return;
        const items = this._box.get_children()
            .filter(actor => actor.child?._delegate?.icon && !actor.animatingOut);
        items.push(this._showAppsIcon, this._trash);
        const changed = this.iconSize !== this._fixedIconSize;
        this.iconSize = this._fixedIconSize;
        for (const item of items)
            item.child._delegate.icon.setIconSize(this.iconSize);
        if (changed)
            this.emit('icon-size-changed');
    }
});
