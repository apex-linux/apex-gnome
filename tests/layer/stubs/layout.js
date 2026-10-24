// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/layout.js: the PressureBarrier the dock's intellihide uses.

const printFact = (key, value) => printerr(`probe: ${key}=${value}`);

export class PressureBarrier {
    constructor(threshold, timeout) {
        printFact('pressure-barrier', `threshold=${threshold} timeout=${timeout}`);
        this.barriers = [];
        this._handlers = [];
        globalThis.PROBE_PRESSURE = this;
    }

    connect(signal, fn) {
        this._handlers.push([signal, fn]);
    }

    addBarrier(barrier) {
        this.barriers.push(barrier);
    }

    removeBarrier(barrier) {
        this.barriers.splice(this.barriers.indexOf(barrier), 1);
    }

    trigger() {
        this._handlers.filter(([s]) => s === 'trigger').forEach(([, fn]) => fn());
    }

    destroy() {
        this.destroyed = true;
    }
}
