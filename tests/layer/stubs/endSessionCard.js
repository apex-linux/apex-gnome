// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/apex/end-session/card.js: card.js's state without its GObject widget.

import St from 'gi://St';

import * as Update from './update.js';

export class UpdateCard extends St.Widget {
    constructor(update) {
        super({style_class: 'apex-update-card'});
        Object.assign(this, {update, on: true, applied: false, subtitle: update.version});
    }

    get wantsApply() {
        return this.update.state === Update.STAGED && this.on && !this.applied;
    }

    setOn(on) {
        if (this.update.state === Update.STAGED && on !== this.on) {
            this.on = on;
            this.emit('switched');
        }
    }

    setChanges(text) {
        this.subtitle = `${this.update.version} · ${text}`;
    }

    async apply() {
        await Update.apply(this.update.digest);
        this.applied = true;
    }

    fail(error) {
        this.subtitle = error.message;
        this.setOn(false);
    }
}
