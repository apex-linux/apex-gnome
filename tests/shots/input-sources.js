// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's input sources (G2_INPUT_SOURCES=1): the image's us and IBus Telex, per window, under Spotlight's
// Super+Space and the input source's Super+Alt+Space, in the session and in the overview.

import Clutter from 'gi://Clutter';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {getIBusManager} from 'resource:///org/gnome/shell/misc/ibusManager.js';
import {getInputSourceManager} from 'resource:///org/gnome/shell/ui/status/keyboard.js';

import {until} from './idle.js';

const TELEX = 'm17n:vi:telex';
const IBUS_WAIT_MS = 20000;
const ENGINE_WAIT_MS = 4000;
const TYPED = [Clutter.KEY_V, Clutter.KEY_i, Clutter.KEY_e, Clutter.KEY_e, Clutter.KEY_t, Clutter.KEY_j];

export async function inputSourcesReport({settle, chord, spotlight}) {
    const ibus = getIBusManager();
    const sources = getInputSourceManager();
    const ready = await until(() => ibus._ready && Object.values(sources.inputSources).some(s => s.id === TELEX),
        IBUS_WAIT_MS);
    const source = () => sources.currentSource?.id ?? null;
    const engine = () => ibus._currentEngineName;
    const popup = await spotlight();
    const keyboard = Main.uiGroup.get_stage().context.get_backend().get_default_seat()
        .create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    const state = () => ({source: source(), engine: engine()});
    const settled = async want => {
        await until(() => engine() === want, ENGINE_WAIT_MS);
        return state();
    };
    const report = {
        ready,
        sources: Object.values(sources.inputSources).map(s => ({type: s.type, id: s.id})),
        telexEngine: ibus.getEngineDesc(TELEX)?.get_name() ?? null,
    };

    const superSpace = async () => {
        await chord(keyboard, [Clutter.KEY_Super_L], Clutter.KEY_space);
        const after = {spotlight: popup?.isOpen ?? null, ...state()};
        popup?.close();
        await settle();
        return after;
    };
    // A virtual keyboard holds no modifier, so the switcher finishes at once: it is read as it joins uiGroup.
    const switched = async (modifiers, want) => {
        const shown = [];
        const addedId = Main.uiGroup.connect('child-added', (_group, child) => {
            if (child.constructor.name === 'InputSourcePopup')
                shown.push(child._items.map(item => item.id));
        });
        await chord(keyboard, modifiers, Clutter.KEY_space);
        Main.uiGroup.disconnect(addedId);
        return {switcher: shown, ...await settled(want)};
    };
    const mode = async () => {
        const at = {start: await settled('xkb:us::eng')};
        at.superSpace = await superSpace();
        at.superAltSpace = await switched([Clutter.KEY_Super_L, Clutter.KEY_Alt_L], TELEX);
        at.superSpaceInTelex = await superSpace();
        at.shiftSuperAltSpace = await switched([Clutter.KEY_Shift_L, Clutter.KEY_Super_L, Clutter.KEY_Alt_L], 'xkb:us::eng');
        return at;
    };

    report.session = await mode();
    await chord(keyboard, [Clutter.KEY_Super_L, Clutter.KEY_Alt_L], Clutter.KEY_space);
    await settled(TELEX);
    popup?.open();
    await settle();
    for (const keyval of TYPED)
        // eslint-disable-next-line no-await-in-loop
        await chord(keyboard, [], keyval);
    await chord(keyboard, [], Clutter.KEY_space);
    report.typed = {engine: engine(), text: popup?.panel.get_children()[0].get_children()[1].get_text() ?? null};
    popup?.close();
    await settle();
    await chord(keyboard, [Clutter.KEY_Shift_L, Clutter.KEY_Super_L, Clutter.KEY_Alt_L], Clutter.KEY_space);
    await settled('xkb:us::eng');

    Main.overview.show();
    await settle();
    report.overview = {visible: Main.overview.visible, ...await mode()};
    Main.overview.hide();
    await settle();
    report.modals = Main.modalCount;
    return report;
}
