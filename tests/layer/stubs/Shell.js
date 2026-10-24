// SPDX-License-Identifier: GPL-3.0-or-later
//
// The fixture typelib's Shell, plus a WindowTracker whose focus the probe sets.

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

export default new Proxy(Shell, {
    get: (target, name) => name === 'WindowTracker'
        ? {get_default: () => windowTracker}
        : target[name],
});
