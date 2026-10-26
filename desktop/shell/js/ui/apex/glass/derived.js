// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's derived glass: the transient surfaces that copy a drawn glass surface take its
// glass. OSDs, Alt+Tab and the screenshot panel, as banners already do (surfaces.js).

import * as Main from '../../main.js';
import * as Registry from './registry.js';

const SWITCHER_LIST_STYLE_CLASS = 'switcher-list';

function _osds() {
    const sync = () => {
        for (const osd of Main.osdWindowManager?._osdWindows ?? []) {
            if (osd?._hbox)
                Registry.register(osd._hbox, {name: 'osd'});
        }
    };
    sync();
    const id = Main.layoutManager.connect('monitors-changed', sync);
    return () => {
        Main.layoutManager.disconnect(id);
        for (const osd of Main.osdWindowManager?._osdWindows ?? []) {
            if (osd?._hbox)
                Registry.unregister(osd._hbox);
        }
    };
}

// switcherPopup.js adds each popup to uiGroup, then its list once it has items.
function _switchers() {
    const watched = new Map();
    const registerList = (_popup, child) => {
        if (child.has_style_class_name?.(SWITCHER_LIST_STYLE_CLASS))
            Registry.register(child, {name: 'switcher'});
    };
    const id = Main.uiGroup.connect('child-added', (_group, actor) => {
        if (actor.constructor.name.endsWith('SwitcherPopup') && !watched.has(actor)) {
            watched.set(actor, actor.connect('child-added', registerList));
            actor.connect('destroy', () => watched.delete(actor));
        }
    });
    return () => {
        Main.uiGroup.disconnect(id);
        for (const [popup, childId] of watched)
            popup.disconnect(childId);
        watched.clear();
    };
}

export function register() {
    const panel = Main.screenshotUI?._panel;
    if (panel)
        Registry.register(panel, {name: 'screenshot'});
    const unregisters = [_osds(), _switchers()];
    return () => {
        unregisters.forEach(unregister => unregister());
        if (panel)
            Registry.unregister(panel);
    };
}
