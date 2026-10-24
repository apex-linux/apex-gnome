// SPDX-License-Identifier: GPL-3.0-or-later
//
// The test image has no Polkit typelib: run.sh points the polkit feature's gi://Polkit here.
// The probe sets reply: 'answer', 'error' or 'cancel'.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const ACTIONS = [
    ['org.freedesktop.packagekit.system-update', 'The PackageKit Project'],
    ['io.github.apex-linux.apex.update.rollback', 'Apex'],
];

const stub = {reply: 'answer', calls: 0};

function _settle(callback) {
    stub.calls++;
    GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
        callback(null, stub.reply);
        return GLib.SOURCE_REMOVE;
    });
}

function _finish(reply, value) {
    if (reply === 'error')
        throw new Gio.IOErrorEnum({code: Gio.IOErrorEnum.FAILED, message: 'polkitd is not running'});
    if (reply === 'cancel')
        throw new Gio.IOErrorEnum({code: Gio.IOErrorEnum.CANCELLED, message: 'cancelled'});
    return value;
}

class Authority {
    static get_async(_cancellable, callback) {
        _settle(callback);
    }

    static get_finish(reply) {
        return _finish(reply, new Authority());
    }

    enumerate_actions(_cancellable, callback) {
        _settle(callback);
    }

    enumerate_actions_finish(reply) {
        return _finish(reply, ACTIONS.map(([id, vendor]) => ({
            get_action_id: () => id,
            get_vendor_name: () => vendor,
        })));
    }
}

export default {Authority, stub};
