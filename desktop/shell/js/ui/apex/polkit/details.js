// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 13's Details: the action's id and, from polkit's own description of it, its vendor.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import Polkit from 'gi://Polkit';
import St from 'gi://St';

Gio._promisify(Polkit.Authority, 'get_async', 'get_finish');
Gio._promisify(Polkit.Authority.prototype, 'enumerate_actions', 'enumerate_actions_finish');

const OPEN_GLYPH = 'pan-down-symbolic';
const CLOSED_GLYPH = 'pan-end-symbolic';
const CLOSED_GLYPH_RTL = 'pan-start-symbolic';

export async function vendorOf(actionId, cancellable) {
    const authority = await Polkit.Authority.get_async(cancellable);
    const actions = await authority.enumerate_actions(cancellable);
    return actions.find(a => a.get_action_id() === actionId)?.get_vendor_name() || null;
}

function _row(key, value, valueClass) {
    const row = new St.BoxLayout({style_class: 'apex-polkit-details-row'});
    row.add_child(new St.Label({style_class: 'apex-polkit-details-key', text: key}));
    row.add_child(new St.Label({style_class: `apex-polkit-details-value ${valueClass}`.trim(), text: value, x_expand: true}));
    return row;
}

async function _fillVendor(dialog, row) {
    const cancellable = new Gio.Cancellable();
    dialog.connect('destroy', () => cancellable.cancel());
    let vendor;
    try {
        vendor = await vendorOf(dialog.actionId, cancellable);
    } catch (e) {
        if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
            console.warn(`Apex: polkit: no vendor for ${dialog.actionId}: ${e.message}`);
        return;
    }
    if (!vendor)
        return;
    row.get_children()[1].text = vendor;
    row.show();
}

export function setUp(dialog) {
    const details = new St.BoxLayout({
        style_class: 'apex-polkit-details',
        orientation: Clutter.Orientation.VERTICAL,
        x_expand: true,
    });
    const chevron = new St.Icon({style_class: 'apex-polkit-details-chevron'});
    const heading = new St.BoxLayout({style_class: 'apex-polkit-details-heading', x_expand: true});
    heading.add_child(chevron);
    heading.add_child(new St.Label({text: _('Details'), y_align: Clutter.ActorAlign.CENTER}));
    const toggle = new St.Button({
        style_class: 'apex-polkit-details-toggle',
        can_focus: true,
        x_expand: true,
        accessible_name: _('Details'),
        child: heading,
    });
    const grid = new St.BoxLayout({
        style_class: 'apex-polkit-details-grid',
        orientation: Clutter.Orientation.VERTICAL,
    });
    const vendor = _row(_('Vendor'), '');
    vendor.hide();
    grid.add_child(_row(_('Action'), dialog.actionId, 'apex-polkit-action'));
    grid.add_child(vendor);
    details.add_child(toggle);
    details.add_child(grid);

    const rtl = Clutter.get_default_text_direction() === Clutter.TextDirection.RTL;
    const closedGlyph = rtl ? CLOSED_GLYPH_RTL : CLOSED_GLYPH;
    const show = open => {
        grid.visible = open;
        chevron.icon_name = open ? OPEN_GLYPH : closedGlyph;
        if (open)
            toggle.add_style_pseudo_class('checked');
        else
            toggle.remove_style_pseudo_class('checked');
    };
    toggle.connect('clicked', () => show(!grid.visible));
    show(true);
    dialog.contentLayout.add_child(details);
    _fillVendor(dialog, vendor).catch(logError);
}
