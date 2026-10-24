// SPDX-License-Identifier: GPL-2.0-or-later
//
// The shield above the title, and the user beside the avatar with the role under the name.

import AccountsService from 'gi://AccountsService';
import Clutter from 'gi://Clutter';
import St from 'gi://St';

const SHIELD_GLYPH = 'dialog-password-symbolic';
const ROOT = 'root';

export function isAdministrator(user) {
    return Boolean(user?.is_loaded) && user.get_user_name() !== ROOT &&
        user.get_account_type() === AccountsService.UserAccountType.ADMINISTRATOR;
}

function _addShield(dialog) {
    const shield = new St.Bin({
        style_class: 'apex-polkit-icon',
        x_align: Clutter.ActorAlign.CENTER,
        child: new St.Icon({icon_name: SHIELD_GLYPH, style_class: 'apex-polkit-icon-glyph'}),
    });
    const content = dialog.contentLayout;
    content.insert_child_below(shield, content.get_first_child());
}

// Upstream labels only root "Administrator", in the name's place; root keeps that.
function _addRole(dialog) {
    const avatar = dialog._userAvatar;
    const name = dialog._userLabel;
    const row = avatar.get_parent();
    row.orientation = Clutter.Orientation.HORIZONTAL;
    row.add_style_class_name('apex-polkit-user');
    avatar.x_align = Clutter.ActorAlign.START;
    avatar.y_align = Clutter.ActorAlign.CENTER;
    row.remove_child(name);

    const names = new St.BoxLayout({
        style_class: 'apex-polkit-names',
        orientation: Clutter.Orientation.VERTICAL,
        y_align: Clutter.ActorAlign.CENTER,
    });
    const role = new St.Label({style_class: 'apex-polkit-role', text: _('Administrator'), visible: false});
    names.add_child(name);
    names.add_child(role);
    row.add_child(names);

    const follow = () => {
        role.visible = isAdministrator(dialog._user);
    };
    dialog._user.connectObject('notify::is-loaded', follow, 'changed', follow, dialog);
    follow();
}

export function setUp(dialog) {
    _addShield(dialog);
    _addRole(dialog);
}
