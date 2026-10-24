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
| `check.sh` | the lane checks of this package: upstream's resource still in `/usr/bin/nautilus`, every resource file of Source1 in `/org/gnome/nautilus/apex`, the Apex marker, Fedora's own patch, and `libnautilus-extension.so.4` |

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
| Grid icon sizes | 48, 64, 96, 168 and 256 px (`NautilusGridZoomLevel`) | 72 px as the default level |
| Item count | the floating bar, only on hover or selection | the item-count bar |
| Disk usage | the properties dialog | the footer of the sidebar |
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
| `src/apex/apex.css` | the sheet; today only the Apex marker |
| `src/apex/apex.c` | `apex_files_init()`: registers the resource |

## The series

| Patch | Upstream files | Changed lines | Hunks |
|---|---|---|---|
| `0001-build` | `src/meson.build`, `src/nautilus-main.c` | +3 | `subdir('apex')` after upstream's sources; the include and `apex_files_init()` after `nautilus_register_resource()` |

libnautilus is a static library: an object nothing calls is left out of the binary, so
`main()` registers the resource itself rather than relying on a constructor.

Budget (ADR 0014): at most 400 changed lines in upstream files, in hook hunks only; the
added files under `src/apex/` do not count. In use: 3 lines in 2 files.

The patches are `git format-patch` output against Fedora's `%prep` tree, with `a/` and
`b/` prefixes, applied with `-p1`. Write them with apex-image's `just pkg-prep nautilus`
and `just pkg-export nautilus`, as for gnome-shell
([its README](../gnome-shell/README.md#changing-a-patch-or-rebasing)).

## Building it here

```bash
just nautilus-test   # desktop/nautilus's licence and paths, the series, the patches' From:
just nautilus-lane   # podman or docker: apex-lane's container half in fedora:45
```

`tests/nautilus/lane.sh` is `tests/ptyxis/lane.sh` for this recipe: it builds
`apex-lane` from a pinned apex-image commit and runs its container half,
`apex-lane in-container build nautilus`, as the builder VM does: the SRPM's signature,
`spec-edit`, the series at fuzz 0, the exact-tree check, `rpmbuild -ba` with Fedora's
`%check`, the lane checks and `check.sh`. It leaves out what the VM adds, the signing
and the store. The RPMs and logs land in `_build/nautilus/out/`. CI runs it on every
push.
