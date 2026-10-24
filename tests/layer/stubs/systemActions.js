// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/misc/systemActions.js.

export function getDefault() {
    return {activateAction: id => printerr(`probe: system-action=${id}`)};
}
