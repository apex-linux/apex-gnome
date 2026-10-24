// SPDX-License-Identifier: GPL-3.0-or-later
//
// glass-load.js's stand-in for a video: a new colour from a timer, not the frame clock, so each
// run commits the same frames; "still" paints once. The probe places, moves and stops it.

import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk?version=4.0';

const APP_ID = 'io.github.apex_linux.G2LoadWindow';
const FRAME_MS = 33;
const PALETTE = [[0.88, 0.11, 0.14], [0.2, 0.82, 0.48], [0.21, 0.52, 0.89], [0.96, 0.83, 0.18],
    [0.57, 0.25, 0.67], [1, 0.47, 0]];

const still = ARGV.includes('still');
let frame = 0;
const app = new Gtk.Application({application_id: APP_ID});
app.connect('activate', () => {
    const area = new Gtk.DrawingArea();
    area.set_draw_func((_area, cr) => {
        cr.setSourceRGB(...PALETTE[frame % PALETTE.length]);
        cr.paint();
    });
    const window = new Gtk.ApplicationWindow({
        application: app, title: 'G2 load window', default_width: 640, default_height: 400, child: area,
    });
    window.present();
    if (!still) {
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, FRAME_MS, () => {
            frame++;
            area.queue_draw();
            return GLib.SOURCE_CONTINUE;
        });
    }
});
app.run([GLib.get_prgname() ?? 'g2-load-window']);
