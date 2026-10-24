// SPDX-License-Identifier: GPL-3.0-or-later
// accent-test.sh's file chooser: GTK's own chooser widget on the folder in ARGV, with no portal to hand it to.

import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk?version=4.0';
import System from 'system';

const app = new Gtk.Application({application_id: 'io.github.apex_linux.S7Chooser'});
app.connect('activate', () => {
    const chooser = new Gtk.FileChooserWidget({action: Gtk.FileChooserAction.OPEN});
    chooser.set_current_folder(Gio.File.new_for_path(System.programArgs[0]));
    const window = new Gtk.ApplicationWindow({application: app, title: 'S7 Chooser', child: chooser});
    window.present();
});
app.run([]);
