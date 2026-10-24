// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's Spotlight engine: one query fans out to the stock search providers, each within
// its own budget, and comes back as the drawn sections with their caps.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

export const BUDGET_MS = 1000;
export const CALCULATOR_APP = 'org.gnome.Calculator.desktop';

export const SECTIONS = [
    {name: 'Calculator', cap: 1, provider: CALCULATOR_APP},
    {name: 'Applications', cap: 4, provider: 'applications'},
    {name: 'Settings', cap: 3, provider: 'org.gnome.Settings.desktop'},
    {name: 'Files', cap: 4, provider: 'org.gnome.Nautilus.desktop'},
];

export function termsOf(text) {
    const trimmed = text.trim();
    return trimmed === '' ? [] : trimmed.split(/\s+/);
}

// Resolves to null when the budget runs out first, and cancels the provider's calls.
function withinBudget(work, cancellable, ms) {
    return new Promise(resolve => {
        let timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
            timeoutId = 0;
            cancellable.cancel();
            resolve(null);
            return GLib.SOURCE_REMOVE;
        });
        const settle = value => {
            if (timeoutId === 0)
                return;
            GLib.source_remove(timeoutId);
            timeoutId = 0;
            resolve(value);
        };
        work.then(settle, e => {
            if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                console.warn(`Apex: a Spotlight provider failed: ${e}`);
            settle(null);
        });
    });
}

function metasOf(provider, ids, cancellable) {
    return ids.length > 0 ? provider.getResultMetas(ids, cancellable) : Promise.resolve([]);
}

async function query(provider, terms, cap, cancellable) {
    const ids = await provider.getInitialResultSet(terms, cancellable);
    return metasOf(provider, provider.filterResults(ids, cap), cancellable);
}

function rowsOf(section, provider, metas, terms) {
    const calculator = section.name === 'Calculator';
    return metas.slice(0, section.cap).map(meta => ({
        title: calculator ? meta.clipboardText ?? meta.name : meta.name,
        subtitle: calculator ? meta.name : meta.description ?? '',
        createIcon: size => meta.createIcon?.(size) ?? null,
        // gnome-calculator gives its result a copy glyph; board 38 draws the app's icon.
        gicon: calculator ? provider.appInfo?.get_icon() ?? null : null,
        copyText: calculator ? meta.clipboardText ?? meta.name : null,
        activate: () => provider.activateResult(meta.id, terms),
    }));
}

// A sum offers Calculator as the first application, when it is installed.
async function withCalculatorFirst(apps, metas, cancellable) {
    const others = metas.filter(meta => meta.id !== CALCULATOR_APP);
    try {
        const [calculator] = await metasOf(apps, [CALCULATOR_APP], cancellable);
        return calculator ? [calculator, ...others] : metas;
    } catch {
        return metas;
    }
}

export class Search {
    constructor(providers, budgetMs = BUDGET_MS) {
        this._providers = providers;
        this._budgetMs = budgetMs;
        this._cancellables = [];
    }

    cancel() {
        this._cancellables.forEach(c => c.cancel());
        this._cancellables = [];
    }

    async run(terms) {
        this.cancel();
        if (terms.length === 0)
            return [];
        const sections = SECTIONS.filter(s => this._providers.has(s.provider));
        const found = await Promise.all(sections.map(section => {
            const cancellable = new Gio.Cancellable();
            this._cancellables.push(cancellable);
            const provider = this._providers.get(section.provider);
            return withinBudget(query(provider, terms, section.cap, cancellable), cancellable, this._budgetMs);
        }));
        const metasByName = new Map(sections.map((s, i) => [s.name, found[i]]));
        const apps = this._providers.get('applications');
        if (metasByName.get('Calculator')?.length > 0 && apps) {
            metasByName.set('Applications', await withCalculatorFirst(apps,
                metasByName.get('Applications') ?? [], new Gio.Cancellable()));
        }
        return sections
            .map(section => ({
                name: section.name,
                rows: rowsOf(section, this._providers.get(section.provider),
                    metasByName.get(section.name) ?? [], terms),
            }))
            .filter(section => section.rows.length > 0);
    }
}
