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
        const sensitive = update.state === Update.STAGED;
        this.switch = new PopupMenu.Switch(true);
        this.switch.reactive = sensitive;
        this._button = new St.Button({
            style_class: 'apex-update-card-switch', child: this.switch, can_focus: sensitive,
            reactive: sensitive, accessible_name: TITLE, y_align: Clutter.ActorAlign.CENTER,
        });
        this._button.connect('clicked', () => this.setOn(!this.switch.state));
        this._button.connect('style-changed', () => this._followOpacity());
        this.add_child(this._button);
        this.switch.connect('notify::state', () => this.emit('switched'));
    }

    // St has no opacity in CSS: an insensitive switch takes the sheet's -apex-opacity.
    _followOpacity() {
        const [found, opacity] = this._button.get_theme_node().lookup_double('-apex-opacity', false);
        this._button.opacity = Math.round((found ? opacity : 1) * 255);
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
