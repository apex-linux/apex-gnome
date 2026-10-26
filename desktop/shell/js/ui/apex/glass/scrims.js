// SPDX-License-Identifier: GPL-2.0-or-later
//
// ADR 0014's scrims: GNOME hides window_group in the overview, so each monitor gets a clone of it
// below #overviewGroup, blurred in actor mode at that monitor's own scale, not the stage's highest.

import Clutter from 'gi://Clutter';
import St from 'gi://St';

import * as Main from '../../main.js';
import * as Registry from './registry.js';

const SCRIM_NAME = 'apexGlassScrim';
const SCRIM_STYLE_CLASS = 'apex-glass-scrim';
const LAUNCHER_STYLE_CLASS = 'apex-launcher';
// overviewControls.js's ControlsState: WINDOW_PICKER is 1, APP_GRID 2.
const LAUNCHER_STATE = 1.5;

function _stateAdjustment() {
    return Main.overview._overview?._controls?._stateAdjustment ?? null;
}

// A fixed box laid out in its first frame; the clone, moved by the monitor's origin, shows its part.
function _scrim(monitor, visible) {
    const scrim = new St.Widget({
        name: SCRIM_NAME, style_class: SCRIM_STYLE_CLASS, reactive: false, visible, clip_to_allocation: true,
        x: monitor.x, y: monitor.y, width: monitor.width, height: monitor.height,
    });
    scrim.add_child(new Clutter.Clone({source: global.window_group, reactive: false, x: -monitor.x, y: -monitor.y}));
    return scrim;
}

export function register() {
    const group = Main.layoutManager.overviewGroup;
    const adjustment = _stateAdjustment();
    let scrims = [];
    const follow = () => {
        const launcher = (adjustment?.value ?? 0) > LAUNCHER_STATE;
        for (const scrim of scrims) {
            scrim.visible = group.visible;
            if (launcher)
                scrim.add_style_class_name(LAUNCHER_STYLE_CLASS);
            else
                scrim.remove_style_class_name(LAUNCHER_STYLE_CLASS);
        }
    };
    const build = () => {
        scrims.forEach(scrim => scrim.destroy());
        scrims = Main.layoutManager.monitors.map((monitor, index) => {
            const scrim = _scrim(monitor, group.visible);
            Main.uiGroup.insert_child_below(scrim, group);
            Registry.register(scrim, {name: `scrim-${index}`, mode: 'actor'});
            return scrim;
        });
        follow();
    };
    const connections = [
        [group, group.connect('notify::visible', follow)],
        [Main.layoutManager, Main.layoutManager.connect('monitors-changed', build)],
        ...adjustment ? [[adjustment, adjustment.connect('notify::value', follow)]] : [],
    ];
    build();

    return () => {
        connections.forEach(([emitter, id]) => emitter.disconnect(id));
        scrims.forEach(scrim => scrim.destroy());
    };
}
