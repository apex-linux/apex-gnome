// SPDX-License-Identifier: GPL-2.0-or-later
//
// ADR 0014's scrims: GNOME hides window_group in the overview, so a clone of it, blurred in actor
// mode, sits below #overviewGroup, bound to the stage: uiGroup keeps its first size when monitors change.

import Clutter from 'gi://Clutter';
import St from 'gi://St';

import * as Main from '../../main.js';
import * as Registry from './registry.js';

const SCRIM_STYLE_CLASS = 'apex-glass-scrim';
const LAUNCHER_STYLE_CLASS = 'apex-launcher';
// overviewControls.js's ControlsState: WINDOW_PICKER is 1, APP_GRID 2.
const LAUNCHER_STATE = 1.5;

function _stateAdjustment() {
    return Main.overview._overview?._controls?._stateAdjustment ?? null;
}

export function register() {
    const group = Main.layoutManager.overviewGroup;
    const scrim = new St.Widget({
        name: 'apexGlassScrim', style_class: SCRIM_STYLE_CLASS, reactive: false,
        visible: group.visible,
        constraints: new Clutter.BindConstraint({source: global.stage, coordinate: Clutter.BindCoordinate.ALL}),
    });
    scrim.add_child(new Clutter.Clone({source: global.window_group, reactive: false}));
    Main.uiGroup.insert_child_below(scrim, group);

    const adjustment = _stateAdjustment();
    const follow = () => {
        scrim.visible = group.visible;
        if ((adjustment?.value ?? 0) > LAUNCHER_STATE)
            scrim.add_style_class_name(LAUNCHER_STYLE_CLASS);
        else
            scrim.remove_style_class_name(LAUNCHER_STYLE_CLASS);
    };
    const connections = [
        [group, group.connect('notify::visible', follow)],
        ...adjustment ? [[adjustment, adjustment.connect('notify::value', follow)]] : [],
    ];
    follow();
    Registry.register(scrim, {name: 'scrim', mode: 'actor'});

    return () => {
        connections.forEach(([emitter, id]) => emitter.disconnect(id));
        scrim.destroy();
    };
}
