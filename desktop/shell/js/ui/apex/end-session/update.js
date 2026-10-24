// SPDX-License-Identifier: GPL-2.0-or-later

// apex-updated's Update1 for board 14's update card: the staged update, its changes and Apply.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

export const BUS_NAME = 'io.github.apex_linux.Apex.Update1';
export const OBJECT_PATH = '/io/github/apex_linux/Apex/Update1';
const IFACE = BUS_NAME;
const PROPERTIES_IFACE = 'org.freedesktop.DBus.Properties';
const ERROR_PREFIX = `${IFACE}.Error.`;

// The dialog never waits for the card: a slower reply means no card.
export const READ_TIMEOUT_MS = 900;
const CHANGES_TIMEOUT_MS = 5000;
const NO_TIMEOUT = GLib.MAXINT32;

export const STAGED = 'staged';
export const READY_FOR_REBOOT = 'ready-for-reboot';

// The subtitle's parts, each from the first package of its list that the update changes.
const PARTS = [['GNOME', ['gnome-shell']], ['Linux', ['kernel-cachyos', 'kernel']], ['Mesa', ['mesa-dri-drivers']]];

Gio._promisify(Gio.DBusConnection.prototype, 'call');

function _call(iface, method, params, replyType, timeoutMs) {
    return Gio.DBus.system.call(BUS_NAME, OBJECT_PATH, iface, method, params, replyType,
        Gio.DBusCallFlags.NONE, timeoutMs, null);
}

// What the card shows, or null for no card: another state, no staged digest, no bus or no reply in time.
export async function read() {
    let props;
    try {
        const reply = await _call(PROPERTIES_IFACE, 'GetAll', new GLib.Variant('(s)', [IFACE]),
            new GLib.VariantType('(a{sv})'), READ_TIMEOUT_MS);
        [props] = reply.recursiveUnpack();
    } catch {
        return null;
    }
    const staged = props.Staged ?? {};
    if (![STAGED, READY_FOR_REBOOT].includes(props.State) || !staged.digest)
        return null;
    return {state: props.State, digest: staged.digest, version: staged.version ?? ''};
}

function _version(evr) {
    const withoutEpoch = evr.replace(/^\d+:/, '');
    const dash = withoutEpoch.lastIndexOf('-');
    return dash > 0 ? withoutEpoch.slice(0, dash) : withoutEpoch;
}

// "GNOME 51.1, Linux 7.2.9, Mesa 26.1.2" from GetChanges, leaving out what the update keeps.
export async function changes() {
    const reply = await _call(IFACE, 'GetChanges', null, new GLib.VariantType('(a(sssss))'), CHANGES_TIMEOUT_MS);
    const [rows] = reply.deepUnpack();
    const newest = new Map(rows.filter(([, , , , to]) => to).map(([name, , , , to]) => [name, to]));
    return PARTS.map(([label, names]) => {
        const name = names.find(n => newest.has(n));
        return name ? `${label} ${_version(newest.get(name))}` : null;
    }).filter(Boolean).join(', ');
}

// Resolves once the stage is applied; rejects with {kind, message}, the message PolicyDenied's own.
export async function apply(digest) {
    try {
        await _call(IFACE, 'Apply', new GLib.Variant('(s)', [digest]), null, NO_TIMEOUT);
    } catch (e) {
        const remote = Gio.DBusError.get_remote_error(e) ?? '';
        Gio.DBusError.strip_remote_error(e);
        const kind = remote.startsWith(ERROR_PREFIX) ? remote.slice(ERROR_PREFIX.length) : 'Unknown';
        throw Object.assign(new Error(e.message), {kind});
    }
}
