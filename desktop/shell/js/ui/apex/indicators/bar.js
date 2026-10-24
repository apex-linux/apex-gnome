// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the app indicators sit left of the search button, after a thin divider, in the
// order the items registered. Up to four show; with more, three show and "‹ +N" lists the rest.

import Clutter from 'gi://Clutter';
import St from 'gi://St';

import * as Main from '../../main.js';
import * as PanelMenu from '../../panelMenu.js';
import * as PopupMenu from '../../popupMenu.js';

const MAX_SHOWN = 4;
const SEARCH_ROLE = 'apex-search';

export class Bar {
    constructor() {
        this._indicators = [];
        this._box = new St.BoxLayout({style_class: 'apex-indicators', name: 'apexIndicators'});
        this._divider = new St.Widget({
            style_class: 'apex-indicators-divider',
            y_align: Clutter.ActorAlign.CENTER,
        });

        this._countLabel = new St.Label({
            style_class: 'apex-indicators-overflow-count',
            y_align: Clutter.ActorAlign.CENTER,
        });
        const pill = new St.BoxLayout({style_class: 'apex-indicators-overflow-pill'});
        pill.add_child(new St.Icon({icon_name: 'go-previous-symbolic', style_class: 'apex-indicator-icon'}));
        pill.add_child(this._countLabel);
        this._overflow = new PanelMenu.Button(0.5, '', true);
        this._overflow.add_style_class_name('apex-indicators-overflow');
        this._overflow.add_child(pill);
        const click = new Clutter.ClickGesture();
        click.connect('recognize', () => this._toggleOverflow());
        this._overflow.add_action(click);
        this._box.add_child(this._overflow.container);

        this._overflowMenu = new PopupMenu.PopupMenu(this._overflow, 0.5, St.Side.TOP);
        this._overflowMenu.actor.add_style_class_name('panel-menu');
        this._overflowMenu.actor.add_style_class_name('apex-indicators-overflow-menu');
        this._overflowMenu.connect('open-state-changed', (_menu, open) => {
            if (open)
                this._overflow.add_style_pseudo_class('checked');
            else
                this._overflow.remove_style_pseudo_class('checked');
        });
        Main.uiGroup.add_child(this._overflowMenu.actor);
        this._overflowMenu.actor.hide();
        Main.panel.menuManager.addMenu(this._overflowMenu);

        const {quickSettings} = Main.panel.statusArea;
        const parent = quickSettings.container.get_parent();
        const children = parent.get_children();
        const before = [Main.panel.statusArea[SEARCH_ROLE]?.container, quickSettings.container]
            .find(container => children.includes(container));
        const index = children.indexOf(before);
        parent.insert_child_at_index(this._box, index);
        parent.insert_child_at_index(this._divider, index + 1);
        this._lockId = Main.sessionMode.connect('updated', () => this._layout());
        this._layout();
    }

    add(indicator) {
        this._indicators.push(indicator);
        this._box.insert_child_below(indicator.button.container, this._overflow.container);
        indicator.onChange = () => this._layout();
        this._layout();
    }

    remove(id) {
        const indicator = this._indicators.find(i => i.id === id);
        if (!indicator)
            return;
        this._indicators.splice(this._indicators.indexOf(indicator), 1);
        indicator.destroy();
        this._layout();
    }

    _layout() {
        const shown = this._indicators.filter(i => i.shown);
        const overflowing = shown.length > MAX_SHOWN;
        const inBar = overflowing ? shown.slice(0, MAX_SHOWN - 1) : shown;
        this._hidden = overflowing ? shown.slice(MAX_SHOWN - 1) : [];
        this._indicators.forEach(i => {
            i.button.container.visible = inBar.includes(i);
        });
        this._overflow.container.visible = overflowing;
        this._countLabel.text = `+${this._hidden.length}`;
        this._overflow.accessible_name = `${this._hidden.length} more app indicators`;
        const visible = shown.length > 0 && !Main.sessionMode.isLocked;
        this._box.visible = visible;
        this._divider.visible = visible;
        if (!overflowing)
            this._overflowMenu.close();
    }

    _toggleOverflow() {
        if (this._overflowMenu.isOpen) {
            this._overflowMenu.close();
            return;
        }
        this._overflowMenu.removeAll();
        for (const indicator of this._hidden) {
            const row = new PopupMenu.PopupBaseMenuItem({style_class: 'apex-indicators-overflow-row'});
            row.add_child(indicator.newGlyph());
            row.add_child(new St.Label({text: indicator.title, x_expand: true, y_align: Clutter.ActorAlign.CENTER}));
            row.add_child(new St.Icon({icon_name: 'go-next-symbolic', style_class: 'apex-indicators-overflow-chevron'}));
            row.connect('activate', () => {
                this._overflowMenu.close();
                indicator.openMenu(this._overflow);
            });
            this._overflowMenu.addMenuItem(row);
        }
        this._overflowMenu.toggle();
    }

    destroy() {
        Main.sessionMode.disconnect(this._lockId);
        this._indicators.forEach(i => i.destroy());
        this._indicators = [];
        Main.panel.menuManager.removeMenu(this._overflowMenu);
        this._overflowMenu.destroy();
        this._divider.destroy();
        this._box.destroy();
    }
}
