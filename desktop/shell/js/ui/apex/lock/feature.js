// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's lock screen, one feature for disabled-features ('lock'). Every part changes what
// the lock screen shows; unlocking stays GDM's, and only PAM's success leads to it.

import * as Avatar from './avatar.js';
import * as Background from './background.js';
import * as Question from './question.js';
import * as Stage from './stage.js';

const PARTS = [Background, Stage, Question, Avatar];

export function configure(featureName) {
    for (const part of PARTS)
        part.configure(featureName);
}

export function enable() {
    for (const part of PARTS)
        part.enable();
}

export function disable() {
    for (const part of [...PARTS].reverse())
        part.disable();
}
