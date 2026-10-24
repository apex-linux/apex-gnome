// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/messageList.js: messages, a group, and calendar.js's parts that
// carry patch 0012's hooks.

import St from '../../../St.js';
import * as Hooks from './apex/hooks.js';

class MessageHeader extends St.BoxLayout {
    constructor(source) {
        super({style_class: 'message-header'});
        this.sourceIcon = new St.Icon({name: 'source-icon'});
        this.content = new St.BoxLayout({name: 'content'});
        this.content.add_child(new St.Label({name: 'title', text: source.title}));
        this.content.add_child(new St.Label({name: 'time', text: 'now'}));
        this.add_child(this.sourceIcon);
        this.add_child(this.content);
        Hooks.run('message-header', this, this.sourceIcon, this.content);
    }
}

export class Message extends St.Button {
    constructor(source, gicon = null) {
        super({style_class: 'message'});
        this.header = new MessageHeader(source);
        this.add_child(this.header);
        Hooks.run('message', this, source);
        this.icon = gicon;
    }

    get icon() {
        return this._gicon;
    }

    set icon(icon) {
        this._gicon = Hooks.value('message-icon', icon, this);
    }
}

// A group as stock first shows it: collapsed, its second card styled under the first.
export class NotificationMessageGroup extends St.Widget {
    constructor(source, count) {
        super({name: source.title, style_class: 'message-notification-group'});
        this._expanded = false;
        this.count = count;
        this.layout_manager = {name: 'expander'};
        for (let i = 0; i < count; i++) {
            const item = new St.Bin({child: new Message(source)});
            if (i === 1)
                item.child.add_style_pseudo_class('second-in-stack');
            this.add_child(item);
        }
        this.cover = new St.Widget({name: 'cover'});
        this.header = new St.BoxLayout({name: 'header', visible: false});
        this.add_child(this.cover);
        this.add_child(this.header);
        Hooks.run('message-group', this, this.cover, this.header);
    }

    get expanded() {
        return Hooks.value('message-group-expanded', this._expanded || this.count === 1, this);
    }

    notify(property) {
        this.emit(`notify::${property}`);
    }
}

// calendar.js's CalendarMessageList: Clear alone in the footer, hidden while the placeholder shows.
export function newCalendarMessageList() {
    const footer = new St.BoxLayout({name: 'footer', style_class: 'message-list-controls'});
    const clear = new St.Button({name: 'clear', label: 'Clear', x_expand: true, x_align: 1});
    const placeholder = new St.Widget({name: 'placeholder', visible: false});
    footer.add_child(clear);
    Hooks.run('message-list-controls', footer, clear, placeholder);
    return {footer, clear, placeholder};
}

// calendar.js's Calendar: the month header between its chevrons, and a week of day buttons.
export function newCalendar() {
    const calendar = new St.Widget({name: 'calendar'});
    const topBox = new St.BoxLayout({name: 'header'});
    const label = new St.Label({name: 'month', text: 'September', x_align: 2});
    [new St.Button({name: 'back'}), label, new St.Button({name: 'forward'})].forEach(c => topBox.add_child(c));
    Hooks.run('calendar-header', calendar, topBox, label);
    const days = [27, 28, 29].map(day => {
        const button = new St.Button({style_class: `calendar-day${day === 28 ? ' calendar-day-with-events' : ''}`,
            child: new St.Label({text: `${day}`})});
        Hooks.run('calendar-day', button);
        return button;
    });
    return {calendar, topBox, days};
}
