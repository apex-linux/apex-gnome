// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's input sources (G2_INPUT_SOURCES=1): the image's us and IBus Telex, per window, under Spotlight's
// Super+Space and the input source's Super+Alt+Space, in the session and in the overview.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';
import {getIBusManager} from 'resource:///org/gnome/shell/misc/ibusManager.js';
import {getInputSourceManager} from 'resource:///org/gnome/shell/ui/status/keyboard.js';

import {until} from './idle.js';

const TELEX = 'm17n:vi:telex';
const IBUS_WAIT_MS = 20000;
const ENGINE_WAIT_MS = 4000;
const POPUP_WAIT_MS = 2000;
const HELD_MS = 500;
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
    const chip = () => Main.panel.statusArea.keyboard?._container.get_children().find(label => label.visible)?.text ?? null;
    const state = () => ({source: source(), engine: engine(), chip: chip()});
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
    // Held, Super+Alt keeps the switcher up, on the next source, and only the release switches.
    const held = async (modifiers, want) => {
        const at = () => GLib.get_monotonic_time();
        let switcher = null;
        const addedId = Main.uiGroup.connect('child-added', (_group, child) => {
            if (child.constructor.name === 'InputSourcePopup')
                switcher = child;
        });
        const shown = () => switcher?.mapped ?? false;
        modifiers.forEach(m => keyboard.notify_keyval(at(), m, Clutter.KeyState.PRESSED));
        keyboard.notify_keyval(at(), Clutter.KEY_space, Clutter.KeyState.PRESSED);
        keyboard.notify_keyval(at(), Clutter.KEY_space, Clutter.KeyState.RELEASED);
        await until(shown, POPUP_WAIT_MS);
        await Scripting.sleep(HELD_MS);
        const whileHeld = {
            shown: shown(),
            items: switcher?._items.map(item => item.id) ?? null,
            selected: switcher?._items[switcher._selectedIndex]?.id ?? null,
            ...state(),
        };
        [...modifiers].reverse().forEach(m => keyboard.notify_keyval(at(), m, Clutter.KeyState.RELEASED));
        Main.uiGroup.disconnect(addedId);
        return {held: whileHeld, released: {shown: shown(), ...await settled(want)}};
    };
    const mode = async () => {
        const at = {start: await settled('xkb:us::eng')};
        at.superSpace = await superSpace();
        at.superAltSpace = await switched([Clutter.KEY_Super_L, Clutter.KEY_Alt_L], TELEX);
        at.superSpaceInTelex = await superSpace();
        at.shiftSuperAltSpace = await switched([Clutter.KEY_Shift_L, Clutter.KEY_Super_L, Clutter.KEY_Alt_L], 'xkb:us::eng');
        at.heldSuperAlt = await held([Clutter.KEY_Super_L, Clutter.KEY_Alt_L], TELEX);
        at.back = await switched([Clutter.KEY_Shift_L, Clutter.KEY_Super_L, Clutter.KEY_Alt_L], 'xkb:us::eng');
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
