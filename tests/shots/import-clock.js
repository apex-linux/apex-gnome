// SPDX-License-Identifier: GPL-3.0-or-later
//
// probe.js's first import. A module graph evaluates its imports in order, so this runs as the
// probe's graph starts to evaluate, once main.js has fetched and parsed all of it.

import GLib from 'gi://GLib';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export const graphEvaluated = {at: GLib.get_monotonic_time() / 1000, startingUp: Main.layoutManager._startingUp};
