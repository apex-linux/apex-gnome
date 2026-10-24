// SPDX-License-Identifier: GPL-2.0-or-later
//
// Any feature registers its glass here, whether or not the glass feature runs: the actor's
// sheet gives -apex-glass-blur and -apex-glass-saturation, the glass feature does the rest.

const _surfaces = new Map();
const _listeners = new Set();

function _notify(change, surface) {
    for (const listener of [..._listeners])
        listener[change](surface);
}

export function unregister(actor) {
    const surface = _surfaces.get(actor);
    if (!surface)
        return;
    _surfaces.delete(actor);
    actor.disconnect(surface.destroyId);
    _notify('removed', surface);
}

// paused() is a reason besides being unmapped to leave the blur off; pausedChanged lists
// the [emitter, signal] pairs after which it may answer otherwise. A second call replaces opts.
export function register(actor, opts = {}) {
    unregister(actor);
    const surface = {
        actor, name: opts.name ?? actor.name ?? actor.constructor.name, mode: opts.mode ?? 'background',
        paused: opts.paused ?? (() => false), pausedChanged: opts.pausedChanged ?? [],
        destroyId: actor.connect('destroy', () => unregister(actor)),
    };
    _surfaces.set(actor, surface);
    _notify('added', surface);
}

export function surfaces() {
    return [..._surfaces.values()];
}

export function listen(listener) {
    _listeners.add(listener);
    return () => _listeners.delete(listener);
}
