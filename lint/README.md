# lint

| File | What it is |
|---|---|
| `eslint.config.js` | gnome-shell 51.0's [`eslint.config.js`](https://gitlab.gnome.org/GNOME/gnome-shell/-/blob/51.0/eslint.config.js), the version the recipe builds. Its rules are unchanged; only the `files` (this repository's paths) and the `ignores` (gnome-shell's tree, absent here) differ |
| `package.json`, `package-lock.json` | the tools that configuration needs, at the versions gnome-shell 51.0 pins in [`tools/package-lock.json`](https://gitlab.gnome.org/GNOME/gnome-shell/-/blob/51.0/tools/package-lock.json): eslint 9.38.0, `@eslint/config-helpers` 0.4.1 and `eslint-config-gnome` at commit `c479d059`. The lock is gnome-shell's, less `ci-run-eslint`, `commander` and `eslint-formatter-junit`, which only gnome-shell's CI wrapper uses |
| `eslint.sh` | `npm ci` into `lint/node_modules`, then eslint on `desktop/shell/js` and `tests/{layer,shots}/*.js` |
| `theme.sh` | sassc on the three sheets, as the rebuilt gnome-shell compiles them |

Fedora 45 packages no eslint, so the tools come from npm, pinned by the lockfile and
installed with `npm ci`. gnome-shell's rules live in `eslint-config-gnome`, which is not
on npm's registry; like gnome-shell, the lock takes it from GNOME's GitLab at a fixed commit.

When the recipe moves to a new gnome-shell release, take both files from that tag again.
