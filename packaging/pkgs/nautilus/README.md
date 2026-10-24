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
| `check.sh` | the lane checks of this package: upstream's resource still in `/usr/bin/nautilus`, every resource file of Source1 in `/org/gnome/nautilus/apex`, the Apex marker and the footer's and count bar's sheet, the 72 px default zoom in the schema, Fedora's own patch, and `libnautilus-extension.so.4` |

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
| Grid and list | one `AdwSplitButton` that toggles the mode (`slot.files-view-mode-toggle`), with zoom and sort in its menu; `slot.files-view-mode` holds the mode | 0007: a two-option `AdwToggleGroup` on `slot.files-view-mode` |
| Grid icon sizes | 48, 64, 96, 168 and 256 px (`NautilusGridZoomLevel`) | 0003: a 72 px level, the default |
| Item count | the floating bar, only on hover or selection | 0002: the item-count bar, which takes over the floating bar |
| Disk usage | the properties dialog | 0002: the footer of the sidebar |
| Details | the properties dialog | 0004: the details pane, the end pane of a second `AdwOverlaySplitView` |
| Recent | the Recent place | 0005: the recent strip on Home |
| Search | the search bar and the search popover's type and date filters, which re-run the search | 0006: the chips, which filter only the shown results |

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
| `src/apex/apex-window.c` | `apex_window_attach()`: loads the sheet, puts the disk footer under the places sidebar and the count bar at the bottom of the content. `APEX_NAUTILUS_STOCK=1` keeps the stock window |
| `src/apex/apex-disk-footer.c` | the footer: the system's name (`os-release` `NAME`), a 4 px meter of the used space in the accent, and "588 GB free of 1 TB" for the filesystem holding `$HOME` (not composefs `/`), queried when it maps and every 30 s while it shows |
| `src/apex/apex-count-bar.c` | the count bar: follows the window's active slot, its view and its model; "9 items", "N results" while searching, "· “name” selected" or "· N selected", "Loading…" before the first items. It hides each view's floating bar (`gtk_widget_set_child_visible`), which said the same |
| `src/apex/apex-format.c` | the footer's and the bar's texts, without GTK; `tests/nautilus/format-test.c` tests them |

## The series

| Patch | Upstream files | Changed lines | Hunks |
|---|---|---|---|
| `0001-build` | `src/meson.build`, `src/nautilus-main.c` | +3 | `subdir('apex')` after upstream's sources; the include and `apex_files_init()` after `nautilus_register_resource()` |
| `0002-window` | `src/nautilus-window.c` | +4 | the include; `apex_window_attach()` in `nautilus_window_init()` |
| `0003-zoom` | `src/nautilus-enums.h`, `src/nautilus-grid-view.c`, `src/nautilus-ui-utilities.c`, `data/org.gnome.nautilus.gschema.xml` | +17 −5 | the 72 px size and level; its case in the size switch; the standard level; the empty-folder border's metrics at 72 px (the 64 px ones); the schema's enum, renumbered above it, and its default |

libnautilus is a static library: an object nothing calls is left out of the binary, so
`main()` registers the resource itself rather than relying on a constructor.

Budget (ADR 0014): at most 400 changed lines in upstream files, in hook hunks only; the
added files under `src/apex/` do not count. In use: 29 lines in 7 files.

ROADMAP S2d names the footer, the count and the zoom 0001 to 0003, and S7 the rest 0004 to
0007. Here `0001-build` wires Source1 in, the footer and the count share one hook
(`0002-window`), and the zoom is `0003-zoom`, so the series stays at ADR 0014's seven
patches and S7's numbers hold.

The zoom level's nick is `apex`: GSettings stores a level by its nick, so the renumbered
levels above it keep every stored value, and a stock nautilus reading `apex` falls back
to its default.

The patches are `git format-patch` output against Fedora's `%prep` tree, with `a/` and
`b/` prefixes, applied with `-p1`. Write them with apex-image's `just pkg-prep nautilus`
and `just pkg-export nautilus`, as for gnome-shell
([its README](../gnome-shell/README.md#changing-a-patch-or-rebasing)).

## Building it here

```bash
just nautilus-test   # desktop/nautilus's licence and paths, the series, the patches' From:; the texts' unit test
just nautilus-lane   # podman or docker: apex-lane's container half in fedora:45
just nautilus-shots  # podman or docker: that nautilus captured in a headless gnome-shell, light and dark
```

`tests/nautilus/lane.sh` is `tests/lib/lane.sh` copied for this recipe: it builds
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
| `home` | 27, Home in grid view | the footer's text and labelled meter; "9 items" |
| `documents` | 28, Documents in list view, the spec selected | the footer; "5 items · “Apex Fedora — Spec.odt” selected" |

The footer's numbers are the container's filesystem, so `check.py` asserts their form
and `format-test.c` the board's own "588 GB free of 1 TB". CI keeps the captures, trees
and logs as the `nautilus-shots` artifact.
