// SPDX-License-Identifier: GPL-3.0-or-later
//
// The layer job's gjs has no Graphene typelib: run.sh points gi://Graphene here.

class Point {
    constructor({x, y}) {
        this.x = x;
        this.y = y;
    }
}

class Point3D extends Point {}

class Rect {
    init(x, y, width, height) {
        Object.assign(this, {x, y, width, height});
        return this;
    }

    inset(dx, dy) {
        return this.init(this.x + dx, this.y + dy, this.width - 2 * dx, this.height - 2 * dy);
    }
}

export default {Point, Point3D, Rect};
