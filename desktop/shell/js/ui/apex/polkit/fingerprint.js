// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 13's fingerprint line, shown only for what PAM sends: upstream's info line, with the
// print glyph and the hint's style when the text is pam_fprintd's prompt.

import GLib from 'gi://GLib';
import St from 'gi://St';

const FINGERPRINT_GLYPH = 'auth-fingerprint-symbolic';
const FPRINTD_DOMAIN = 'fprintd';

// fprintd's pam/fingerprint-strings.h: "Place your <finger> on <reader>" and its swipe form.
const FINGER = '(finger|(left|right) (thumb|(index|middle|ring|little) finger))';
const PROMPT = new RegExp(`^(Place your ${FINGER} on|Swipe your ${FINGER} across) .+$`);
const GENERIC_PROMPTS = [
    'Place your finger on the fingerprint reader',
    'Swipe your finger across the fingerprint reader',
];

export function isFingerprintPrompt(text) {
    if (!text)
        return false;
    return PROMPT.test(text) || GENERIC_PROMPTS.some(p => GLib.dgettext(FPRINTD_DOMAIN, p) === text);
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
