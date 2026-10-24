// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/apex/end-session/update.js: Update1 as globalThis.update1 says,
// each Apply logged in globalThis.endSessionCalls.

export const STAGED = 'staged';
export const READY_FOR_REBOOT = 'ready-for-reboot';

const scenario = () => globalThis.update1 ?? {read: null};

export function read() {
    return Promise.resolve(scenario().read);
}

export function changes() {
    return Promise.resolve('GNOME 51.1, Linux 7.2.9, Mesa 26.1.2');
}

export function apply(digest) {
    (globalThis.endSessionCalls ??= []).push(`apply:${digest}`);
    const {applyError} = scenario();
    return applyError ? Promise.reject(Object.assign(new Error(applyError), {kind: 'PolicyDenied'})) : Promise.resolve();
}
