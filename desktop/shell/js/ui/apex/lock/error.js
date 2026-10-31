// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 20's wrong password: while the prompt's error shows, the field takes the error ring.
// A fingerprint error hides the message for the hint's line, so it rings nothing.

import {ERROR_CLASS} from './fingerprint.js';

const RING_CLASS = 'apex-lock-error';

export function followPrompt(dialog, prompt) {
    const message = prompt._message;
    const follow = () => {
        if (message.visible && message.opacity > 0 && message.text && message.has_style_class_name(ERROR_CLASS))
            dialog.add_style_class_name(RING_CLASS);
        else
            dialog.remove_style_class_name(RING_CLASS);
    };
    message.connectObject('notify::text', follow, 'notify::opacity', follow, 'notify::visible', follow, prompt);
    prompt.connect('destroy', () => dialog.remove_style_class_name(RING_CLASS));
    follow();
}
