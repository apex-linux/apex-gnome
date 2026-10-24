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
| `check.sh` | the lane checks of this package: upstream's resource still in `/usr/bin/gnome-control-center`, every resource file of Source1 in `/org/gnome/Settings/apex`, the Apex marker, the `-filesystem` directories and `org.gnome.Settings.desktop` |

This first step changes no behaviour: Settings is Fedora's, with the Apex resource
compiled in and nothing loading it.

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
| The panel list | `default_panels[]` in `shell/cc-panel-loader.c`: an id, its `get_type()` and an optional static init function, compiled in; no plugin API | an `extern` and a `PANEL_TYPE ("apex", …)` line (0001 of C1 step 2) |
| Its metadata | `gnome-<id>-panel.desktop` in `/usr/share/applications`, read by `cc_panel_loader_fill_model()`: name, icon, keywords and the category, which picks the sidebar section | an added `gnome-apex-panel.desktop.in` |
| The build | `panels/meson.build` runs `subdir()` for each id, each adding a static library to `panels_libs`; the executable links them | `subdir('apex')` (this step) |
| The sidebar order | `panel_order[]` in `shell/cc-panel-list.c`; an id missing from it sorts as index 0, the top | one line at the head of `panel_order[]` (step 2); 0002 (C2) reorders it |
| Opening by name | `gnome-control-center <id>`, through `CcApplication`'s command line and the same list | nothing more |

So a panel is added files plus three short hooks. The Apex panel and its pages live in
`panels/apex/`; the System panel's Software Updates row (C2) is one more hook in
`panels/system/`.

## `desktop/control-center/`

Every file is GPL-2.0-or-later, gnome-control-center's licence, and sits under
`panels/apex/`, the one path `source1_paths` allows; `tests/control-center/selftest.sh`
checks both, and that every patch is the owner's.

| Path | What it is |
|---|---|
| `panels/apex/meson.build` | `apex_shell_sources`: the Apex resource, compiled into the executable's sources by 0001 |
| `panels/apex/apex.gresource.xml` | the Apex resource, `/org/gnome/Settings/apex`; outside the files libadwaita loads from the base path by itself |
| `panels/apex/apex.css` | the Apex sheet: only the marker `/*! apex-control-center */` for now |

## The series

| Patch | Upstream files | Changed lines | Hunks |
|---|---|---|---|
| `0001-build` | `panels/meson.build`, `shell/meson.build` | +2 | `subdir('apex')` after upstream's panels; `apex_shell_sources` added to `shell_sources` |

The resource goes into the executable as sources, not as a static library in
`panels_libs`: the linker takes an archive member only when something references it,
and nothing upstream does.

Budget (ADR 0014): at most 150 changed lines in upstream files, in hook hunks only; the
added files under `panels/apex/` do not count. In use: 2 lines in 2 files.

The patches are `git format-patch` output against Fedora's `%prep` tree, with `a/` and
`b/` prefixes, applied with `-p1`. Write them with apex-image's
`just pkg-prep gnome-control-center` and `just pkg-export gnome-control-center`, as for
gnome-shell ([its README](../gnome-shell/README.md#changing-a-patch-or-rebasing)).

## Building it here

```bash
just control-center-test   # desktop/control-center's licence and paths; the patches' From: lines
just control-center-lane   # podman or docker: apex-lane's container half in fedora:45
```

`tests/control-center/lane.sh` builds `apex-lane` from a pinned apex-image commit and
runs its container half, `apex-lane in-container build gnome-control-center`, as the
builder VM does: the SRPM's signature, `spec-edit`, the series at fuzz 0, the exact-tree
check, `rpmbuild -ba` with Fedora's `%check`, the lane checks and `check.sh`. It leaves
out what the VM adds, the signing and the store. The RPMs and logs land in
`_build/control-center/out/`. CI runs it on every push.
