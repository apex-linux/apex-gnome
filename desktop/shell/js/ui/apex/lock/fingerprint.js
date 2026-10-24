// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 20's fingerprint states in the hint's line, driven by GDM's gdm-fingerprint conversation.

const FINGERPRINT_SERVICE = 'gdm-fingerprint';
// authPrompt.js's setMessage() gives an error this class, before this module hears the message.
const ERROR_CLASS = 'login-dialog-message-warning';
const FAILED_CLASS = 'apex-lock-hint-failed';
const INDICATOR_HIDDEN = 0;
const INDICATOR_SHOWN = 255;

export const State = {PASSWORD: 'password', SCAN: 'scan', FAILED: 'failed'};

export function hintText(state) {
    if (state === State.SCAN)
        return _('Or touch the fingerprint reader');
    if (state === State.FAILED)
        return _('Fingerprint not recognized. Try again.');
    return _('Press Enter to unlock');
}

export function stateAfter(state, message, isError) {
    if (message?.serviceName !== FINGERPRINT_SERVICE || !message.text)
        return state;
    return isError ? State.FAILED : State.SCAN;
}

function _show(dialog, hint, state) {
    hint.label.text = hintText(state);
    hint.glyph.visible = state !== State.PASSWORD;
    if (state === State.FAILED)
        hint.line.add_style_class_name(FAILED_CLASS);
    else
        hint.line.remove_style_class_name(FAILED_CLASS);
    if (dialog._authIndicatorButton)
        dialog._authIndicatorButton.opacity = state === State.PASSWORD ? INDICATOR_SHOWN : INDICATOR_HIDDEN;
}

export function followPrompt(dialog, prompt, hint) {
    let state = State.PASSWORD;
    _show(dialog, hint, state);
    prompt._userVerifier.connectObject('show-message', verifier => {
        const message = verifier.currentMessage;
        state = stateAfter(state, message, prompt._message.has_style_class_name(ERROR_CLASS));
        prompt._message.visible = message?.serviceName !== FINGERPRINT_SERVICE;
        _show(dialog, hint, state);
    }, prompt);
    prompt.connect('destroy', () => _show(dialog, hint, State.PASSWORD));
}
