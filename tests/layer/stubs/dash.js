// SPDX-License-Identifier: GPL-3.0-or-later
//
// run.sh installs this as js/ui/dash.js: the parts of upstream's Dash that ApexDock uses.

import GObject from 'gi://GObject';

import St from '../../../St.js';

const printFact = (key, value) => printerr(`probe: ${key}=${value}`);

export class BaseIconStub {
    constructor(name) {
        this.name = name;
        this.iconSize = 64;
        this._iconBin = new St.Bin();
    }

    setIconSize(size) {
        this.iconSize = size;
    }

    ease(props) {
        Object.assign(this, props);
    }
}

export const DashItemContainer = GObject.registerClass({
    Signals: {'destroy': {}},
}, class DashItemContainer extends GObject.Object {
    _init() {
        super._init();
        this.visible = true;
        this.label = new St.Label({style_class: 'dash-label'});
        this.child = null;
    }

    setChild(actor) {
        this.child = actor;
    }

    setLabelText(text) {
        this.labelText = text;
    }

    show() {
        this.visible = true;
    }

    destroy() {
        this.emit('destroy');
    }
});

export const Dash = GObject.registerClass({
    Signals: {'icon-size-changed': {}, 'destroy': {}, 'style-changed': {}},
}, class Dash extends GObject.Object {
    _init() {
        super._init();
        this.iconSize = 64;
        this.visible = true;
        this._styleClasses = new Set();
        this._box = new St.Widget();
        this._dashContainer = new St.Widget();
        this._dashContainer.add_child(this._box);
        this._showAppsIcon = new St.Widget({name: 'showApps'});
        this._showAppsIcon.label = new St.Label({style_class: 'dash-label'});
        this._showAppsIcon.icon = new BaseIconStub('Show Apps');
        this._showAppsIcon.child = new St.Button();
        this._showAppsIcon.child._delegate = this._showAppsIcon;
        this._dashContainer.add_child(this._showAppsIcon);
        this._dashContainer._parent = this;
        this.showAppsButton = new St.Button({checked: false});
        for (const name of (globalThis.PROBE_FAVOURITES ?? []))
            this._box.add_child(this._createAppItem({get_name: () => name}));
    }

    _hookUpLabel() {}

    _createAppItem(app) {
        const item = new St.Widget({name: app.get_name()});
        item.label = new St.Label({style_class: 'dash-label'});
        item.child = new St.Button();
        item.child.icon = new BaseIconStub(app.get_name());
        item.child._delegate = {app, icon: item.child.icon};
        return item;
    }

    add_style_class_name(name) {
        this._styleClasses.add(name);
    }

    remove_style_class_name(name) {
        this._styleClasses.delete(name);
    }

    has_style_class_name(name) {
        return this._styleClasses.has(name);
    }

    get_stage() {
        return null;
    }

    destroy() {
        printFact('dock.destroyed', this.name);
        this.emit('destroy');
    }
});
