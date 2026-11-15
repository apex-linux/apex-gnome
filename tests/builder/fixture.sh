#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Board 40's apex-gnome project (the spec's tree TG), a git repository on dock-focus-label with its three changes.
set -euo pipefail

usage() {
    cat <<USAGE
usage: tests/builder/fixture.sh DIR

Writes the apex-gnome project of boards 40 to 42 (docs/design/apex-code-boards-40-42.md,
section 7.1) into DIR: the files of its project tree, committed on main, then the branch
dock-focus-label with dock.js, feature.js and tests/layer/run.sh changed and not committed,
as its Version control view lists them. dock.js's outline has the board's symbols on the
board's lines: DockLabels 6, constructor 7, _nameOnFocus 15, _syncFocusLabel 28, _placeLabel 36.
USAGE
}

case ${1:-} in -h | --help | '') usage; exit 0 ;; esac
readonly DIR=$1
rm -rf -- "$DIR"
mkdir -p "$DIR"
cd "$DIR"

apex=desktop/shell/js/ui/apex
mkdir -p "$apex/dock" "$apex/glass" packaging tests/layer tests/shots

cat >"$apex/dock/dock.js" <<'EOF'
// SPDX-License-Identifier: GPL-3.0-or-later
// The dock's focus label: the name of the item keyboard focus is on.

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export class DockLabels {
    constructor(dock) {
        this._dock = dock;
        this._focusShowing = null;
        this._focusId = global.stage.connect('notify::key-focus',
            () => this._syncFocusLabel());
    }

    _nameOnFocus(item) {
        if (this._focusShowing === item)
            return;
        this._focusShowing?.hideLabel();
        this._focusShowing = item;
        if (item === null)
            return;
        item.showLabel();
        this._placeLabel(item);
    }

    _syncFocusLabel() {
        const focus = global.stage.key_focus;
        const item = this._dock.items.find(i => i.contains(focus)) ?? null;
        this._nameOnFocus(item);
    }

    // Above the item, kept on its monitor.

    _placeLabel(item) {
        const [x, y] = item.get_transformed_position();
        const label = item.label;
        const area = Main.layoutManager.getWorkAreaForMonitor(Main.layoutManager.primaryIndex);
        label.set_position(
            Math.max(area.x, Math.min(x, area.x + area.width - label.width)),
            y - label.height - 6);
    }

    destroy() {
        global.stage.disconnect(this._focusId);
        this._focusShowing = null;
    }
}
EOF

cat >"$apex/dock/feature.js" <<'EOF'
// SPDX-License-Identifier: GPL-3.0-or-later
import {DockLabels} from './dock.js';

export function enable(dock) {
    dock.labels = new DockLabels(dock);
    return dock.labels;
}

// Drops the labels, and with them the focus label.

export function disable(dock) {
    dock.labels?.destroy();
    dock.labels = null;
}
EOF

printf '// SPDX-License-Identifier: GPL-3.0-or-later\nexport const HIDE_DELAY_MS = 250;\n' >"$apex/dock/intellihide.js"
printf '// SPDX-License-Identifier: GPL-3.0-or-later\nexport const BLUR_RADIUS = 32;\n' >"$apex/glass/glass.js"
printf '// SPDX-License-Identifier: GPL-3.0-or-later\nexport const LAYER = "apex";\n' >"$apex/layer.js"
printf 'Name: apex-gnome\nVersion: 1\n' >packaging/apex-gnome.spec
printf '// SPDX-License-Identifier: GPL-3.0-or-later\nexport const name = dock => dock.labels._focusShowing?.name;\n' >tests/layer/probe.js
printf '#!/bin/sh\nset -eu\n' >tests/layer/run.sh
printf '#!/bin/sh\nset -eu\n' >tests/shots/shoot.sh
printf 'default:\n\tjust --list\n' >Justfile
cat >README.md <<'EOF'
# apex-gnome

Apex's GNOME Shell layer.


## Building

Run `just`.
EOF

git init -q -b main
git -c user.name=Apex -c user.email=apex@localhost add -A
git -c user.name=Apex -c user.email=apex@localhost commit -q -m 'apex-gnome'
git checkout -q -b dock-focus-label

# The branch's three changes, left unstaged: +12 −2, +3 −1 and +38 −0.
sed -i 's|^        this._focusShowing = null;$|        this._focusShowing = null;\n        this._focusItem = null;|' "$apex/dock/dock.js"
sed -i 's|^        if (this._focusShowing === item)$|        if (this._focusItem === item)\n            this._focusItem = null;\n        if (this._focusShowing === item)|' "$apex/dock/dock.js"
sed -i 's|^    dock.labels = null;$|    dock.labels = undefined;|' "$apex/dock/feature.js"
for i in $(seq 38); do printf 'echo "layer check %d"\n' "$i"; done >>tests/layer/run.sh
