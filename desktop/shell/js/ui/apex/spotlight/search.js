// SPDX-License-Identifier: GPL-2.0-or-later
//
// DESIGN's Spotlight engine: one query fans out to the stock search providers, each within
// its own budget, and comes back as the drawn sections with their caps.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {tileOf} from './tiles.js';

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
        key: `${section.name}/${meta.id}`,
        title: calculator ? meta.clipboardText ?? meta.name : meta.name,
        subtitle: calculator ? meta.name : meta.description ?? '',
        createIcon: size => meta.createIcon?.(size) ?? null,
        // gnome-calculator gives its result a copy glyph; board 38 draws the app's icon.
        gicon: calculator ? provider.appInfo?.get_icon() ?? null : null,
        tile: section.name === 'Settings' ? tileOf(meta.id) : undefined,
        copyText: calculator ? meta.clipboardText ?? meta.name : null,
        activate: () => provider.activateResult(meta.id, terms),
    }));
}

// Fetched with the apps, so that a sum can offer Calculator first whichever answers last.
async function calculatorApp(apps, cancellable) {
    try {
        const [meta] = await metasOf(apps, [CALCULATOR_APP], cancellable);
        return meta ?? null;
    } catch {
        return null;
    }
}

async function appsQuery(apps, terms, cap, cancellable) {
    const [metas, calculator] = await Promise.all([
        query(apps, terms, cap, cancellable),
        calculatorApp(apps, cancellable),
    ]);
    return {metas, calculator};
}

export class Search {
    constructor(providers, budgetMs = BUDGET_MS) {
        this._providers = providers;
        this._budgetMs = budgetMs;
        this._cancellables = [];
        this._run = 0;
    }

    cancel() {
        this._run++;
        this._cancellables.forEach(c => c.cancel());
        this._cancellables = [];
    }

    // onUpdate(sections, done) runs as each provider answers or runs out of budget, the
    // sections always in SECTIONS' order.
    run(terms, onUpdate) {
        this.cancel();
        if (terms.length === 0) {
            onUpdate([], true);
            return Promise.resolve();
        }
        const run = this._run;
        const sections = SECTIONS.filter(s => this._providers.has(s.provider));
        const found = new Map();
        return Promise.all(sections.map(async section => {
            const cancellable = new Gio.Cancellable();
            this._cancellables.push(cancellable);
            const provider = this._providers.get(section.provider);
            const work = section.name === 'Applications'
                ? appsQuery(provider, terms, section.cap, cancellable)
                : query(provider, terms, section.cap, cancellable).then(metas => ({metas}));
            found.set(section.name, await withinBudget(work, cancellable, this._budgetMs));
            if (run === this._run)
                onUpdate(this._assemble(sections, found, terms), found.size === sections.length);
        }));
    }

    _assemble(sections, found, terms) {
        const sum = found.get('Calculator')?.metas.length > 0;
        return sections
            .map(section => {
                const result = found.get(section.name);
                let metas = result?.metas ?? [];
                if (section.name === 'Applications' && sum && result?.calculator)
                    metas = [result.calculator, ...metas.filter(m => m.id !== CALCULATOR_APP)];
                return {name: section.name, rows: rowsOf(section, this._providers.get(section.provider), metas, terms)};
            })
            .filter(section => section.rows.length > 0);
    }
}
