// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/appDisplay.js: upstream's app search, faked, over an
// app system that knows the fake apps.

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
