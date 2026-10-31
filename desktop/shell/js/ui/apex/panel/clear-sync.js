// SPDX-License-Identifier: GPL-2.0-or-later
//
// calendar.js binds Clear's visibility to the placeholder's without SYNC_CREATE, so an empty list
// shows Clear until a first notification comes and goes. This syncs it once, as SYNC_CREATE would.

import * as Main from '../../main.js';

let _list = null;
let _stockVisible = null;
let _placeholderId = 0;
let _sessionId = 0;

function _attach() {
    const list = Main.panel.statusArea.dateMenu?._messageList;
    if (!list || list === _list)
        return;
    _detach();
    _list = list;
    const {_clearButton: clear, _placeholder: placeholder} = list;
    _stockVisible = clear.visible;
    // Once the placeholder changes, stock's binding has synced Clear and nothing is left to restore.
    _placeholderId = placeholder.connect('notify::visible', () => (_stockVisible = null));
    clear.visible = !placeholder.visible;
}

function _detach() {
    if (!_list)
        return;
    _list._placeholder.disconnect(_placeholderId);
    if (_stockVisible !== null)
        _list._clearButton.visible = _stockVisible;
    _list = null;
    _stockVisible = null;
    _placeholderId = 0;
}

export function configure() {}

export function enable() {
    _sessionId = Main.sessionMode.connect('updated', _attach);
    _attach();
}

export function disable() {
    if (_sessionId)
        Main.sessionMode.disconnect(_sessionId);
    _sessionId = 0;
    _detach();
}
