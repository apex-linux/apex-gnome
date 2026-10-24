// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's end-session dialog (board 14), through patch 0018's hook: stock's icon in a circle
// above the title, Restart between Cancel and Power Off, and the theme's gap and widths.

import Clutter from 'gi://Clutter';
import St from 'gi://St';

import * as Hooks from '../hooks.js';

export const ICON_STYLE_CLASS = 'apex-end-session-icon';
export const RESTART_STYLE_CLASS = 'apex-end-session-restart';
export const ROW_STYLE_CLASS = 'apex-end-session-row';

const POWER_OFF = 'ConfirmedShutdown';
const REBOOT = 'ConfirmedReboot';
const STOCK_BUTTON_SPACING = 12;

let _enabled = false;
let _icon = null;
let _row = null;
let _rowStyleId = 0;

function _setIcon(dialog, iconName) {
    if (!iconName) {
        _icon?.destroy();
        return;
    }
    if (!_icon) {
        _icon = new St.Bin({
            style_class: ICON_STYLE_CLASS,
            x_align: Clutter.ActorAlign.CENTER,
            child: new St.Icon({x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER}),
        });
        _icon.connect('destroy', () => (_icon = null));
        dialog.contentLayout.insert_child_below(_icon, null);
    }
    _icon.child.icon_name = iconName;
}

// Stock's own reboot path: the dialog closes, then confirms, as its Restart button does.
function _addRestart(dialog) {
    const button = dialog.addButton({
        label: C_('button', 'Restart'),
        action: () => {
            const id = dialog.connect('closed', () => {
                dialog.disconnect(id);
                dialog._confirm(REBOOT).catch(logError);
            });
            dialog.close(true);
        },
    });
    button.add_style_class_name(RESTART_STYLE_CLASS);
    const [cancel] = dialog.buttonLayout.get_children();
    dialog.buttonLayout.set_child_above_sibling(button, cancel);
}

// Clutter.BoxLayout's spacing is unreachable from CSS: the row takes the theme's.
function _followRowStyle() {
    const node = _row.peek_theme_node();
    if (!node)
        return;
    const [found, spacing] = node.lookup_length('spacing', false);
    if (found)
        _row.layout_manager.spacing = spacing;
}

function _styleRow(row, powerOff) {
    if (!_row) {
        _row = row;
        _rowStyleId = row.connect('style-changed', _followRowStyle);
    }
    row.layout_manager.homogeneous = !powerOff;
    if (powerOff)
        row.add_style_class_name(ROW_STYLE_CLASS);
    else
        row.remove_style_class_name(ROW_STYLE_CLASS);
    _followRowStyle();
}

function _restoreRow() {
    if (!_row)
        return;
    _row.disconnect(_rowStyleId);
    _row.remove_style_class_name(ROW_STYLE_CLASS);
    _row.layout_manager.homogeneous = true;
    _row.layout_manager.spacing = STOCK_BUTTON_SPACING;
    for (const button of _row.get_children()) {
        if (button.has_style_class_name(RESTART_STYLE_CLASS))
            button.destroy();
    }
    _row = null;
    _rowStyleId = 0;
}

function _apply(dialog, dialogContent) {
    if (!_enabled)
        return;
    const powerOff = dialogContent.confirmButtons.some(b => b.signal === POWER_OFF);
    _setIcon(dialog, dialogContent.iconName);
    if (powerOff)
        _addRestart(dialog);
    _styleRow(dialog.buttonLayout, powerOff);
}

export function configure(featureName) {
    Hooks.provide(featureName, 'end-session-buttons', _apply);
}

// The dialog builds its buttons each time it opens: the hook covers the next one.
export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
    _icon?.destroy();
    _restoreRow();
}
