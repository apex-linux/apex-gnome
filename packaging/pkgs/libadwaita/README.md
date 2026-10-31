# libadwaita in the rebuild lane

Fedora's libadwaita SRPM, rebuilt so that open windows follow the window radius Settings
writes: S2c's live radius, track C's step C1.3. The lane, `apex-lane`, and the formats of
the files here are in
[packaging/README.md](https://github.com/apex-linux/apex-image/blob/main/packaging/README.md#the-rebuild-lane).

| File | Role |
|---|---|
| `pkg.env` | the SRPM, the hold family `libadwaita`, and the one binary package the image takes; no Source1 |
| `spec-edit` | `.apexN` on Fedora's `Release:` |
| `series`, `patches/` | the hook hunk, `0001-apex-css` |
| `check.sh` | the lane checks of this package: `/usr/lib64/libadwaita-1.so.0` still exports `adw_style_manager_get_default` and holds the Adwaita stylesheet, and carries the `gtk-4.0/apex.css` path of `0001-apex-css` |

## What the build does to Fedora's package

- Fedora 45 ships libadwaita 1.10.0 (`libadwaita-1.10.0-2.fc45`), with no patch of its
  own; `%autosetup -p1` applies the series as `Patch1001`, at Fedora's fuzz 0.
- `Release: %{autorelease}.apexN` gives `1.10.0-2.fc45.apexN`, above Fedora's build and
  below its next one.
- On a failed build the lane holds the family and the image keeps Fedora's libadwaita;
  its degraded name is `adwaita`. Apps then read `apex.css` only at start, through the
  user's `gtk.css`.
- Checked 2026-10-30 against GNOME 51.1 (FEDORA-2026-2812a1754d): no libadwaita update
  is pending for F45. The patch applies at fuzz 0 to libadwaita-1.10.0-2.fc45 and the
  lane builds it with the 51.1 update in the buildroot.

## `0001-apex-css`

Settings (apex-session-agent) writes `$XDG_CONFIG_HOME/gtk-4.0/apex.css`, the
`--window-radius` on `:root` and its 0 px resets for maximised, fullscreen, tiled and
solid-csd windows, and replaces it atomically. The user's `gtk.css` imports it, but GTK
reads that once, at start.

The style manager of a display that loads the Adwaita stylesheet also loads `apex.css`
in a provider at `GTK_STYLE_PROVIDER_PRIORITY_USER + 1`, above the user's `gtk.css`, and
reloads it from a `GFileMonitor` on `gtk-4.0/` whenever the file is created, replaced,
moved or removed. A second monitor, on the config directory, re-arms the first when
`gtk-4.0/` is created or removed and loads the file then. Without it, an app started
before the first login's `apex.css` (and its `gtk-4.0/`) kept the stock radius: GLib
watches a missing directory by polling every few seconds and then reports the directory,
not the file. A missing file means no provider and no warning. With `GTK_THEME` set,
or Granite present, libadwaita loads no stylesheet of its own, and the patch adds nothing.
Flatpak apps use their runtime's libadwaita and read the file only at start.

| Patch | Upstream files | Changed lines | Hunks |
|---|---|---|---|
| `0001-apex-css` | `src/adw-style-manager.c` | +79 | `APEX_CSS`; the provider and both monitors in the struct; `load_apex_css()`, the monitors' callback, `watch_apex_dir()` and `watch_apex_css()`; the call in `constructed()`, beside the Adwaita providers; all three cleared in `dispose()` |

Budget: at most 80 changed lines in upstream files, in hook hunks only. In use: 79 lines
in 1 file. The patch is `git format-patch` output against Fedora's `%prep` tree, with
`a/` and `b/` prefixes, applied with `-p1` (apex-image's `just pkg-prep libadwaita` and
`just pkg-export libadwaita`).

## Building it here

```bash
just libadwaita-lane    # podman or docker: apex-lane's container half in fedora:45
just libadwaita-radius  # --stock, the built RPM's rewrite case, then its --late case, under an open Ptyxis
```

`tests/lib/lane.sh libadwaita` runs `apex-lane in-container build libadwaita` as the
builder VM does, without the signing and the store; the RPMs and logs land in
`_build/libadwaita/out/`.

`tests/libadwaita/radius-test.sh` runs a headless gnome-shell (`tests/lib/headless.sh`),
writes `apex.css` with a 14 px radius, and opens Ptyxis, a libadwaita window, in light.
Its automation script, `radius-probe.js`, samples a pixel inside the window's top-left
corner and one on the header bar on the same row, rewrites `apex.css` with 0 px through
`g_file_set_contents()`, and polls. On the built RPM the corner must match the header
bar within 1 s; with `--stock`, on Fedora's libadwaita, it must still differ after 3 s.
With `--late`, a first login, Ptyxis starts with no `gtk-4.0/` at all and must be
stock-rounded; the script then creates `gtk-4.0/` and writes `apex.css` at 0 px, and the
corner must match within 1 s. No Ptyxis warning or critical may show during `--late` but
VTE's own `columns >= 1` one, which `--stock` shows too. In every mode the window must
still be Ptyxis's at the end and the header-bar sample unchanged, so a crashed or closed
window cannot pass. Each run starts without a `gtk-4.0/`. CI runs `--stock`, the rewrite
case and `--late` after the lane.
