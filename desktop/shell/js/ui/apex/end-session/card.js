// SPDX-License-Identifier: GPL-2.0-or-later

// Board 14's update card: the staged update, its versions, and the switch that applies it.

import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as PopupMenu from '../../popupMenu.js';
import * as Update from './update.js';

export const CARD_STYLE_CLASS = 'apex-update-card';
export const TITLE = 'Start the new version next time';
export const GENERIC_ERROR = 'The update could not be prepared. Software Updates in Settings has the details.';
const ICON_NAME = 'system-software-update';

export const UpdateCard = GObject.registerClass({
    Signals: {'switched': {}},
}, class UpdateCard extends St.BoxLayout {
    constructor(update) {
        super({style_class: CARD_STYLE_CLASS, x_expand: true});
        this._update = update;
        this._applied = false;
        this.add_child(new St.Icon({style_class: 'apex-update-card-icon', icon_name: ICON_NAME, y_align: Clutter.ActorAlign.CENTER}));
        const labels = new St.BoxLayout({
            style_class: 'apex-update-card-text', orientation: Clutter.Orientation.VERTICAL,
            x_expand: true, y_align: Clutter.ActorAlign.CENTER,
        });
        this.add_child(labels);
        labels.add_child(new St.Label({style_class: 'apex-update-card-title', text: TITLE}));
        this._subtitle = new St.Label({style_class: 'apex-update-card-subtitle', text: update.version});
        this._subtitle.clutter_text.line_wrap = true;
        labels.add_child(this._subtitle);
        this.switch = new PopupMenu.Switch(true);
        this._button = new St.Button({
            style_class: 'apex-update-card-switch', child: this.switch, can_focus: true,
            reactive: update.state === Update.STAGED, accessible_name: TITLE, y_align: Clutter.ActorAlign.CENTER,
        });
        this._button.connect('clicked', () => this.setOn(!this.switch.state));
        this.add_child(this._button);
        this.switch.connect('notify::state', () => this.emit('switched'));
        if (update.state === Update.READY_FOR_REBOOT)
            this._button.add_style_pseudo_class('insensitive');
    }

    get on() {
        return this.switch.state;
    }

    // "staged" with the switch on: Apply still has to arm the stage.
    get wantsApply() {
        return this._update.state === Update.STAGED && this.on && !this._applied;
    }

    get digest() {
        return this._update.digest;
    }

    setOn(on) {
        if (this._update.state === Update.STAGED)
            this.switch.state = on;
    }

    setChanges(text) {
        if (text && !this._failed)
            this._subtitle.text = `${this._update.version} · ${text}`;
    }

    async apply() {
        await Update.apply(this._update.digest);
        this._applied = true;
    }

    fail(error) {
        this._failed = true;
        this._subtitle.text = error.kind === 'PolicyDenied' && error.message ? error.message : GENERIC_ERROR;
        this.setOn(false);
    }
});
