// SPDX-License-Identifier: GPL-3.0-or-later
//
// gjs outside the shell has no St: run.sh points the features' gi://St imports here.

import GLib from 'gi://GLib';

const scaleFactor = Number(GLib.getenv('PROBE_SCALE') ?? '1');

class Label {
    constructor(params) {
        Object.assign(this, params);
    }
}

class Bin extends Label {}
class Icon extends Label {}

export default {
    Bin,
    Icon,
    Label,
    ThemeContext: {get_for_stage: () => ({scale_factor: scaleFactor})},
};
