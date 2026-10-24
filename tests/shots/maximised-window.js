// SPDX-License-Identifier: GPL-3.0-or-later
//
// One maximised GTK window for the dock's intellihide case: probe.js starts it in the
// shell's session and stops it.

import Gtk from 'gi://Gtk?version=4.0';
import GLib from 'gi://GLib';

const app = new Gtk.Application({application_id: 'io.github.apex_linux.G2Window'});
app.connect('activate', () => {
    const window = new Gtk.ApplicationWindow({application: app, title: 'G2 maximised window'});
    window.maximize();
    window.present();
});
app.run([GLib.get_prgname() ?? 'g2-window']);
