# gnome-shell in the rebuild lane

Fedora's gnome-shell SRPM, rebuilt with the Apex layer inside it
([ADR 0014](../../../docs/adr/0014-engine-level-desktop.md),
[ARCHITECTURE 7.4](../../../docs/ARCHITECTURE.md#74-desktop-layer)). The lane itself,
and the formats of the files here, are in [packaging/README.md](../../README.md#the-rebuild-lane).

| File | Role |
|---|---|
| `pkg.env` | the SRPM, the hold family, the mutter pin and its mirrored RPMs, Source1 (`desktop/shell/`) and the `%prep` changes the lane checks |
| `spec-edit` | anchored edits to Fedora's spec: `.apexN`, Source1, `BuildRequires: sassc`, the exact mutter pin, and the `%prep` lines |
| `series`, `patches/` | the hook hunks, one patch per concern |
| `check.sh` | the lane checks of this package: the Apex resource in libshell, the patched `main.js`, upstream's sheets under `theme/stock/`, the Apex markers in the rebuilt sheets |

## What the build does to Fedora's package

- `Release: %{autorelease}.apexN` gives `51.0-1.fc45.apexN`, above Fedora's
  `51.0-1.fc45` and below Fedora's next build, `51.0-2.fc45`. A pin-only rebuild is
  `.apexN.M`.
- `Source1` is `apex-shell-<tree>.tar`, the `git archive` of `desktop/shell/`. `%prep`
  unpacks it at the top of the tree with `tar -xkf`, moves upstream's compiled
  `gnome-shell-light.css` and `-dark.css` to `data/theme/apex/stock/`, and deletes
  `gnome-shell-high-contrast.css`. Meson then finds no compiled sheet and runs sassc on
  all three entry files, whose `@import` hooks pull in the Apex SCSS.
- `BuildRequires: mutter-devel = <EVR>` and `Requires: mutter%{?_isa} = <EVR>` sit next
  to Fedora's `>=` lines. The EVR is the newest `mutter-devel` in the lane's
  repositories, so the tested pair moves together. The Fedora-signed `mutter` and
  `mutter-common` of that build are stored with the shell and locked with it.
- Fedora's own patch stays `Patch0`; the series follows as `Patch1001` and up, and
  Fedora's `%autosetup -S git` applies it with `git apply`, which allows no fuzz.

## The series

| Patch | Upstream files | Changed lines | Hunks |
|---|---|---|---|
| `0001-build` | `data/theme/gnome-shell-{light,dark,high-contrast}.scss`, `data/theme/meson.build`, `js/meson.build`, `src/meson.build` | +13 | the `@import` hooks; `subdir('apex')`; `apex.gresource.xml` compiled and linked into libshell next to `js-resources` |
| `0002-loader` | `js/ui/main.js`, `js/ui/sessionMode.js` | +16 −1 | the static import of `ui/apex/hooks.js`; the layer loaded (configure) before the session mode exists; `enable()` at `startup-prepared`; the stock sheets in safe mode; a value hook over each session mode's parameters |

Budget (ADR 0014): at most 450 changed lines of hook hunks in at most 33 upstream files.
In use: 30 lines in 8 files. The C budget for `shell-blur-effect.{c,h}` (300 lines) is
untouched until 0003-blur (S2b).

The patches are `git format-patch` output against Fedora's `%prep` tree (upstream
51.0 plus Fedora's patch): `From:`, `Subject:`, a message that says what the hunks hook,
then the diff with `a/` and `b/` prefixes, applied with `-p1`. Write them with
`just pkg-export`, never by hand.

## Changing a patch or rebasing

```bash
just pkg-prep gnome-shell            # in the VM: _build/pkg/gnome-shell/tree, one commit per patch
just vm-ssh                          # cd apex-fedora/_build/pkg/gnome-shell/tree; edit; git commit --amend
just pkg-export gnome-shell          # the commits back to patches/ on this host
just pkg-export gnome-shell 0010-panel.patch   # a new commit becomes a new patch, added to series
just pkg-build gnome-shell           # the lane: fuzz 0, the build, the checks
```

The tree's commits after the tag `apex-base` are the series, one commit per `series`
entry in order. Source1 is unpacked in the tree and ignored by git, and the moved and
deleted sheets are marked `skip-worktree`, so `git commit -a` never picks them up.

When Fedora ships a new gnome-shell and a patch stops applying, the lane holds the
family (`just pkg-status` shows the reason and the timer). `just pkg-rebase gnome-shell
gnome-shell-51.1-1.fc45` prepares the tree from that build and runs `git am -3`; when a
patch stops, resolve it in the tree (`git am --show-current-patch=diff`, edit,
`git add`, `git am --continue`), then `just pkg-export gnome-shell` and
`just pkg-build gnome-shell`. The three-way fallback needs the blobs the patch was made
against, which the new tree has only for files Fedora did not change; otherwise resolve
by hand.

## Not covered by the lane

- The headless shell (G2) and the VM checks (G4): the static import graph, safe mode,
  the light shell for `color-scheme 'default'`, the gdm mode and the unlock dialog.
- The image: `[apex]` admits the lane's RPMs once the image build reads
  `rpms.lock.next` (the next stage of S1a).
