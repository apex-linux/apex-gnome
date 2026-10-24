// SPDX-License-Identifier: GPL-2.0-or-later
//
// One app indicator in the bar: its glyph, the attention dot, and what each click does.

import Clutter from 'gi://Clutter';
import St from 'gi://St';

import * as Main from '../../main.js';
import * as PanelMenu from '../../panelMenu.js';
import * as PopupMenu from '../../popupMenu.js';
import {fillMenu, MenuClient} from './dbusmenu.js';
import {glyphSource, newGlyph} from './icon.js';
import {Item} from './item.js';

const SCROLL_STEP = 120;
const GLYPH_STYLE_CLASS = 'apex-indicator-icon';

export class Indicator {
    constructor(bus, id, busName, path) {
        this.id = id;
        this.onChange = () => {};
        this._bus = bus;
        this._client = null;
        this._menu = null;
        this._updateMenu = null;

        // A panel button like the others, so the bar's pill rules size it.
        this.button = new PanelMenu.Button(0.5, '', true);
        this.button.add_style_class_name('apex-indicator');
        this._glyph = newGlyph(GLYPH_STYLE_CLASS);
        this._dot = new St.Widget({
            style_class: 'apex-indicator-dot',
            x_align: Clutter.ActorAlign.END,
            y_align: Clutter.ActorAlign.START,
            x_expand: true,
            y_expand: true,
            visible: false,
        });
        const pill = new St.Widget({style_class: 'apex-indicator-pill', layout_manager: new Clutter.BinLayout()});
        pill.add_child(this._glyph);
        pill.add_child(this._dot);
        this.button.add_child(pill);
        const click = new Clutter.ClickGesture({required_button: 0});
        click.connect('recognize', gesture => this._clicked(gesture.get_button()));
        this.button.add_action(click);
        const scroll = new Clutter.ScrollController({
            flags: Clutter.ScrollControllerFlags.DISCRETE |
                Clutter.ScrollControllerFlags.SCROLL_VERTICAL | Clutter.ScrollControllerFlags.SCROLL_HORIZONTAL,
        });
        scroll.connect('scroll', (_controller, _sprite, _source, dx, dy) => this._scrolled(dx, dy));
        this.button.add_action(scroll);

        this.item = new Item(bus, busName, path, () => this._sync());
    }

    get shown() {
        return this.item.props.Status !== 'Passive';
    }

    get title() {
        return this.item.title;
    }

    get attention() {
        return this.item.props.Status === 'NeedsAttention';
    }

    newGlyph() {
        const glyph = newGlyph(GLYPH_STYLE_CLASS);
        glyph.setSource(this._glyphSource());
        return glyph;
    }

    _glyphSource() {
        return glyphSource(this.item.props, St.ThemeContext.get_for_stage(global.stage).scale_factor);
    }

    _sync() {
        const {props} = this.item;
        this._glyph.setSource(this._glyphSource());
        this._dot.visible = this.attention;
        this.button.accessible_name = this.title;
        if (props.Menu !== (this._client?.path ?? '')) {
            this._destroyMenu();
            this._client?.destroy();
            this._client = props.Menu && props.Menu !== '/'
                ? new MenuClient(this._bus, this.item.busName, props.Menu, changed => this._menuChanged(changed))
                : null;
        }
        this.onChange(this);
    }

    _point() {
        const [x, y] = this.button.get_transformed_position();
        const [width, height] = this.button.get_transformed_size();
        return [Math.round(x + width / 2), Math.round(y + height)];
    }

    _clicked(mouseButton) {
        const [x, y] = this._point();
        if (mouseButton === Clutter.BUTTON_MIDDLE)
            this.item.secondaryActivate(x, y);
        else if (mouseButton === Clutter.BUTTON_SECONDARY || this.item.props.ItemIsMenu)
            this.openMenu(this.button);
        else
            this.item.activate(x, y);
    }

    _scrolled(dx, dy) {
        if (dy !== 0)
            this.item.scroll(Math.round(-dy * SCROLL_STEP), 'vertical');
        else if (dx !== 0)
            this.item.scroll(Math.round(-dx * SCROLL_STEP), 'horizontal');
        return Clutter.EVENT_STOP;
    }

    // From the bar its menu hangs under its own button; from the overflow menu, under
    // the overflow button.
    openMenu(source) {
        if (!this._client) {
            const [x, y] = this._point();
            if (source === this.button)
                this.item.contextMenu(x, y);
            else
                this.item.activate(x, y);
            return;
        }
        if (this._menu?.sourceActor !== source) {
            this._destroyMenu();
            this._menu = new PopupMenu.PopupMenu(source, 0.5, St.Side.TOP);
            this._menu.actor.add_style_class_name('panel-menu');
            this._menu.actor.add_style_class_name('apex-indicator-menu');
            Main.uiGroup.add_child(this._menu.actor);
            this._menu.actor.hide();
            Main.panel.menuManager.addMenu(this._menu);
            this._menu.connect('open-state-changed', (_menu, open) => this._menuOpened(open));
        }
        this._updateMenu = fillMenu(this._menu, this.title, this._client);
        this._client.aboutToShow(0);
        if (!this._menu.isOpen)
            this._menu.toggle();
    }

    get menuOpen() {
        return this._menu?.isOpen ?? false;
    }

    _menuOpened(open) {
        this._client?.event(0, open ? 'opened' : 'closed');
        if (this._menu.sourceActor !== this.button)
            return;
        if (open)
            this.button.add_style_pseudo_class('checked');
        else
            this.button.remove_style_pseudo_class('checked');
    }

    _menuChanged(changed) {
        if (!this.menuOpen)
            return;
        if (changed === null || !this._updateMenu(changed))
            this._updateMenu = fillMenu(this._menu, this.title, this._client);
    }

    _destroyMenu() {
        if (!this._menu)
            return;
        this._menu.close();
        Main.panel.menuManager.removeMenu(this._menu);
        this._menu.destroy();
        this._menu = null;
        this._updateMenu = null;
    }

    destroy() {
        this._destroyMenu();
        this._client?.destroy();
        this._client = null;
        this.item.destroy();
        this.button.destroy();
    }
}
