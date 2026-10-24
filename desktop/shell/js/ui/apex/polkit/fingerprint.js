// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 13's fingerprint line, shown only for what PAM sends: upstream's info line, with the
// print glyph and the hint's style when the text is pam_fprintd's prompt.

import GLib from 'gi://GLib';
import St from 'gi://St';

const FINGERPRINT_GLYPH = 'auth-fingerprint-symbolic';
const FPRINTD_DOMAIN = 'fprintd';

// pam_fprintd's prompts are fprintd's pam/fingerprint-strings.h msgids, four per finger.
const FINGERS = ['finger', 'left thumb', 'left index finger', 'left middle finger', 'left ring finger',
    'left little finger', 'right thumb', 'right index finger', 'right middle finger', 'right ring finger',
    'right little finger'];
export const PROMPT_MSGIDS = FINGERS.flatMap(finger => [
    `Place your ${finger} on the fingerprint reader`,
    `Place your ${finger} on %s`,
    `Swipe your ${finger} across the fingerprint reader`,
    `Swipe your ${finger} across %s`,
]);

// In the session's locale, as pam_fprintd formats them: %s is the reader's name.
let _prompts = null;
function _promptPatterns() {
    _prompts ??= PROMPT_MSGIDS.map(msgid => {
        const [before, after = null] = GLib.dgettext(FPRINTD_DOMAIN, msgid).split('%s');
        const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        return new RegExp(`^${escape(before)}${after === null ? '' : `.+${escape(after)}`}$`);
    });
    return _prompts;
}

export function isFingerprintPrompt(text) {
    return Boolean(text) && _promptPatterns().some(prompt => prompt.test(text));
}

export function setUp(dialog) {
    const label = dialog._infoMessageLabel;
    const box = label.get_parent();
    const line = new St.BoxLayout({style_class: 'apex-polkit-info', visible: label.visible});
    const glyph = new St.Icon({
        style_class: 'apex-polkit-fingerprint-glyph',
        icon_name: FINGERPRINT_GLYPH,
        visible: false,
    });
    box.insert_child_above(line, label);
    box.remove_child(label);
    line.add_child(glyph);
    line.add_child(label);
    label.x_expand = true;

    const follow = () => {
        const fingerprint = isFingerprintPrompt(label.text);
        line.visible = label.visible;
        glyph.visible = fingerprint;
        if (fingerprint)
            line.add_style_class_name('apex-polkit-fingerprint');
        else
            line.remove_style_class_name('apex-polkit-fingerprint');
    };
    label.connectObject('notify::visible', follow, 'notify::text', follow, dialog);
    follow();
}
