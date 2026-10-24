// SPDX-License-Identifier: GPL-2.0-or-later
//
// The stock providers Spotlight queries: upstream's app search, and the remote providers
// its sections draw (gnome-calculator, gnome-control-center, nautilus).

import Gio from 'gi://Gio';

import * as AppDisplay from '../../appDisplay.js';
import * as RemoteSearch from '../../remoteSearch.js';
import * as SystemActions from '../../../misc/systemActions.js';
import {SECTIONS} from './search.js';

const SEARCH_PROVIDERS_SCHEMA = 'org.gnome.desktop.search-providers';

// Upstream draws app results as icons, which activate themselves.
class AppProvider extends AppDisplay.AppSearchProvider {
    async getResultMetas(ids, cancellable) {
        const metas = await super.getResultMetas(ids, cancellable);
        return metas.map(meta => ({
            ...meta,
            description: this._appSys.lookup_app(meta.id)?.get_description() ?? '',
        }));
    }

    activateResult(id) {
        const app = this._appSys.lookup_app(id);
        if (app)
            app.activate();
        else
            SystemActions.getDefault().activateAction(id);
    }
}

export function load() {
    const wanted = new Set(SECTIONS.map(s => s.provider));
    const remote = RemoteSearch.loadRemoteSearchProviders(
        new Gio.Settings({schema_id: SEARCH_PROVIDERS_SCHEMA}));
    return new Map([
        ['applications', new AppProvider()],
        ...remote.filter(p => wanted.has(p.id)).map(p => [p.id, p]),
    ]);
}
