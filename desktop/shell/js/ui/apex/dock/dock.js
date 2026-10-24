// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's dock: upstream's Dash at a fixed icon size, its apps followed by a separator,
// a full-colour Show Apps tile and Trash, each icon lifted while hovered.

import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Dash from '../../dash.js';
import {TrashItem} from './trash.js';

const LIFT_PX = 6;
const LIFT_MS = 180;
const SHOW_APPS_FALLBACK_ICON = 'view-app-grid-symbolic';
const NO_INDICATORS_STYLE_CLASS = 'apex-dock-no-indicators';

export const ApexDock = GObject.registerClass(
class ApexDock extends Dash.Dash {
    _init(iconSize) {
        this._fixedIconSize = iconSize;
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
        }
        this._adjustIconSize();
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
