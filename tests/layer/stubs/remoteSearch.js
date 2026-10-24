// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/remoteSearch.js: the remote providers, faked, plus one
// Spotlight draws no section for.

import {Provider} from './searchProviders.js';

export function loadRemoteSearchProviders(settings) {
    return settings.get_strv('sort-order').concat('org.gnome.Characters.desktop').map(id => new Provider(id));
}
