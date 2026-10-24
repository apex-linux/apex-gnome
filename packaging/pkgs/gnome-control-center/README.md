# gnome-control-center in the rebuild lane

Fedora's gnome-control-center SRPM, rebuilt with the Apex Settings inside it: the Apex
Desktop panel, the coloured sidebar tiles and the Software Updates page of the design
canvas's boards 11, 18 and 26, and the restyled Appearance and Power panels of boards
23 and 24.
[ADR 0014](https://github.com/apex-linux/apex/blob/main/docs/adr/0014-engine-level-desktop.md)
puts it in the lane; ROADMAP track C, S2c and S2d define its series. The lane,
`apex-lane`, and the formats of the files here are in
[packaging/README.md](https://github.com/apex-linux/apex-image/blob/main/packaging/README.md#the-rebuild-lane).

| File | Role |
|---|---|
| `pkg.env` | the SRPM, the hold family `gnome-control-center`, the two binary packages the image takes, and Source1 (`desktop/control-center/`, unpacked as `panels/apex/`) |
| `spec-edit` | anchored edits to Fedora's spec: `.apexN`, `Source1`, and the `%prep` line that unpacks it |
| `series`, `patches/` | the hook hunks, one patch per concern |
| `check.sh` | the lane checks of this package: upstream's resource still in `/usr/bin/gnome-control-center`, every resource file of Source1 in `/org/gnome/Settings/apex`, the Apex marker, the panel's template, desktop files and icon, the "Apex Tweaks" entry, the `-filesystem` directories and `org.gnome.Settings.desktop` |

## What the build does to Fedora's package

- Fedora 45 ships gnome-control-center 51.0 (`gnome-control-center-51.0-2.fc45`, in
  `fedora`), on GTK 4.24 and libadwaita 1.10.
- `Release: %{autorelease}.apexN` gives `51.0-2.fc45.apexN`, above Fedora's build and
  below its next one.
- `install=` takes `gnome-control-center` and `gnome-control-center-filesystem`, ADR
  0014's hold family: the main package requires `-filesystem`, a noarch package of
  directories, so holding one without the other could pair a held Settings with a newer
  Fedora `-filesystem`.
- Fedora's spec has only `Source0` and no patch, so the Apex archive is `Source1`:
  `apex-control-center-<tree>.tar`, the `git archive` of `desktop/control-center/`.
  `%prep` unpacks it at the top of the tree with `tar -xkf` right after `%autosetup`,
  which gives `panels/apex/` and never replaces an upstream file. Nothing is moved or
  deleted. The series follows as `Patch1001` and up, and `%autosetup -p1` applies it with
  `patch`, at Fedora's fuzz 0.

### How a panel registers in 51.0

| Piece | Where | What an Apex panel needs |
|---|---|---|
| The panel list | `default_panels[]` in `shell/cc-panel-loader.c`: an id, its `get_type()` and an optional static init function, compiled in; no plugin API | an `extern` and a `PANEL_TYPE ("apex", …)` line |
| Its metadata | `gnome-<id>-panel.desktop` in `/usr/share/applications`, read by `cc_panel_loader_fill_model()`: name, icon, keywords and the category, which picks the sidebar section | an added `gnome-apex-panel.desktop.in` |
| The build | `panels/meson.build` runs `subdir()` for each id, each adding a static library to `panels_libs`; the executable links them | `subdir('apex')` |
| The sidebar order | `panel_order[]` in `shell/cc-panel-list.c`; an id missing from it sorts as index 0, the top; a separator shows above a row whose predecessor in the list is `"separator"` | `"apex"` and a `"separator"` at its head; 0002 (C2) reorders it |
| Opening by name | `gnome-control-center <id>`, through `CcApplication`'s command line and the same list | nothing more |

So a panel is added files plus three short hooks. The Apex panel and its pages live in
`panels/apex/`; the System panel's Software Updates row (C2) is one more hook in
`panels/system/`.

## The Apex Desktop panel

Board 11, both scroll positions: `gnome-control-center apex`, first in the sidebar, and
the launcher's "Apex Tweaks" (`io.github.apex_linux.Apex.Tweaks.desktop`) opens it.

- **The header**, a card: a 72 px tile of the current wallpaper (`picture-uri` or
  `picture-uri-dark`, following Dark Style) with the Apex diamond in the accent, "Apex
  Desktop", and "Version 45.YYYYMMDD.N · GNOME Shell 51.0 on Wayland · Fedora Linux 45":
  the booted image's `version` from `/usr/share/apex/manifest.json`, the shell's
  `ShellVersion` over D-Bus with `XDG_SESSION_TYPE`, and `NAME` and `VERSION_ID` from
  os-release. A part that cannot be read is left out.
- **The rows** are DESIGN's ["Apex Desktop panel rows"](https://github.com/apex-linux/apex/blob/main/docs/DESIGN.md#apex-desktop-panel-rows),
  each bound with `g_settings_bind`, so a change on either side shows at once:
  `AdwSwitchRow`s, and `AdwToggleGroup`s for Icon Size (`dock-icon-size`), Corner
  Radius (0, 8, 14, 20; any other `window-corner-radius` selects none) and Titlebar
  Buttons (`appmenu:minimize,maximize,close` or `appmenu:close`; another layout selects
  none). The two rows that write two keys bind the first and write the second when the
  row changes: Show Date in Clock writes `clock-show-weekday`, and Reduce Motion
  (`enable-animations`, inverted) sets a11y `reduced-motion` to `'reduce'` or resets
  it, as Accessibility does. Their handlers connect after the bindings, so opening the
  panel writes nothing.
- **Without apex-desktop's schema** the panel shows an explanation instead of the rows.
  A schema without one of the Apex keys hides that row and logs it.

## `desktop/control-center/`

Every file is GPL-2.0-or-later, gnome-control-center's licence, and sits under
`panels/apex/`, the one path `source1_paths` allows; `tests/control-center/selftest.sh`
checks both, and that every patch is the owner's.

| Path | What it is |
|---|---|
| `panels/apex/meson.build` | the panel's static library in `panels_libs`; `apex_shell_sources`, the Apex resource, compiled into the executable's sources by 0001; the two desktop files and the icon |
| `panels/apex/apex.gresource.xml` | the Apex resource, `/org/gnome/Settings/apex`: the panel's template and the sheet; outside the files libadwaita loads from the base path by itself |
| `panels/apex/apex.css` | the Apex sheet, with the marker `/*! apex-control-center */`: the header's tile, diamond and type |
| `panels/apex/cc-apex-panel.{c,h,blp}` | the panel: its rows and their bindings, and the missing-schema page |
| `panels/apex/cc-apex-header.{c,h}` | the header: the wallpaper tile and the version line |
| `panels/apex/gnome-apex-panel.desktop.in` | the panel's name, icon, keywords and section for the sidebar and search |
| `panels/apex/io.github.apex_linux.Apex.Tweaks.desktop.in` | "Apex Tweaks" in the launcher |
| `panels/apex/icons/org.gnome.Settings-apex-symbolic.svg` | the Apex diamond, the panel's sidebar icon |

## The series

| Patch | Upstream files | Changed lines | Hunks |
|---|---|---|---|
| `0001-apex-desktop` | `panels/meson.build`, `shell/meson.build`, `shell/cc-panel-loader.c`, `shell/cc-panel-list.c` | +7 | `subdir('apex')` after upstream's panels; `apex_shell_sources` added to `shell_sources`; the panel registered as `apex`; `"apex"` and a separator at the head of `panel_order[]` |

The resource goes into the executable as sources, not as a static library in
`panels_libs`: the linker takes an archive member only when something references it,
and nothing upstream does.

Budget (ADR 0014): at most 150 changed lines in upstream files, in hook hunks only; the
added files under `panels/apex/` do not count. In use: 7 lines in 4 files.

The patches are `git format-patch` output against Fedora's `%prep` tree, with `a/` and
`b/` prefixes, applied with `-p1`. Write them with apex-image's
`just pkg-prep gnome-control-center` and `just pkg-export gnome-control-center`, as for
gnome-shell ([its README](../gnome-shell/README.md#changing-a-patch-or-rebasing)).

## Building it here

```bash
just control-center-test   # desktop/control-center's licence and paths; the patches' From: lines
just control-center-lane   # podman or docker: apex-lane's container half in fedora:45
just control-center-run    # podman or docker: the built Settings in a headless gnome-shell
```

`tests/lib/lane.sh gnome-control-center` builds `apex-lane` from a pinned apex-image commit and
runs its container half, `apex-lane in-container build gnome-control-center`, as the
builder VM does: the SRPM's signature, `spec-edit`, the series at fuzz 0, the exact-tree
check, `rpmbuild -ba` with Fedora's `%check`, the lane checks and `check.sh`. It leaves
out what the VM adds, the signing and the store. The RPMs and logs land in
`_build/gnome-control-center/out/`. CI runs it on every push.

`tests/control-center/run.sh` installs those RPMs in a fedora:45 container and runs
gnome-shell headless at scale 2 for the user `apex`, with apex-desktop's schema from
`tests/layer/fixtures/`, a `manifest.json`, two flat test wallpapers, G2's `fixtures.py`
on the system bus and its `clock.c` holding the wall clock. Its automation script,
`probe.js`, opens `gnome-control-center apex` at board 11's window size and captures it
at the top and scrolled to the end, light and dark. `bindings.py` then checks every row
through AT-SPI, both ways: each key written with GSettings shows on its row, and each
switch or toggle the row offers writes its key (and the second key of the two-key rows).
A third run without the schema checks the explanation. CI runs it after the lane and
keeps the captures as the `control-center-shots` artifact.

In these captures the sidebar has no separator under Apex Desktop: the fixtures offer no
Wi-Fi device, so the Wi-Fi row, the one after the separator in `panel_order[]`, is not
there, and upstream draws a separator only above the row that follows one in the list.
On the laptop the Wi-Fi row is there and the separator shows.
