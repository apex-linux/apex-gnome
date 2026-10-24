// SPDX-License-Identifier: GPL-3.0-or-later
//
// The fixture typelib's Shell, plus a WindowTracker whose focus the probe sets, a BlurEffect
// and an AppSystem that knows a few apps, one of them in a folder.

import Shell from 'gi://Shell';

const handlers = new Map();
let nextId = 1;

const windowTracker = {
    focus_app: null,
    connect(signal, fn) {
        handlers.set(nextId, [signal, fn]);
        return nextId++;
    },
    disconnect(id) {
        handlers.delete(id);
    },
    focus(app) {
        this.focus_app = app;
        for (const [signal, fn] of [...handlers.values()]) {
            if (signal === 'notify::focus-app')
                fn();
        }
    },
};

const apps = ['Calculator', 'Characters', 'Disks', 'Disk Usage Analyzer', 'Files', 'Text Editor']
    .map(name => ({id: `${name.toLowerCase().replace(/ /g, '-')}.desktop`, name}))
    .map(({id, name}) => ({get_id: () => id, get_name: () => name}));

const appSystem = {
    get_default: () => ({lookup_app: id => apps.find(app => app.get_id() === id) ?? null}),
    search: query => [apps.filter(app => app.get_name().toLowerCase().includes(query.toLowerCase()))
        .map(app => app.get_id())],
};

// ShellBlurEffect with patch 0003's properties, as the glass feature sets them.
class BlurEffect {
    constructor(props) {
        Object.assign(this, {enabled: true, radius: 0, saturation: 1, corner_radius: 0}, props);
    }

    set(props) {
        Object.assign(this, props);
    }
}

const stubs = {
    WindowTracker: {get_default: () => windowTracker},
    AppSystem: appSystem,
    BlurEffect,
    BlurMode: {ACTOR: 0, BACKGROUND: 1},
};

export default new Proxy(Shell, {
    get: (target, name) => stubs[name] ?? target[name],
});
