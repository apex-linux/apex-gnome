// SPDX-License-Identifier: GPL-2.0-or-later
//
// Board 36: while the app grid shows, the overview's pill is the launcher's own. It searches
// apps only and filters the grid in place; Super+Space still searches everything.

import Clutter from 'gi://Clutter';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as AppDisplay from '../../appDisplay.js';
import * as IconGrid from '../../iconGrid.js';
import * as Main from '../../main.js';

const HINT = 'Search apps';
const NO_RESULTS = 'No Results';
const NO_RESULTS_HINT = 'The launcher searches apps only. Super+Space searches everything.';
const GRID_MODES = [{rows: 4, columns: 7}];
const ICON_SIZE = 88;
const MAX_RESULTS = GRID_MODES[0].rows * GRID_MODES[0].columns;

// Apps only, folders flattened, by name as board 36 lists them.
function appsMatching(query) {
    const appSystem = Shell.AppSystem.get_default();
    return Shell.AppSystem.search(query).flat()
        .map(id => appSystem.lookup_app(id))
        .filter(app => app !== null)
        .sort((a, b) => a.get_name().localeCompare(b.get_name()));
}

export class LauncherSearch {
    get active() {
        return this._button?.checked ?? false;
    }

    enable() {
        const controls = Main.overview._overview._controls;
        this._entry = controls._searchEntry;
        this._appDisplay = controls._appDisplay;
        this._button = Main.overview.dash.showAppsButton;
        this._ids = [
            [this._button, this._button.connect('notify::checked', () => this._sync())],
            [this._entry.clutter_text, this._entry.clutter_text.connect('text-changed', () => this._filter())],
            [this._entry.clutter_text, this._entry.clutter_text.connect('activate', () => this._launchFirst())],
        ];
        this._sync();
    }

    disable() {
        this._ids?.forEach(([object, id]) => object.disconnect(id));
        this._ids = null;
        this._leave();
        this._button = null;
    }

    _sync() {
        if (this.active)
            this._enter();
        else
            this._leave();
    }

    _enter() {
        if (this._stockHint !== undefined)
            return;
        this._stockHint = this._entry.hint_text;
        this._entry.hint_text = HINT;
        this._entry.add_style_class_name('apex-launcher-search');
        this._filter();
    }

    _leave() {
        if (this._stockHint === undefined)
            return;
        this._entry.hint_text = this._stockHint;
        this._stockHint = undefined;
        this._entry.remove_style_class_name('apex-launcher-search');
        this._clear();
        this._entry.set_text('');
    }

    _filter() {
        const query = this._entry.get_text().trim();
        if (!this.active || query === '') {
            this._clear();
            return;
        }
        this._show(appsMatching(query).slice(0, MAX_RESULTS));
    }

    _build() {
        this._grid = new IconGrid.IconGrid({allow_incomplete_pages: true, page_valign: Clutter.ActorAlign.START});
        this._grid.setGridModes(GRID_MODES);
        this._grid.layout_manager.fixed_icon_size = ICON_SIZE;
        this._empty = new St.BoxLayout({
            style_class: 'apex-launcher-empty',
            orientation: Clutter.Orientation.VERTICAL,
            x_align: Clutter.ActorAlign.CENTER,
            x_expand: true,
        });
        this._empty.add_child(new St.Label({style_class: 'apex-launcher-empty-title', text: NO_RESULTS, x_align: Clutter.ActorAlign.CENTER}));
        this._empty.add_child(new St.Label({style_class: 'apex-launcher-empty-hint', text: NO_RESULTS_HINT, x_align: Clutter.ActorAlign.CENTER}));
        this._results = new St.BoxLayout({
            name: 'apexLauncherResults',
            orientation: Clutter.Orientation.VERTICAL,
            x_expand: true,
            y_expand: true,
        });
        this._results.add_child(this._grid);
        this._results.add_child(this._empty);
        this._appDisplay.add_child(this._results);
    }

    _show(apps) {
        if (!this._results)
            this._build();
        this._appDisplay._box.hide();
        this._icons?.forEach(icon => {
            this._grid.removeItem(icon);
            icon.destroy();
        });
        this._icons = apps.map(app => new AppDisplay.AppIcon(app, {isDraggable: false, expandTitleOnHover: false}));
        this._icons.forEach(icon => this._grid.addItem(icon));
        this._icons[0]?.add_style_pseudo_class('selected');
        this._grid.visible = this._icons.length > 0;
        this._empty.visible = this._icons.length === 0;
    }

    _clear() {
        this._results?.destroy();
        this._results = null;
        this._grid = null;
        this._empty = null;
        this._icons = null;
        this._appDisplay?._box.show();
    }

    _launchFirst() {
        if (this.active)
            this._icons?.[0]?.activate(Clutter.BUTTON_PRIMARY);
    }
}
