// SPDX-License-Identifier: GPL-3.0-or-later
// A plain GTK 4 window for the probe's motion case to maximise; it lives until the shell ends.

import Gtk from 'gi://Gtk?version=4.0';

const app = new Gtk.Application({application_id: 'io.github.apex_linux.G2Window'});
app.connect('activate', () => {
    const window = new Gtk.ApplicationWindow({application: app, title: 'G2', default_width: 640,
        default_height: 400});
    window.present();
});
app.run([]);
