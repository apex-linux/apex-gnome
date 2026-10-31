// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 13's wrong-password state: while upstream's error line shows, the field takes the error ring.

const ERROR_CLASS = 'apex-polkit-error';

export function setUp(dialog) {
    const label = dialog._errorMessageLabel;
    const follow = () => {
        if (label.visible)
            dialog.add_style_class_name(ERROR_CLASS);
        else
            dialog.remove_style_class_name(ERROR_CLASS);
    };
    label.connectObject('notify::visible', follow, dialog);
    follow();
}
