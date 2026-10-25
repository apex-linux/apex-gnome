// SPDX-License-Identifier: GPL-3.0-or-later
//
// The layer job's gjs has no Mtk typelib: run.sh points gi://Mtk here.

class Rectangle {
    constructor({x = 0, y = 0, width = 0, height = 0} = {}) {
        Object.assign(this, {x, y, width, height});
    }
}

export default {Rectangle};
