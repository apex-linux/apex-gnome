// SPDX-License-Identifier: GPL-3.0-or-later
//
// The fixture typelib's Shell, plus a WindowTracker whose focus the probe sets and a BlurEffect.

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
    BlurEffect,
    BlurMode: {ACTOR: 0, BACKGROUND: 1},
};

export default new Proxy(Shell, {
    get: (target, name) => stubs[name] ?? target[name],
});
