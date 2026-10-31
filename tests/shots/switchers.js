// SPDX-License-Identifier: GPL-2.0-or-later
// The shell's switcher popups, each as its keybinding opens it, for glass.js and a11y.js.

import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as SwitcherPopup from 'resource:///org/gnome/shell/ui/switcherPopup.js';
import {InputSourcePopup} from 'resource:///org/gnome/shell/ui/status/keyboard.js';
import {SwitchMonitorPopup} from 'resource:///org/gnome/shell/ui/switchMonitor.js';

const BOARD_39_SOURCES = [{shortName: 'en', displayName: 'English (US)'}, {shortName: 'fr', displayName: 'French'}];

const AltTabStandIn = GObject.registerClass(class G2AltTabStandInPopup extends SwitcherPopup.SwitcherPopup {
    _init() {
        super._init([{}, {}]);
        this._switcherList = new SwitcherPopup.SwitcherList(true);
        this._items.forEach(() => this._switcherList.addItem(new St.Icon({icon_name: 'application-x-executable', icon_size: 96}), null));
    }
});

export const SWITCHERS = {
    'switcher': () => new AltTabStandIn(),
    'input-source-switcher': () => new InputSourcePopup(BOARD_39_SOURCES, null, null),
    'ctrl-alt-tab-switcher': () => {
        Main.ctrlAltTabManager.popup(false, null, 0);
        return Main.ctrlAltTabManager._popup;
    },
    'monitor-switcher': () => new SwitchMonitorPopup(),
};

export function showSwitcher(build) {
    const popup = build();
    if (!popup)
        return null;
    // SwitcherPopup's own show(), as SwitchMonitorPopup's refuses on a monitor that cannot switch.
    if (!popup._haveModal && !SwitcherPopup.SwitcherPopup.prototype.show.call(popup, false, null, 0)) {
        popup.destroy();
        return null;
    }
    popup._showImmediately();
    return popup;
}
