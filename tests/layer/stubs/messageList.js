// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/messageList.js: a notification group and the calendar's list.

import St from '../../../St.js';

// A group of one or more notifications, collapsed as stock first shows it.
export class NotificationMessageGroup extends St.Widget {
    constructor(name, count) {
        super({name, style_class: 'message-notification-group'});
        this._expanded = false;
        this._cover = new St.Widget({name: 'cover'});
        this._headerBox = new St.BoxLayout({name: 'header', visible: false});
        this.layout_manager = {expansion: 0};
        this.fades = 0;
        for (let i = 0; i < count; i++)
            this.add_child(new St.Bin({layout_manager: {scalingEnabled: false}, child: new St.Widget()}));
        this.add_child(this._cover);
        this.add_child(this._headerBox);
    }

    _updateStackedMessagesFade() {
        this.fades++;
    }

    notify(property) {
        this.emit(`notify::${property}`);
    }
}

class MessageView extends St.Widget {
    add_child(child) {
        super.add_child(child);
        this.emit('child-added', child);
    }
}

// calendar.js's CalendarMessageList: the view, the placeholder, and Clear alone in the footer.
export function newCalendarMessageList() {
    const view = new MessageView({name: 'view'});
    view.add_child(new St.Bin({child: new NotificationMessageGroup('Mail', 3)}));
    const footer = new St.BoxLayout({name: 'footer', style_class: 'message-list-controls'});
    const clear = new St.Button({name: 'clear', label: 'Clear', x_expand: true, x_align: 1});
    footer.add_child(clear);
    return {_messageView: view, _placeholder: new St.Widget({name: 'placeholder', visible: false}), _clearButton: clear};
}
