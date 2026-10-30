// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/misc/loginManager.js: logind's PrepareForSleep as LoginManager relays it.

const handlers = new Map();
let nextId = 1;

const manager = {
    preparingForSleep: false,
    connectObject(signal, fn, owner) {
        const id = nextId++;
        handlers.set(id, [signal, fn]);
        owner.connect('destroy', () => handlers.delete(id));
    },
};

export function getLoginManager() {
    return manager;
}

// The flag first, then the signal, as LoginManagerSystemd does; before the listeners, SHIELD plays
// ScreenShield's own handler, which connected at startup.
export function prepareForSleep(aboutToSuspend, shield = () => {}) {
    manager.preparingForSleep = aboutToSuspend;
    shield(aboutToSuspend);
    for (const [signal, fn] of [...handlers.values()]) {
        if (signal === 'prepare-for-sleep')
            fn(manager, aboutToSuspend);
    }
}
