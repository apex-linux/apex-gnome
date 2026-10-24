# Ptyxis in the rebuild lane

Fedora's ptyxis SRPM, rebuilt with the Apex terminal inside it: the sessions sidebar and
split panes of the design canvas's boards 32 and 33. It is the lane's second package
after gnome-shell, an owner decision of 2026-10-24 under
[ADR 0014](https://github.com/apex-linux/apex/blob/main/docs/adr/0014-engine-level-desktop.md)'s
escalation rule. The lane, `apex-lane`, and the formats of the files here are in
[packaging/README.md](https://github.com/apex-linux/apex-image/blob/main/packaging/README.md#the-rebuild-lane).

| File | Role |
|---|---|
| `pkg.env` | the SRPM, the hold family `ptyxis`, the one binary package the image takes, and Source1 (`desktop/ptyxis/`, unpacked as `src/apex/`) |
| `spec-edit` | anchored edits to Fedora's spec: `.apexN`, `Source100`, and the `%prep` line that unpacks it |
| `series`, `patches/` | the hook hunks, one patch per concern |
| `check.sh` | the lane checks of this package: upstream's resource still in `/usr/bin/ptyxis`, every resource file of Source1 in `/org/gnome/Ptyxis/apex`, the Apex marker, and Fedora's gschema override |

## What the build does to Fedora's package

- Fedora 45 ships Ptyxis 50.1 (`ptyxis-50.1-6.fc45`), on VTE 0.84, GTK 4.24 and
  libadwaita 1.10. It has tabs, the tab overview and a per-tab monitor of the foreground
  process; it has no split panes and no sidebar.
- `Release: %{autorelease}.apexN` gives `50.1-6.fc45.apexN`, above Fedora's build and
  below its next one.
- Fedora's own `Source1` is its gschema override, so the Apex archive is `Source100`:
  `apex-ptyxis-<tree>.tar`, the `git archive` of `desktop/ptyxis/`. `%prep` unpacks it
  at the top of the tree with `tar -xkf`, which gives `src/apex/` and never replaces an
  upstream file. Nothing is moved or deleted.
- Fedora's spec has no patch of its own; the series follows as `Patch1001` and up, and
  `%autosetup -p1` applies it with `patch`, at Fedora's fuzz 0.

## `desktop/ptyxis/`

Every file is GPL-3.0-or-later, Ptyxis's licence, and sits under `src/apex/`, the one
path `source1_paths` allows; `tests/ptyxis/selftest.sh` checks both.

| Path | What it is |
|---|---|
| `src/apex/meson.build` | adds the Apex resource to `ptyxis_sources` |
| `src/apex/apex.gresource.xml` | the Apex resource, `/org/gnome/Ptyxis/apex`; outside the resource base path, so libadwaita loads nothing from it by itself |
| `src/apex/apex.css` | the Apex marker; the sheet the sidebar and pane headers will use |

## The series

| Patch | Upstream files | Changed lines | Hunks |
|---|---|---|---|
| `0001-build` | `src/meson.build` | +1 | `subdir('apex')` after upstream's resources |

Budget (ADR 0014, as amended for Ptyxis): at most 400 changed lines in upstream files,
in hook hunks only; the added files under `src/apex/` do not count. In use: 1 line in
1 file.

The patches are `git format-patch` output against Fedora's `%prep` tree, with `a/` and
`b/` prefixes, applied with `-p1`. Write them with apex-image's `just pkg-prep ptyxis`
and `just pkg-export ptyxis`, as for gnome-shell
([its README](../gnome-shell/README.md#changing-a-patch-or-rebasing)).

## Building it here

```bash
just ptyxis-lane     # podman or docker: apex-lane's container half in fedora:45
```

`tests/ptyxis/lane.sh` builds `apex-lane` from a pinned apex-image commit and runs its
container half, `apex-lane in-container build ptyxis`, as the builder VM does: the
SRPM's signature, `spec-edit`, the series at fuzz 0, the exact-tree check,
`rpmbuild -ba` with Fedora's `%check`, the lane checks and `check.sh`. It leaves out
what the VM adds, the signing and the store. The RPMs and logs land in
`_build/ptyxis/out/`. CI runs it on every push.
