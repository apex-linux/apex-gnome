// SPDX-License-Identifier: GPL-2.0-or-later
//
// "Enter Password" for PAM's exact "Password:" only; every other question as PAM asks it.

import * as Hooks from '../hooks.js';

export const PAM_PASSWORD_QUESTION = 'Password:';

let _enabled = false;

export function questionText(stock, question) {
    if (!_enabled)
        return stock;
    return question === PAM_PASSWORD_QUESTION ? _('Enter Password') : question;
}

export function configure(featureName) {
    Hooks.provide(featureName, 'auth-prompt-question', questionText);
}

export function enable() {
    _enabled = true;
}

export function disable() {
    _enabled = false;
}
