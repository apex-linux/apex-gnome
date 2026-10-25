// SPDX-License-Identifier: GPL-3.0-or-later
//
// glass-load.js's stand-in for a video: a new colour from a timer, not the frame clock, so each
// run commits the same frames; "still" paints once. The probe places, moves and stops it.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk?version=4.0';

const APP_ID = 'io.github.apex_linux.G2LoadWindow';
const FRAME_MS = 33;
const PALETTE = [[0.88, 0.11, 0.14], [0.2, 0.82, 0.48], [0.21, 0.52, 0.89], [0.96, 0.83, 0.18],
    [0.57, 0.25, 0.67], [1, 0.47, 0]];

// tests/laptop's options: measure=PATH logs each change and each presented frame as it completes;
// coalesce=N makes change N share a tick with the next, so exactly one change is never shown.
const option = name => ARGV.find(a => a.startsWith(`${name}=`))?.slice(name.length + 1);
const still = ARGV.includes('still');
const measurePath = option('measure');
const coalesceAt = Number(option('coalesce') ?? -1);
const log = measurePath ? Gio.File.new_for_path(measurePath).append_to(Gio.FileCreateFlags.NONE, null) : null;
const write = line => {
    log?.write_all(`${line}\n`, null);
    log?.flush(null);
};

let frame = 0;
const painted = new Map();

function change() {
    frame++;
    write(`c ${frame} ${GLib.get_monotonic_time()}`);
}

// Frame timings live in a short history, so each is read as soon as the compositor completes it.
function collect(clock) {
    for (const [counter, shown] of painted) {
        const timings = clock.get_timings(counter);
        if (timings && !timings.get_complete())
            break;
        write(`p ${shown} ${timings?.get_presentation_time() ?? 0}`);
        painted.delete(counter);
    }
}

const app = new Gtk.Application({application_id: APP_ID});
app.connect('activate', () => {
    const area = new Gtk.DrawingArea();
    area.set_draw_func((_area, cr) => {
        cr.setSourceRGB(...PALETTE[frame % PALETTE.length]);
        cr.paint();
        if (log)
            painted.set(area.get_frame_clock().get_frame_counter(), frame);
    });
    const window = new Gtk.ApplicationWindow({
        application: app, title: 'G2 load window', default_width: 640, default_height: 400, child: area,
    });
    if (log)
        window.connect('map', () => window.get_frame_clock().connect('after-paint', collect));
    window.present();
    if (!still) {
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, FRAME_MS, () => {
            change();
            if (frame === coalesceAt)
                change();
            area.queue_draw();
            return GLib.SOURCE_CONTINUE;
        });
    }
});
app.run([GLib.get_prgname() ?? 'g2-load-window']);
