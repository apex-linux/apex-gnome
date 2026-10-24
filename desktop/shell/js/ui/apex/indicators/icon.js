// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN: an indicator is a 16 px glyph in the bar's colour, the item's -symbolic icon
// when the theme has one, otherwise its icon or pixmap drawn as a one-colour mask.

import Clutter from 'gi://Clutter';
import GdkPixbuf from 'gi://GdkPixbuf';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {MaskEffect} from './mask.js';

const FALLBACK_ICON = 'application-x-executable-symbolic';
const SYMBOLIC = '-symbolic';
const PIXMAP_SIZE = 16;

let _theme = null;

function _iconTheme() {
    _theme ??= new St.IconTheme();
    return _theme;
}

function _themeFile(themePath, name) {
    if (!themePath)
        return null;
    const theme = new St.IconTheme();
    theme.set_search_path([themePath]);
    return theme.lookup_icon(name, PIXMAP_SIZE, 0)?.get_filename() ?? null;
}

// The largest pixmap no bigger than twice the glyph, else the smallest; ARGB32 in
// network byte order, as the spec sends it, becomes RGBA.
function _pixbuf(pixmaps, scale) {
    const wanted = PIXMAP_SIZE * scale;
    const usable = pixmaps.filter(([w, h, data]) => w > 0 && h > 0 && data.length === w * h * 4);
    if (usable.length === 0)
        return null;
    usable.sort((a, b) => a[0] - b[0]);
    const [width, height, argb] = usable.filter(([w]) => w <= 2 * wanted).at(-1) ?? usable[0];
    const rgba = new Uint8Array(argb.length);
    for (let i = 0; i < argb.length; i += 4) {
        rgba[i] = argb[i + 1];
        rgba[i + 1] = argb[i + 2];
        rgba[i + 2] = argb[i + 3];
        rgba[i + 3] = argb[i];
    }
    return GdkPixbuf.Pixbuf.new_from_bytes(new GLib.Bytes(rgba), GdkPixbuf.Colorspace.RGB,
        true, 8, width, height, width * 4);
}

// What to draw for the item's properties: {iconName} for a symbolic icon St recolours,
// {gicon} for one drawn as a mask.
export function glyphSource(props, scale = 1) {
    const attention = props.Status === 'NeedsAttention';
    const name = (attention && props.AttentionIconName) || props.IconName;
    const pixmaps = (attention && props.AttentionIconPixmap?.length && props.AttentionIconPixmap) ||
        props.IconPixmap || [];
    if (name?.startsWith('/'))
        return {gicon: Gio.FileIcon.new(Gio.File.new_for_path(name)), kind: 'file'};
    if (name) {
        const symbolic = name.endsWith(SYMBOLIC) ? name : `${name}${SYMBOLIC}`;
        if (_iconTheme().has_icon(symbolic))
            return {iconName: symbolic, kind: 'symbolic'};
        const file = _themeFile(props.IconThemePath, symbolic) ?? _themeFile(props.IconThemePath, name);
        if (file)
            return {gicon: Gio.FileIcon.new(Gio.File.new_for_path(file)), kind: 'theme-path'};
        if (_iconTheme().has_icon(name))
            return {gicon: Gio.ThemedIcon.new(name), kind: 'mask'};
    }
    const pixbuf = _pixbuf(pixmaps, scale);
    if (pixbuf)
        return {gicon: pixbuf, kind: 'pixmap'};
    return {iconName: FALLBACK_ICON, kind: 'fallback'};
}

// A St.Icon that keeps showing the item's glyph in the colour its style gives it.
export function newGlyph(styleClass) {
    const icon = new St.Icon({
        style_class: styleClass,
        x_align: Clutter.ActorAlign.CENTER,
        y_align: Clutter.ActorAlign.CENTER,
    });
    const mask = new MaskEffect();
    icon.connect('style-changed', () => mask.setColor(icon.get_theme_node().get_foreground_color()));
    icon.setSource = source => {
        icon.kind = source.kind;
        if (source.iconName) {
            icon.remove_effect(mask);
            icon.gicon = null;
            icon.icon_name = source.iconName;
        } else {
            icon.gicon = source.gicon;
            if (!icon.get_effects().includes(mask))
                icon.add_effect(mask);
        }
    };
    return icon;
}
