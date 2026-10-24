// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/appDisplay.js: upstream's app search and app icons, faked,
// over an app system that knows the fake apps.

import {ITEMS, Provider} from './searchProviders.js';

const apps = new Map(ITEMS.applications.map(([id, , description]) => [id, {
    get_description: () => description,
    activate: () => printerr(`probe: spotlight.launched=${id}`),
}]));

export class AppSearchProvider extends Provider {
    constructor() {
        super('applications');
        this._appSys = {lookup_app: id => apps.get(id) ?? null};
    }
}

export class AppIcon {
    constructor(app) {
        this.app = app;
        this.pseudoClasses = new Set();
    }

    add_style_pseudo_class(name) {
        this.pseudoClasses.add(name);
    }

    activate() {
        printerr(`probe: launcher.launched=${this.app.get_id()}`);
    }

    destroy() {}
}
