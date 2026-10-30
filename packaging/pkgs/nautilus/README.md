# nautilus in the rebuild lane

Fedora's nautilus SRPM, rebuilt with the Apex Files widgets inside it: the window of the
design canvas's boards 27 ("Files: Home"), 28 ("Files: list and details") and 29
("Files: search").
[ADR 0014](https://github.com/apex-linux/apex/blob/main/docs/adr/0014-engine-level-desktop.md)
puts nautilus in the lane; ROADMAP S2d and S7 define its series. The lane, `apex-lane`,
and the formats of the files here are in
[packaging/README.md](https://github.com/apex-linux/apex-image/blob/main/packaging/README.md#the-rebuild-lane).

| File | Role |
|---|---|
| `pkg.env` | the SRPM, the hold family `nautilus`, the two binary packages the image takes, and Source1 (`desktop/nautilus/`, unpacked as `src/apex/`) |
| `spec-edit` | anchored edits to Fedora's spec: `.apexN`, `Source1`, and the `%prep` line that unpacks it |
| `series`, `patches/` | the hook hunks, one patch per concern |
| `check.sh` | the lane checks of this package: upstream's resource still in `/usr/bin/nautilus`, every resource file of Source1 in `/org/gnome/nautilus/apex`, the Apex marker and the sheet of every Apex widget, the 72 px default zoom in the schema, Fedora's own patch, and `libnautilus-extension.so.4` |

## What the build does to Fedora's package

- Fedora 45 ships nautilus 51.0.1 (`nautilus-51.0.1-1.fc45`, in `fedora`; 51.1 waits in
  `updates-testing`, which the image does not take), on GTK 4.24 and libadwaita 1.10.
- `Release: %{autorelease}.apexN` gives `51.0.1-1.fc45.apexN`, above Fedora's build and
  below its next one.
- `install=` takes `nautilus` and `nautilus-extensions`: `nautilus` requires
  `nautilus-extensions` at its own exact version and release, so Fedora's would not do.
  `nautilus-devel` is built and not installed. The extensions that link
  `libnautilus-extension.so.4` (papers-nautilus, nautilus-python and the rest) keep
  working: the library is Fedora's source, unchanged.
- Fedora's spec has only `Source0`, so the Apex archive is `Source1`:
  `apex-nautilus-<tree>.tar`, the `git archive` of `desktop/nautilus/`. `%prep` unpacks it
  at the top of the tree with `tar -xkf` right after `%autosetup`, which gives
  `src/apex/` and never replaces an upstream file. Nothing is moved or deleted.
- Fedora's one patch, `default-terminal.patch` (Ptyxis as the terminal), stays
  `Patch0`; the series follows as `Patch1001` and up, and `%autosetup -p1` applies it
  with `patch`, at Fedora's fuzz 0. Fedora's `sed` that drops `-Werror` from the top
  `meson.build` runs after both and touches no Apex file.

### What nautilus 51 already has

| Board element | In nautilus 51.0.1 | The Apex patch |
|---|---|---|
| Sidebar and content | `AdwOverlaySplitView` (`split_view`), collapsing below 682 sp | — |
| Grid and list | one `AdwSplitButton` that toggles the mode (`slot.files-view-mode-toggle`), with zoom and sort in its menu; `slot.files-view-mode` holds the mode | 0007: a two-option `AdwToggleGroup` on `slot.files-view-mode`; the split button's menu moves to a View Options button |
| Grid icon sizes | 48, 64, 96, 168 and 256 px (`NautilusGridZoomLevel`) | 0003: a 72 px level, the default |
| Item count | the floating bar, only on hover or selection | 0002: the item-count bar, which takes over the floating bar |
| Disk usage | the properties dialog | 0002: the footer of the sidebar |
| Details | the properties dialog | 0004: the details pane, the end pane of a second `AdwOverlaySplitView` |
| Recent | the Recent place | 0005: the recent strip on Home |
| Search | the search bar and the search popover's type and date filters, which re-run the search; the slot's `filter`, bound to the view model and used only by the file chooser | 0006: the chips, a `GtkCustomFilter` set as the slot's `filter`, so they filter only the shown results |

## `desktop/nautilus/`

Every file is GPL-3.0-or-later, nautilus's licence, and sits under `src/apex/`, the one
path `source1_paths` allows; `tests/nautilus/selftest.sh` checks both, and that every
patch is the owner's.

| Path | What it is |
|---|---|
| `src/apex/meson.build` | adds the Apex sources and resource to `libnautilus_sources` |
| `src/apex/apex.gresource.xml` | the Apex resource, `/org/gnome/nautilus/apex`, compiled with `--manual-register`; outside `style.css` and the other files libadwaita loads from the base path by itself |
| `src/apex/apex.css` | the sheet, in libadwaita's colours and variables, so dark style needs no rules of its own |
| `src/apex/apex.c` | `apex_files_init()`: registers the resource |
| `src/apex/apex-window.c` | `apex_window_attach()`: loads the sheet; puts the disk footer under the places sidebar, the details split view and the recent strip around the tab view, the chips under the header and the count bar at the bottom; adds the two actions and their main-menu items ("Details Pane", "Recent Files on Home"); and replaces the view controls. `APEX_NAUTILUS_STOCK=1` keeps the stock window |
| `src/apex/apex-disk-footer.c` | the footer: the system's name (`os-release` `NAME`), a 4 px meter of the used space in the accent, and "588 GB free of 1 TB" for the filesystem holding `$HOME` (not composefs `/`), queried when it maps and every 30 s while it shows |
| `src/apex/apex-count-bar.c` | the count bar: follows the window's active slot, its view and its model; "9 items", "N results" while searching, "· “name” selected" or "· N selected", "Loading…" before the first items. It hides each view's floating bar (`gtk_widget_set_child_visible`), which said the same |
| `src/apex/apex-format.c` | the texts and the kinds, without GTK: the footer's and the bar's texts, the recent cards' days, `~` paths, and a content type's chip group; `tests/nautilus/format-test.c` tests them |
| `src/apex/apex-slot-watch.c` | one object per window that follows the active slot, its view and its model, and says when the view or what it shows changes; every widget below reads it |
| `src/apex/apex-settings.c` | `win.show-details` and `win.show-recent-strip`, stateful actions on the Apex keys `files-details-pane` and `files-recent-strip`; with the schema missing they start at the defaults (closed, shown) and are not stored |
| `src/apex/apex-details-pane.c` | 0004, `ApexDetailsPane`: the selected item, or the open folder: its icon or thumbnail at 112 px, name, kind, size, modified time, `~` location, Open and Star. It is the end pane, 300 px, of an `AdwOverlaySplitView` around the tab view, inside an `AdwBreakpointBin` that overlays it below 720 sp of content: nautilus's sidebar is 180 px wide from 682 to 900 sp and collapses below, so that is a window under 900 px |
| `src/apex/apex-recent-strip.c` | 0005, `ApexRecentStrip`: "Recent", the four newest existing local items of `GtkRecentManager` as cards (icon or thumbnail, name, "Folder · Today"), and "Folders"; on Home in grid view when not searching, and hidden when empty or `win.show-recent-strip` is off. A card opens its file |
| `src/apex/apex-search-chips.c` | 0006, `ApexSearchChips`: All, Folders, Documents, Images, Audio & Video, a top bar while searching. The chip sets a `GtkCustomFilter` as the slot's `filter`, so the search is untouched; the counts come from the unfiltered results and follow every change |
| `src/apex/apex-view-controls.c` | 0007: the two-option `AdwToggleGroup` for grid and list, the View Options menu (the split button's own popover: zoom, sort, hidden files, columns) and the Details toggle, in place of each `NautilusViewControls` (the header's, and the action bar's on narrow windows) |

## The series

| Patch | Upstream files | Changed lines | Hunks |
|---|---|---|---|
| `0001-build` | `src/meson.build`, `src/nautilus-main.c` | +3 | `subdir('apex')` after upstream's sources; the include and `apex_files_init()` after `nautilus_register_resource()` |
| `0002-window` | `src/nautilus-window.c` | +4 | the include; `apex_window_attach()` in `nautilus_window_init()` |
| `0003-zoom` | `src/nautilus-enums.h`, `src/nautilus-grid-view.c`, `src/nautilus-ui-utilities.c`, `data/org.gnome.nautilus.gschema.xml` | +17 −5 | the 72 px size and level; its case in the size switch; the standard level; the empty-folder border's metrics at 72 px (the 64 px ones); the schema's enum, renumbered above it, and its default |
| `0006-unfiltered` | `src/nautilus-view-model.c`, `src/nautilus-view-model.h` | +7 | `nautilus_view_model_get_unfiltered()`, the root store under the model's filter, for the chips' counts |
| `0006-row-location` | `src/nautilus-name-cell.c` | +13 | the path and snippet setters update a bound cell's labels: the list view binds the item before it sets the path, so a row first bound under a chip's filter lost its location (an upstream bug the chips expose) |

libnautilus is a static library: an object nothing calls is left out of the binary, so
`main()` registers the resource itself rather than relying on a constructor.

Budget (ADR 0014): at most 400 changed lines in upstream files, in hook hunks only; the
added files under `src/apex/` do not count. In use: 49 lines in 10 files.

Each feature and the upstream lines it takes. A feature with no upstream line can't fail a
rebase, so it has no patch file; the lane holds the family as a whole either way.

| Feature | Upstream hunks |
|---|---|
| 0001, the disk footer | `0002-window`'s hook (shared with 0002) |
| 0002, the item-count bar | `0002-window`'s hook |
| 0003, the 72 px zoom level | `0003-zoom` |
| 0004, the details pane | none: `0002-window`'s hook |
| 0005, the recent strip | none: `0002-window`'s hook |
| 0006, the search chips | `0006-unfiltered`, for the counts; `0006-row-location`, so rows bound under the filter keep their location; the filter goes on the slot's existing `filter` |
| 0007, the grid/list toggle group | none: `0002-window`'s hook |

`0001-build` wires Source1 in for all of them.

The zoom level's nick is `apex`: GSettings stores a level by its nick, so the renumbered
levels above it keep every stored value, and a stock nautilus reading `apex` falls back
to its default.

The patches are `git format-patch` output against Fedora's `%prep` tree, with `a/` and
`b/` prefixes, applied with `-p1`. Write them with apex-image's `just pkg-prep nautilus`
and `just pkg-export nautilus`, as for gnome-shell
([its README](../gnome-shell/README.md#changing-a-patch-or-rebasing)).

Fedora updates absorbed:

- 2026-10-30, GNOME 51.1 (FEDORA-2026-2812a1754d, F45 `updates-testing`, request stable):
  every patch applies at fuzz 0 to `nautilus-51.1-1.fc45` as well as `51.0.1-1.fc45`, and
  the lane builds it with the whole update in the buildroot. No patch changed.

## Building it here

```bash
just nautilus-test   # desktop/nautilus's licence and paths, the series, the patches' From:; the texts' unit test
just nautilus-lane   # podman or docker: apex-lane's container half in fedora:45
just nautilus-shots  # podman or docker: that nautilus captured in a headless gnome-shell, light and dark
```

For C, `just app-dev nautilus` in apex-image rebuilds the Apex build the desktop VM runs
incrementally and runs it there ([desktop/README.md](../../../desktop/README.md#c-in-the-apps-just-app-dev)).

`tests/lib/lane.sh nautilus` builds
`apex-lane` from a pinned apex-image commit and runs its container half,
`apex-lane in-container build nautilus`, as the builder VM does: the SRPM's signature,
`spec-edit`, the series at fuzz 0, the exact-tree check, `rpmbuild -ba` with Fedora's
`%check`, the lane checks and `check.sh`. It leaves out what the VM adds, the signing
and the store. The RPMs and logs land in `_build/nautilus/out/`. CI runs it on every
push.

`tests/nautilus/shoot.sh` installs those RPMs in a fedora:45 container and runs
gnome-shell headless at scale 2 for the user `apex`, with apex-desktop's fonts and font
settings, G2's `fixtures.py` on the system bus and its `clock.c` holding the wall clock
at the board's 2026-10-21 10:24, as `tests/shots/direct.sh` runs a case. It builds
apex-desktop's `Apex` icon theme (folders, file types, Apex Symbolic) from a pinned
commit, as that package's spec does, without Colloid's app icons, and compiles the Apex
schema. `home.py` seeds the home of board 27: its folders and files with their sizes and
times, the XDG directories, PNGs in the board's colours, and the four recent files.

Each case is one shell: `probe.js` opens Files at the board's window geometry
(1240×762 at 100, 48), `a11y.py` dumps the window's accessible tree, and the window is
captured. `check.py` then asserts, light and dark:

| Case | Board | Asserted |
|---|---|---|
| `home` | 27, Home in grid view | "9 items"; Grid View on; Details off and the pane closed; "Recent" with the four recent files; no chips |
| `documents` | 28, Documents in list view, the spec selected, `files-details-pane` on | "5 items · “Apex Fedora — Spec.odt” selected"; List View on; the pane open with "Document" and "~/Documents/Apex Fedora — Spec.odt"; no strip |
| `search` | 29, "apex" searched from Home in list view | "11 results…"; the chips All 11, Folders 4, Documents 3, Images 4, Audio & Video 0, with All on; every row's location |
| `search-documents` (light) | 29, with the Documents chip pressed over AT-SPI | "3 results…"; the same five counts, Documents alone on; each row's location |
| `search-again` (light) | 29, with the Documents chip and then All pressed | "11 results…"; All on; every one of the 11 rows names its location |
| `noschema` (light) | 27 without the Apex schema | the pane closed and the strip shown |

Every case also asserts the footer's text and its labelled meter. The Apex schema sits in
its own directory (`GSETTINGS_SCHEMA_DIR`), so `noschema` leaves it out; each case starts
from an empty dconf database and no gvfs metadata.
`probe.js` types the search with a virtual keyboard (Ctrl+F, "apex"), and `a11y.py
OUT PRESS...` presses chips by their accessible names, in order, before the dump.

The footer's numbers are the container's filesystem, so `check.py` asserts their form
and `format-test.c` the board's own "588 GB free of 1 TB". CI keeps the captures, trees
and logs as the `nautilus-shots` artifact.
