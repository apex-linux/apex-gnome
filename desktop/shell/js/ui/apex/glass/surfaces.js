// SPDX-License-Identifier: GPL-2.0-or-later
//
// The glass the layer itself draws: the top bar, Quick Settings, the calendar, banners and the
// overview's and the launcher's scrims.

import * as Main from '../../main.js';
import * as Derived from './derived.js';
import * as Registry from './registry.js';
import * as Scrims from './scrims.js';

const SOLID_BAR_STYLE_CLASS = 'apex-solid-bar';
const BANNER_STYLE_CLASS = 'notification-banner';

function _banners() {
    const bin = Main.messageTray._bannerBin;
    const registerBanner = banner => {
        if (banner.has_style_class_name?.(BANNER_STYLE_CLASS))
            Registry.register(banner, {name: 'banner'});
    };
    bin.get_children().forEach(registerBanner);
    const id = bin.connect('child-added', (_bin, banner) => registerBanner(banner));
    return () => {
        bin.disconnect(id);
        bin.get_children().forEach(banner => Registry.unregister(banner));
    };
}

export function register() {
    const {quickSettings, dateMenu} = Main.panel.statusArea;
    // Board 20: the lock screen and the unlock dialog (both isLocked) draw no bar band.
    Registry.register(Main.panel, {
        name: 'panel',
        paused: () => Main.panel.has_style_class_name(SOLID_BAR_STYLE_CLASS) || Main.sessionMode.isLocked,
        pausedChanged: [[Main.sessionMode, 'updated']],
    });
    Registry.register(quickSettings.menu.box, {name: 'quick-settings'});
    Registry.register(dateMenu.menu.box, {name: 'calendar'});
    const unregisterBanners = _banners();
    const removeScrim = Scrims.register();
    const removeDerived = Derived.register();
    return () => {
        removeDerived();
        removeScrim();
        unregisterBanners();
        [Main.panel, quickSettings.menu.box, dateMenu.menu.box].forEach(actor => Registry.unregister(actor));
    };
}
