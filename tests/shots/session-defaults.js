// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's session defaults, in every case: the fonts and the icon theme the session reads, the
// families fontconfig gives them, and where each icon the bar, the dash and Quick Settings draw resolves.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const FONT_KEYS = ['font-name', 'document-font-name', 'monospace-font-name', 'font-hinting', 'icon-theme'];

// fc-match prints the family it picks, the file and the features fontconfig adds to it.
function fontconfigMatch(pattern) {
    try {
        const [, out] = GLib.spawn_command_line_sync(
            `fc-match --format=%{family[0]}|%{file}|%{fontfeatures} ${GLib.shell_quote(pattern)}`);
        const [family, file, features] = new TextDecoder().decode(out).split('|');
        return {family, file, features: features ? features.split(',') : []};
    } catch (e) {
        return {error: e.message};
    }
}

// The family Pango draws a label with, after fontconfig's substitutions.
function drawnFamily(label) {
    const layout = label?.clutter_text.get_layout();
    const font = layout?.get_context().load_font(layout.get_font_description() ?? layout.get_context().get_font_description());
    return font?.describe().get_family() ?? null;
}

function shownWithin(actor, root) {
    for (let a = actor; a && a !== root; a = a.get_parent()) {
        if (!a.visible)
            return false;
    }
    return true;
}

function iconsOf(root, theme, scale) {
    if (!root)
        return null;
    const icons = [];
    // A dash or dock item names its app, so a fixture app's fallback icon is told from the image's.
    const walk = (actor, app) => {
        app = actor.app?.get_id?.() ?? app;
        if (actor instanceof St.Icon && shownWithin(actor, root)) {
            const gicon = actor.gicon ?? (actor.icon_name ? new Gio.ThemedIcon({name: actor.icon_name}) : null);
            if (gicon) {
                const info = theme.lookup_by_gicon_for_scale(gicon, actor.icon_size > 0 ? actor.icon_size : 16, scale, 0);
                icons.push({icon: gicon.to_string(), file: info?.get_filename() ?? null, app: app ?? null});
            }
        }
        actor.get_children().forEach(child => walk(child, app));
    };
    walk(root, null);
    return icons;
}

export function sessionDefaultsReport({apexDock}) {
    const iface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
    const settings = Object.fromEntries(FONT_KEYS.map(key => [key, iface.get_value(key).deepUnpack()]));
    const theme = new St.IconTheme();
    theme.add_resource_path('/org/gnome/shell/icons');
    const scale = St.ThemeContext.get_for_stage(Main.uiGroup.get_stage()).scale_factor;
    const quickSettings = Main.panel.statusArea.quickSettings;
    return {
        settings,
        shell: {font: St.Settings.get().font_name, iconTheme: St.Settings.get().gtk_icon_theme},
        fontconfig: {sans: fontconfigMatch('Adwaita Sans'), mono: fontconfigMatch('JetBrains Mono')},
        drawn: {clock: drawnFamily(Main.panel.statusArea.dateMenu?._clockDisplay)},
        icons: {
            bar: iconsOf(Main.panel, theme, scale),
            dock: iconsOf(apexDock(), theme, scale),
            dash: iconsOf(Main.overview.dash, theme, scale),
            quickSettings: iconsOf(quickSettings?.menu.box, theme, scale),
        },
    };
}
