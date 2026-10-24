// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fake search providers for Spotlight: each provider named in PROBE_SPOTLIGHT_SLOW answers
// only after PROBE_SPOTLIGHT_SLOW_MS, by default past Spotlight's budget.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const SLOW_MS = Number(GLib.getenv('PROBE_SPOTLIGHT_SLOW_MS') ?? '1500');
const fact = (key, value) => printerr(`probe: ${key}=${value}`);
const slow = new Set((GLib.getenv('PROBE_SPOTLIGHT_SLOW') ?? '').split(',').filter(Boolean));

export const ITEMS = {
    'applications': [
        ['org.gnome.Nautilus.desktop', 'Files', 'Access and organise files'],
        ['org.gnome.DiskUtility.desktop', 'Disks', 'Manage drives and media'],
        ['org.gnome.baobab.desktop', 'Disk Usage Analyzer', 'Check folder sizes and available disk space'],
        ['disk-benchmark.desktop', 'Disk Benchmark', 'Time reads and writes'],
        ['disk-images.desktop', 'Disk Images', 'Write images to drives'],
        ['disk-cleaner.desktop', 'Disk Cleaner', 'Free up space'],
        ['org.gnome.Calculator.desktop', 'Calculator', 'Perform arithmetic, scientific or financial calculations'],
    ],
    'org.gnome.Settings.desktop': [
        ['disk-encryption', 'Disk Encryption', 'Privacy & Security'],
        ['disk-storage', 'Disk Storage', 'System'],
        ['removable-disks', 'Removable Disks', 'Apps'],
        ['disk-sleep', 'Disk Sleep', 'Power'],
    ],
    'org.gnome.Nautilus.desktop': [
        ['file:///home/u/disk-usage.csv', 'disk-usage-2026-10.csv', '~/Documents'],
        ['file:///home/u/disk-unlock.png', 'disk-unlock-board.png', '~/Pictures/Screenshots'],
        ['file:///home/u/Disk Images', 'Disk Images', '~/Downloads'],
        ['file:///home/u/diskspace.md', 'diskspace-notes.md', '~/apex/docs'],
        ['file:///home/u/disk-old.md', 'disk-old.md', '~/apex/docs'],
        ['file:///home/u/disk-new.md', 'disk-new.md', '~/apex/docs'],
    ],
};

function sum(text) {
    const m = text.match(/^(\d+(?:\.\d+)?)\s*([+\-*/])\s*(\d+(?:\.\d+)?)$/);
    if (!m)
        return null;
    const [a, b] = [Number(m[1]), Number(m[3])];
    return String({'+': a + b, '-': a - b, '*': a * b, '/': a / b}[m[2]]);
}

function wait(id, cancellable) {
    if (!slow.has(id))
        return Promise.resolve();
    return new Promise((resolve, reject) => {
        const timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, SLOW_MS, () => {
            resolve();
            return GLib.SOURCE_REMOVE;
        });
        cancellable?.connect(() => {
            fact('spotlight.cancelled', id);
            GLib.source_remove(timeoutId);
            reject(new Gio.IOErrorEnum({code: Gio.IOErrorEnum.CANCELLED, message: 'cancelled'}));
        });
    });
}

export class Provider {
    constructor(id) {
        this.id = id;
        this.appInfo = {get_id: () => id, get_icon: () => null};
    }

    async getInitialResultSet(terms, cancellable) {
        await wait(this.id, cancellable);
        const text = terms.join(' ');
        if (this.id === 'org.gnome.Calculator.desktop')
            return sum(text) === null ? [] : [text, `open:${text}`];
        return (ITEMS[this.id] ?? [])
            .filter(([, name]) => terms.every(t => name.toLowerCase().includes(t.toLowerCase())))
            .map(([id]) => id);
    }

    filterResults(ids, max) {
        return ids.slice(0, max);
    }

    getResultMetas(ids) {
        if (this.id === 'org.gnome.Calculator.desktop')
            return Promise.resolve(ids.map(id => ({id, name: id, description: ` = ${sum(id)}`, clipboardText: sum(id)})));
        const items = ITEMS[this.id] ?? [];
        return Promise.resolve(ids.map(id => items.find(i => i[0] === id))
            .map(([id, name, description]) => this.id === 'applications'
                ? {id, name, createIcon: () => null}
                : {id, name, description, createIcon: () => null}));
    }

    activateResult(id, terms) {
        fact('spotlight.activated', `${this.id}:${id} terms=${terms.join(' ')}`);
    }
}
