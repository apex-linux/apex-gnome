// SPDX-License-Identifier: GPL-3.0-or-later
//
// The layer job's gjs has no Graphene typelib: run.sh points gi://Graphene here.

class Point {
    constructor({x, y}) {
        this.x = x;
        this.y = y;
    }
}

export default {Point};
