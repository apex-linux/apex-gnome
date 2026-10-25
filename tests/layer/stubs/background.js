// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/background.js: the BackgroundManager the overview's thumbnails use.

class BackgroundContent {
    constructor() {
        this.rounded_clip_radius = 0;
        this.bounds = null;
    }

    set_rounded_clip_bounds(rect) {
        this.bounds = rect;
    }
}

export const managers = [];

export class BackgroundManager {
    constructor(params) {
        managers.push(this);
        Object.assign(this, params);
        this.backgroundActor = {content: new BackgroundContent()};
        this.destroyed = false;
        this._handlers = [];
    }

    connect(signal, fn) {
        this._handlers.push([signal, fn]);
    }

    destroy() {
        this.destroyed = true;
    }
}
