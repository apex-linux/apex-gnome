// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 35: workspace thumbnails 70 px tall from the 868 px work area under the bar, shown from
// two workspaces, which with dynamic workspaces is as soon as one has a window.

import Clutter from 'gi://Clutter';
import Graphene from 'gi://Graphene';
import St from 'gi://St';

import * as Background from '../../background.js';
import * as Hooks from '../hooks.js';
import * as Main from '../../main.js';

const THUMBNAIL_SCALE = 0.081;
const THUMBNAILS_THRESHOLD = 1;
const WALLPAPER_STYLE_CLASS = 'apex-thumbnail-wallpaper';

let _enabled = false;
let _stockScale = null;

// The primary monitor's box lives as long as the overview; the others' come with each opening.
function _primaryBox() {
    return Main.overview._overview._controls._thumbnailsBox;
}

// Board 35's thumbnails show the wallpaper; stock's are a flat fill behind the window clones.
// The viewport's scale shrinks the clip, so its radius and border are drawn larger.
function _addBackground(thumbnail) {
    if (!_enabled)
        return;
    thumbnail.add_style_class_name(WALLPAPER_STYLE_CLASS);
    const group = new Clutter.Actor();
    thumbnail._contents.insert_child_at_index(group, 0);
    const manager = new Background.BackgroundManager({
        container: group, monitorIndex: thumbnail.monitorIndex, vignette: false,
    });
    const clip = () => {
        const node = thumbnail.peek_theme_node();
        const scale = thumbnail._viewport.scale_x;
        if (!node || scale <= 0)
            return;
        const monitor = Main.layoutManager.monitors[thumbnail.monitorIndex];
        const workArea = Main.layoutManager.getWorkAreaForMonitor(thumbnail.monitorIndex);
        const border = node.get_border_width(St.Side.TOP);
        const bounds = new Graphene.Rect();
        bounds.init(workArea.x - monitor.x, workArea.y - monitor.y, workArea.width, workArea.height);
        bounds.inset(border / scale, border / scale);
        const {content} = manager.backgroundActor;
        content.set_rounded_clip_bounds(bounds);
        content.rounded_clip_radius = (node.get_border_radius(St.Corner.TOPLEFT) - border) / scale;
    };
    manager.connect('changed', clip);
    thumbnail._viewport.connectObject('notify::scale-x', clip, group);
    thumbnail.connectObject('style-changed', clip, group);
    thumbnail.connect('destroy', () => manager.destroy());
    clip();
}

function _sync(box, scale) {
    box._maxThumbnailScale = scale;
    box._updateShouldShow();
    box.queue_relayout();
}

export function configure(featureName) {
    Hooks.provide(featureName, 'thumbnail-scale', stock => _enabled ? THUMBNAIL_SCALE : stock);
    Hooks.provide(featureName, 'thumbnails-threshold', stock => _enabled ? THUMBNAILS_THRESHOLD : stock);
    Hooks.provide(featureName, 'workspace-thumbnail', _addBackground);
}

export function enable() {
    _enabled = true;
    const box = _primaryBox();
    _stockScale ??= box._maxThumbnailScale;
    _sync(box, THUMBNAIL_SCALE);
}

export function disable() {
    _enabled = false;
    _sync(_primaryBox(), _stockScale);
}
