// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's end-session dialog (board 14), through patch 0018's hook: stock's icon in a circle,
// Restart between Cancel and Power Off, the theme's gap and widths, and the update card.

import Clutter from 'gi://Clutter';
import St from 'gi://St';

import * as Hooks from '../hooks.js';
import {UpdateCard} from './card.js';
import * as Update from './update.js';

export const ICON_STYLE_CLASS = 'apex-end-session-icon';
export const RESTART_STYLE_CLASS = 'apex-end-session-restart';
export const ROW_STYLE_CLASS = 'apex-end-session-row';

const POWER_OFF = 'ConfirmedShutdown';
const REBOOT = 'ConfirmedReboot';
const STOCK_BUTTON_SPACING = 12;
export const RESTART_UPDATE_LABEL = 'Restart & Update';

let _enabled = false;
let _icon = null;
let _row = null;
let _rowStyleId = 0;
let _card = null;
let _opening = 0;
let _guarded = null;
let _staleConfirms = 0;
let _stockConfirm = null;
const _labels = new Map();

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
    return button;
}

function _relabel(restarts) {
    for (const button of restarts) {
        if (!_labels.has(button))
            _labels.set(button, button.label);
        button.label = _card?.on ? RESTART_UPDATE_LABEL : _labels.get(button);
    }
}

// A pressed button closes the dialog before stock confirms: Apply runs first, and on a failure
// the dialog stays open, its press's confirmation skipped. The countdown goes ahead regardless.
function _guard(dialog) {
    if (_guarded)
        return;
    _stockConfirm ??= dialog._confirm;
    const saved = {close: dialog.close, _confirm: _stockConfirm};
    const {close, _confirm: confirm} = saved;
    dialog.close = function (skipSignal) {
        if (!skipSignal || !_enabled || !_card?.wantsApply)
            return close.call(this, skipSignal);
        this._stopTimer();
        const card = _card;
        card.apply().then(() => close.call(this, true), error => {
            _staleConfirms++;
            card.fail(error);
        });
        return undefined;
    };
    dialog._confirm = async function (signal) {
        if (_staleConfirms > 0) {
            _staleConfirms--;
            if (!_guarded && _staleConfirms === 0)
                this._confirm = confirm;
            return undefined;
        }
        if (_enabled && _card?.wantsApply)
            await _card.apply().catch(logError);
        return confirm.call(this, signal);
    };
    const closedId = dialog.connect('closed', () => _unguard());
    _guarded = {dialog, saved, closedId};
}

// On close and on disable. A failed press's stale confirmation is still skipped after either.
function _unguard() {
    if (!_guarded)
        return;
    const {dialog, saved, closedId} = _guarded;
    dialog.disconnect(closedId);
    dialog.close = saved.close;
    if (_staleConfirms === 0)
        dialog._confirm = saved._confirm;
    _guarded = null;
}

function _clearCard() {
    _card?.destroy();
    _card = null;
    _labels.clear();
}

function _restoreLabels() {
    for (const [button, label] of _labels)
        button.label = label;
}

// Only Power Off and Restart, once Update1 answers in time; the dialog opens without waiting.
function _offerUpdate(dialog, restarts) {
    const opening = ++_opening;
    const closedId = dialog.connect('closed', () => {
        dialog.disconnect(closedId);
        if (opening === _opening)
            _opening++;
    });
    Update.read().then(update => {
        if (!update || !_enabled || opening !== _opening)
            return;
        _card = new UpdateCard(update);
        _card.connect('destroy', card => _card === card && (_card = null));
        _card.connect('switched', () => _relabel(restarts));
        dialog.contentLayout.insert_child_above(_card, dialog._messageDialogContent);
        _relabel(restarts);
        Update.changes().then(text => _card?.setChanges(text), () => {});
    }).catch(logError);
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
    const signals = dialogContent.confirmButtons.map(b => b.signal);
    const powerOff = signals.includes(POWER_OFF);
    _setIcon(dialog, dialogContent.iconName);
    _clearCard();
    _staleConfirms = 0;
    _opening++;
    // Cancel, then stock's confirm buttons in order.
    const buttons = dialog.buttonLayout.get_children().slice(1);
    const restarts = signals.flatMap((signal, i) => signal === REBOOT ? [buttons[i]] : []);
    if (powerOff)
        restarts.push(_addRestart(dialog));
    _styleRow(dialog.buttonLayout, powerOff);
    if (powerOff || signals.includes(REBOOT)) {
        _guard(dialog);
        _offerUpdate(dialog, restarts);
    }
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
    _restoreLabels();
    _clearCard();
    _unguard();
    _restoreRow();
}
