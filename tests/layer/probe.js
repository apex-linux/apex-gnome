// SPDX-License-Identifier: GPL-3.0-or-later
//
// Facts go to stderr: it is unbuffered, so the facts before an abort survive.
//
// Environment:
//   APEX_SHELL_DIR   desktop/shell of this repository
//   PROBE_MODE       the session mode (default user)
//   PROBE_LAYER_OFF  1: set layer-enabled=false first (GSETTINGS_BACKEND=memory)
//   PROBE_DISABLED   disabled-features, comma-separated
//   PROBE_BROKEN     1: load a layer module that does not exist
//   PROBE_ENABLE     1: run the enable phase
//   PROBE_WAIT       seconds of main loop after enable (for the abort fault)
// The layer itself reads APEX_SHELL_SAFE, APEX_SHELL_TEST_FAULT and /proc/cmdline.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const root = GLib.getenv('APEX_SHELL_DIR');
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
    'io.github.sekirokenjii.Apex.Desktop', true);
if (schema) {
    const settings = new Gio.Settings({settings_schema: schema});
    if (GLib.getenv('PROBE_LAYER_OFF') === '1')
        settings.set_boolean('layer-enabled', false);
    const disabled = GLib.getenv('PROBE_DISABLED');
    if (disabled)
        settings.set_strv('disabled-features', disabled.split(','));
}

const Hooks = await import(`file://${root}/js/ui/apex/hooks.js`);
fact('safe', Hooks.safe());
const layerUrl = GLib.getenv('PROBE_BROKEN') === '1'
    ? `file://${root}/js/ui/apex/no-such-layer.js`
    : `file://${root}/js/ui/apex/layer.js`;
const layer = await Hooks.loadLayer(() => import(layerUrl));
fact('layer', layer ? 'loaded' : 'null');

const stock = {colorScheme: 'prefer-dark', hasOverview: true};
for (const mode of ['user', 'unlock-dialog', 'gdm', 'initial-setup']) {
    const params = Hooks.value('session-mode', {...stock}, mode);
    fact(`scheme.${mode}`, `${params.colorScheme}${params.hasOverview ? '' : ' (params lost)'}`);
}
fact('test-fault', Hooks.value('test-fault', 'stock'));

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
    fact('scheme.user.after-enable', Hooks.value('session-mode', {...stock}, 'user').colorScheme);
    const wait = Number(GLib.getenv('PROBE_WAIT') ?? '0');
    if (wait > 0) {
        const loop = new GLib.MainLoop(null, false);
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, wait, () => {
            loop.quit();
            return GLib.SOURCE_REMOVE;
        });
        loop.run();
        fact('survived', `${wait}s`);
    }
    for (const [signal, fn] of [...handlers.values()]) {
        if (signal === 'shutdown')
            fn();
    }
    fact('starting-file.after-shutdown', GLib.file_test(marker, GLib.FileTest.EXISTS));
}
fact('done', 'yes');
