// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the search button before the status pill. It does what Super+Space does, and
// opens the stock overview search while Spotlight is in disabled-features.

import Clutter from 'gi://Clutter';
import St from 'gi://St';

import * as Main from '../../main.js';
import * as PanelMenu from '../../panelMenu.js';
import {toggleSpotlight} from '../spotlight/feature.js';

const ROLE = 'apex-search';
const NAME = 'Search (Super+Space)';
const ICON_NAME = 'system-search-symbolic';

let _button = null;
let _tooltip = null;
let _lockId = 0;

function _sync() {
    _button.container.visible = !Main.sessionMode.isLocked;
}

function _syncTooltip() {
    if (!_button.hover) {
        _tooltip.hide();
        return;
    }
    _tooltip.show();
    const [x, y] = _button.get_transformed_position();
    const [width, height] = _button.get_transformed_size();
    const left = Math.min(x + (width - _tooltip.width) / 2, global.stage.width - _tooltip.width);
    _tooltip.set_position(Math.round(left), Math.round(y + height));
}

function _beforeTheStatusPill() {
    const {container} = Main.panel.statusArea.quickSettings;
    return container.get_parent().get_children().indexOf(container);
}

export function enable() {
    _button = new PanelMenu.Button(0.0, NAME, true);
    _button.add_style_class_name('apex-search');
    _button.add_child(new St.Bin({
        style_class: 'apex-search-pill',
        child: new St.Icon({
            icon_name: ICON_NAME,
            style_class: 'system-status-icon',
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
            x_expand: true,
        }),
    }));
    const click = new Clutter.ClickGesture();
    click.connect('recognize', () => toggleSpotlight());
    _button.add_action(click);
    Main.panel.addToStatusArea(ROLE, _button, _beforeTheStatusPill(), 'right');
    _tooltip = new St.Label({style_class: 'dash-label', text: NAME, visible: false});
    Main.layoutManager.addChrome(_tooltip);
    _button.connect('notify::hover', _syncTooltip);
    _lockId = Main.sessionMode.connect('updated', _sync);
    _sync();
}

export function configure() {}

export function disable() {
    if (_lockId)
        Main.sessionMode.disconnect(_lockId);
    _lockId = 0;
    _tooltip?.destroy();
    _tooltip = null;
    _button?.destroy();
    _button = null;
}
