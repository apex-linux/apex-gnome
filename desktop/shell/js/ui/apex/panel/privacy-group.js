// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: the privacy indicators (remote access, camera, microphone, location) sit in an
// orange group at the start of the status pill, with white glyphs, while any of them shows.

import Clutter from 'gi://Clutter';
import St from 'gi://St';

const PRIVACY_INDICATORS = ['_remoteAccess', '_camera', '_volumeInput', '_location'];
const IN_USE_CLASS = 'apex-privacy-in-use';

export class PrivacyGroup {
    constructor(quickSettings) {
        this._box = quickSettings._indicators;
        const children = this._box.get_children();
        this._members = PRIVACY_INDICATORS
            .map(field => quickSettings[field])
            .filter(indicator => indicator && children.includes(indicator))
            .map(indicator => ({indicator, index: children.indexOf(indicator), visibleId: 0}))
            .sort((a, b) => a.index - b.index);
        this.actor = new St.BoxLayout({
            style_class: 'apex-privacy-group',
            name: 'apexPrivacyGroup',
            y_align: Clutter.ActorAlign.CENTER,
        });
        for (const member of this._members) {
            this._box.remove_child(member.indicator);
            this.actor.add_child(member.indicator);
            member.visibleId = member.indicator.connect('notify::visible', () => this._sync());
        }
        this._box.insert_child_at_index(this.actor, 0);
        this._sync();
    }

    get inUse() {
        return this._members.some(({indicator}) => indicator.visible);
    }

    _sync() {
        const inUse = this.inUse;
        this.actor.visible = inUse;
        if (inUse)
            this._box.add_style_class_name(IN_USE_CLASS);
        else
            this._box.remove_style_class_name(IN_USE_CLASS);
    }

    destroy() {
        for (const {indicator, visibleId} of this._members) {
            indicator.disconnect(visibleId);
            this.actor.remove_child(indicator);
        }
        this._box.remove_child(this.actor);
        for (const {indicator, index} of this._members)
            this._box.insert_child_at_index(indicator, index);
        this._box.remove_style_class_name(IN_USE_CLASS);
        this.actor.destroy();
    }
}
