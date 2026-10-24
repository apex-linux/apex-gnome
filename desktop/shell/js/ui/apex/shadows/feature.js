// SPDX-License-Identifier: GPL-2.0-or-later

import St from 'gi://St';

import * as Main from '../../main.js';
import * as Registry from './registry.js';

export const PREVIEW_STYLE_CLASS = 'apex-window-preview';
// A surface sits a few actors below its container's child: a BoxPointer's bin, a dialog's layout.
const SURFACE_DEPTH = 4;

let _watched = [];
const _previews = new Set();

function _surfaces(actor, depth = 0) {
    if (!(actor instanceof St.Widget) || depth > SURFACE_DEPTH)
        return [];
    if (actor.get_stage() && actor.get_theme_node().get_shadow(Registry.LAYER_PROPERTIES[0]))
        return [actor];
    return actor.get_children().flatMap(child => _surfaces(child, depth + 1));
}

// A dialog's layer goes next to it, above the lightbox its ModalDialog keeps under it.
function _registerIn(container, child) {
    const inDialog = container === Main.layoutManager.modalDialogGroup;
    for (const surface of _surfaces(child)) {
        const host = inDialog ? surface.get_parent() : container;
        Registry.register(surface, {name: 'apex-shadow', container: host});
    }
}

function _registerPreviews() {
    const walk = actor => actor.get_children().flatMap(c =>
        c.window_container !== undefined && c instanceof St.Widget ? [c] : walk(c));
    for (const preview of walk(Main.layoutManager.overviewGroup)) {
        preview.add_style_class_name(PREVIEW_STYLE_CLASS);
        _previews.add(preview);
        preview.connectObject('destroy', () => _previews.delete(preview), preview);
        Registry.register(preview, {name: 'apex-preview-shadow', box: preview.window_container});
    }
}

function _containers() {
    return [Main.uiGroup, Main.layoutManager.modalDialogGroup, Main.messageTray._bannerBin].filter(Boolean);
}

export function enable() {
    Registry.start();
    for (const container of _containers()) {
        container.get_children().forEach(child => _registerIn(container, child));
        _watched.push([container, container.connect('child-added', (_c, child) => _registerIn(container, child))]);
    }
    _watched.push([Main.overview, Main.overview.connect('showing', _registerPreviews)]);
    if (Main.overview.visible)
        _registerPreviews();
}

export function disable() {
    _watched.forEach(([emitter, id]) => emitter.disconnect(id));
    _watched = [];
    for (const preview of _previews)
        preview.remove_style_class_name(PREVIEW_STYLE_CLASS);
    _previews.clear();
    Registry.stop();
}
