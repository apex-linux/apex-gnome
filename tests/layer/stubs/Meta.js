// SPDX-License-Identifier: GPL-3.0-or-later
//
// The fixture typelib's Meta, plus the Barrier the dock's intellihide builds.

import Meta from 'gi://Meta';

class Barrier {
    constructor(params) {
        Object.assign(this, params);
    }

    destroy() {
        this.destroyed = true;
    }
}

const BarrierDirection = {POSITIVE_X: 1, POSITIVE_Y: 2, NEGATIVE_X: 4, NEGATIVE_Y: 8};

export default new Proxy(Meta, {
    get: (target, name) => ({Barrier, BarrierDirection})[name] ?? target[name],
});
