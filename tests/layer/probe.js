// SPDX-License-Identifier: GPL-3.0-or-later
//
// Facts go to stderr: it is unbuffered, so the facts before an abort survive.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const shellDir = GLib.getenv('APEX_SHELL_DIR');
const fact = (key, value) => printerr(`probe: ${key}=${value}`);

const handlers = new Map();
let nextId = 1;
globalThis.global = {
    session_mode: GLib.getenv('PROBE_MODE') ?? 'user',
    connect(signal, fn) {
        handlers.set(nextId, [signal, fn]);
        return nextId++;
    },
    disconnect(id) {
        handlers.delete(id);
    },
};

const schema = Gio.SettingsSchemaSource.get_default()?.lookup(
    'io.github.apex_linux.Apex.Desktop', true);
const settings = schema ? new Gio.Settings({settings_schema: schema}) : null;
if (settings) {
    if (GLib.getenv('PROBE_LAYER_OFF') === '1')
        settings.set_boolean('layer-enabled', false);
    const disabled = GLib.getenv('PROBE_DISABLED');
    if (disabled)
        settings.set_strv('disabled-features', disabled.split(','));
}

const Hooks = await import(`file://${shellDir}/js/ui/apex/hooks.js`);
fact('safe', Hooks.safe());
const layerUrl = GLib.getenv('PROBE_BROKEN') === '1'
    ? `file://${shellDir}/js/ui/apex/no-such-layer.js`
    : `file://${shellDir}/js/ui/apex/layer.js`;
const layer = await Hooks.loadLayer(() => import(layerUrl));
fact('layer', layer ? 'loaded' : 'null');

const stock = {colorScheme: 'prefer-dark', hasOverview: true};

// Awaited at the top level, so gjs runs the main loop and the layer's promise jobs between.
function spin(ms) {
    return new Promise(resolve => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
        resolve();
        return GLib.SOURCE_REMOVE;
    }));
}

async function setDisabledLive() {
    const disabled = GLib.getenv('PROBE_DISABLE_LIVE');
    if (disabled === null)
        return;
    for (const list of [disabled.split(','), []]) {
        settings.set_strv('disabled-features', list);
        // eslint-disable-next-line no-await-in-loop
        await spin(200);
        fact(`disabled-live.${list.join(',') || 'none'}`, `witness=${Hooks.value('test-witness', 'stock')} ` +
            `scheme=${Hooks.value('session-mode', {...stock}, 'user').colorScheme}`);
    }
    settings.set_boolean('layer-enabled', false);
    settings.set_strv('disabled-features', disabled.split(','));
    await spin(200);
    settings.set_boolean('layer-enabled', true);
    await spin(200);
    fact('disabled-while-off', `witness=${Hooks.value('test-witness', 'stock')}`);
    settings.set_strv('disabled-features', []);
    await spin(200);
}

async function switchLayer() {
    const cycles = Number(GLib.getenv('PROBE_SWITCH') ?? '0');
    for (let cycle = 1; cycle <= cycles; cycle++) {
        for (const on of [false, true]) {
            settings.set_boolean('layer-enabled', on);
            // eslint-disable-next-line no-await-in-loop
            await spin(200);
            fact(`switch.${cycle}.${on}`, `safe=${Hooks.safe()} ` +
                `scheme=${Hooks.value('session-mode', {...stock}, 'user').colorScheme} ` +
                `witness=${Hooks.value('test-witness', 'stock')}`);
        }
    }
}
for (const mode of ['user', 'unlock-dialog', 'gdm', 'initial-setup']) {
    const params = Hooks.value('session-mode', {...stock}, mode);
    fact(`scheme.${mode}`, `${params.colorScheme}${params.hasOverview ? '' : ' (params lost)'}`);
}
fact('test-fault', Hooks.value('test-fault', 'stock'));
fact('test-witness', Hooks.value('test-witness', 'stock'));

Hooks.provide('probe', 'boom', () => {
    throw new Error('boom');
});
fact('boom', `${Hooks.value('boom', 'stock')},${Hooks.value('boom', 'stock')}`);
fact('run-without-provider', Hooks.run('nothing'));

if (layer && GLib.getenv('PROBE_ENABLE') === '1') {
    layer.enable();
    const marker = GLib.build_filenamev([GLib.get_user_runtime_dir(), 'apex-shell-starting']);
    fact('starting-file', GLib.file_test(marker, GLib.FileTest.EXISTS));
    fact('test-fault.after-enable', Hooks.value('test-fault', 'stock'));
    fact('test-witness.after-enable', Hooks.value('test-witness', 'stock'));
    fact('scheme.user.after-enable', Hooks.value('session-mode', {...stock}, 'user').colorScheme);
    const waitSeconds = Number(GLib.getenv('PROBE_WAIT') ?? '0');
    if (waitSeconds > 0) {
        const loop = new GLib.MainLoop(null, false);
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, waitSeconds, () => {
            loop.quit();
            return GLib.SOURCE_REMOVE;
        });
        loop.run();
        fact('survived', `${waitSeconds}s`);
    }
    await setDisabledLive();
    await switchLayer();
    for (const [signal, fn] of [...handlers.values()]) {
        if (signal === 'shutdown')
            fn();
    }
    fact('starting-file.after-shutdown', GLib.file_test(marker, GLib.FileTest.EXISTS));
}
if (!layer && settings)
    await switchLayer();
fact('done', 'yes');
