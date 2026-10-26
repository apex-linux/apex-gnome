// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's derived glass: the transient surfaces that copy a drawn glass surface take its
// glass. OSDs, Alt+Tab, the screenshot panel and the tile preview, as banners do (surfaces.js).

import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Main from '../../main.js';
import * as Registry from './registry.js';

const SWITCHER_LIST_STYLE_CLASS = 'switcher-list';
const TILE_GLASS_STYLE_CLASS = 'apex-tile-preview-glass';

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

// Board 22 blurs only inside the preview's clear inset border, which a blur on the preview would
// cover too: a glass actor just below it, inside that border, takes the blur instead.
function _tileGlass(preview) {
    const glass = new St.Widget({name: 'apexTilePreviewGlass', style_class: TILE_GLASS_STYLE_CLASS, visible: false});
    const {X, Y, WIDTH, HEIGHT} = Clutter.BindCoordinate;
    const binds = [X, Y, WIDTH, HEIGHT].map(coordinate => new Clutter.BindConstraint({source: preview, coordinate}));
    binds.forEach(bind => glass.add_constraint(bind));
    const inset = () => {
        const border = preview.peek_theme_node()?.get_border_width(St.Side.TOP) ?? 0;
        [border, border, -2 * border, -2 * border].forEach((offset, i) => (binds[i].offset = offset));
    };
    inset();
    preview.bind_property('opacity', glass, 'opacity', GObject.BindingFlags.SYNC_CREATE);
    preview.get_parent().insert_child_below(glass, preview);
    // TilePreview.open() restacks the preview below the dragged window before it shows.
    const follow = () => {
        if (preview.visible) {
            if (glass.get_next_sibling() !== preview)
                preview.get_parent().set_child_below_sibling(glass, preview);
            inset();
            glass.show();
            Registry.register(glass, {name: 'tilePreview'});
        } else {
            Registry.unregister(glass);
            glass.hide();
        }
    };
    const ids = [preview.connect('notify::visible', follow), preview.connect('style-changed', inset)];
    follow();
    return () => {
        ids.forEach(id => preview.disconnect(id));
        Registry.unregister(glass);
        glass.destroy();
    };
}

// windowManager.js builds its TilePreview, which adds itself to the window group, at the first tiling.
function _tilePreviews() {
    const removes = new Map();
    const forget = actor => {
        const [remove, destroyId] = removes.get(actor);
        actor.disconnect(destroyId);
        remove();
        removes.delete(actor);
    };
    const watch = actor => {
        if (actor?.constructor.name !== 'TilePreview' || removes.has(actor))
            return;
        removes.set(actor, [_tileGlass(actor), actor.connect('destroy', () => forget(actor))]);
    };
    watch(Main.wm._tilePreview);
    const id = global.window_group.connect('child-added', (_group, actor) => watch(actor));
    return () => {
        global.window_group.disconnect(id);
        [...removes.keys()].forEach(forget);
    };
}

export function register() {
    const panel = Main.screenshotUI?._panel;
    if (panel)
        Registry.register(panel, {name: 'screenshot'});
    const unregisters = [_osds(), _switchers(), _tilePreviews()];
    return () => {
        unregisters.forEach(unregister => unregister());
        if (panel)
            Registry.unregister(panel);
    };
}
