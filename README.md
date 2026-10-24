# apex-gnome

The patched GNOME of [Apex](https://github.com/apex-linux/apex), a Fedora 45 bootc desktop
for one laptop, the ASUS Vivobook Pro 14X OLED (M7400QC). Today that is gnome-shell with
the Apex layer; libadwaita, Settings and Files patch series join it in S2.

| Path | What it is |
|---|---|
| `desktop/shell/` | The Apex layer: its loader and hooks (`js/ui/apex/`), the kill switches, fault injection, and the top-bar theme built from `_apex-tokens.scss`. It ships inside gnome-shell's resource |
| `packaging/pkgs/gnome-shell/` | The rebuild recipe apex-image's lane builds from Fedora's SRPM: the patch series, `spec-edit`, `pkg.env` and the post-build `check.sh` |
| `tests/layer/` | The layer's safety net in gjs: kill switches, fault injection, the crash guard and live layer cycles |
| `tests/shots/` | G2, the headless shell of a built image, and its self-test |
| `desktop/ptyxis/`, `packaging/pkgs/ptyxis/` | Ptyxis rebuilt in the lane with the Apex terminal, the sessions sidebar and split panes of boards 32 and 33: its sources (`src/apex/`) and its recipe ([README](packaging/pkgs/ptyxis/README.md)) |
| `tests/lib/` | the app tests' shared tools: `lane.sh PKG`, a recipe through apex-lane's container half, and `headless.sh`, a headless gnome-shell after G2's `run_case`; every lane recipe's CI job runs `lane.sh` |
| `tests/ptyxis/` | the checks of `desktop/ptyxis/`, the status logic's unit test, the captures (`shoot.sh`) and the palette test |
| `packaging/pkgs/libadwaita/`, `tests/libadwaita/` | libadwaita rebuilt in the lane to load and follow Settings' `apex.css`, the live window radius ([README](packaging/pkgs/libadwaita/README.md)), and its radius test |
| `desktop/control-center/`, `packaging/pkgs/gnome-control-center/` | gnome-control-center rebuilt in the lane for the Apex Settings, boards 11, 18, 23, 24 and 26: its sources (`panels/apex/`) and its recipe ([README](packaging/pkgs/gnome-control-center/README.md)) |
| `tests/control-center/` | the checks of `desktop/control-center/`, and the Apex Desktop panel in a headless shell: board 11's captures and every row's binding (`run.sh`) |
| `tests/s2c/` | S2c's live window radius end to end: apex-session-agent from the pinned apex-system (`agent.sh`), and Settings' Corner Radius pressed through AT-SPI under open Ptyxis, Files and Settings windows beside a maximised one (`radius-test.sh`) |
| `desktop/nautilus/`, `packaging/pkgs/nautilus/` | nautilus rebuilt in the lane for Files, boards 27 to 29: its sources (`src/apex/`) and its recipe ([README](packaging/pkgs/nautilus/README.md)) |
| `tests/nautilus/` | the checks of `desktop/nautilus/`, the texts' unit test, and the captures with board 27's home (`shoot.sh`) |
| `tests/shell/` | the lock screen and the greeter of the lane's gnome-shell, boards 20 and 12, against a GDM mock that fails every answer (`gdm-mock.py`): captures and their assertions (`shoot.sh`) |

[apex-image](https://github.com/apex-linux/apex-image) pins this repository by commit in
`components.lock`, builds gnome-shell from the recipe in its builder VM, and runs G2 on the
image. [desktop/README.md](desktop/README.md) describes the layer, its S1a behaviour and
the dev loop. The `just vm-*`, `just pkg-*` and `just shell-*` recipes the READMEs here
name are apex-image's.
The design is in the [apex](https://github.com/apex-linux/apex) repository:
[DESIGN.md](https://github.com/apex-linux/apex/blob/main/docs/DESIGN.md) and
[ARCHITECTURE §11](https://github.com/apex-linux/apex/blob/main/docs/ARCHITECTURE.md#11-quality-gates).

The layer reads its settings from apex-desktop's schema, and apex-desktop's crash guard
unit turns it off after an early shell failure. `tests/layer/fixtures/` holds copies of
both, so this repository's CI needs no other checkout; apex-image runs the layer tests
against the pinned apex-desktop with `APEX_DESKTOP_SRC`. The fixtures' `Meta-51.gir` and
`Shell-51.gir` carry the mutter and gnome-shell constants the layer uses, which gjs
outside the shell otherwise lacks; `tests/layer/main-stub.js` stands in for `main.js`.

## Development

```bash
just check        # the layer tests, G2's self-test, eslint, the theme, the script self-test and the comment guard
just layer-test   # gjs, glib-compile-schemas and gi-compile-repository (or g-ir-compiler); bwrap for the kernel command-line cases
just shots-test   # gjs, GdkPixbuf and jq; dbus-daemon and python3-dbusmock for the fixtures
just eslint       # node, npm and git: gnome-shell 51.0's eslint rules, pinned in lint/package-lock.json
just theme        # sassc and git; dnf5, rpm2cpio, cpio and xz for Fedora's gnome-shell SRPM
just ptyxis-lane  # podman or docker: Ptyxis rebuilt as the lane builds it, RPMs in _build/ptyxis/out
just ptyxis-shots # podman or docker: that Ptyxis captured in a headless gnome-shell, light and dark
just libadwaita-lane     # podman or docker: libadwaita rebuilt as the lane builds it, RPMs in _build/libadwaita/out
just libadwaita-radius   # podman or docker: that libadwaita under an open Ptyxis, apex.css rewritten from 14 px to 0 px
just control-center-lane # podman or docker: gnome-control-center rebuilt as the lane builds it, RPMs in _build/gnome-control-center/out
just control-center-run  # podman or docker: that Settings in a headless gnome-shell: board 11 captured, every row checked
just s2c-radius     # podman or docker, after the three lanes: Settings' Corner Radius from 14 to 0 under open windows
just nautilus-lane # podman or docker: nautilus rebuilt as the lane builds it, RPMs in _build/nautilus/out
just nautilus-shots # podman or docker: that nautilus captured in a headless gnome-shell, light and dark
just gnome-shell-lane # podman or docker: gnome-shell rebuilt as the lane builds it, RPMs in _build/gnome-shell/out
just lock-shots  # podman or docker: its lock screen and greeter, light and dark, against a GDM mock
```

`just eslint` lints `desktop/shell/js` and the gjs tests with gnome-shell's own
configuration (`lint/README.md`). `just theme` compiles the light, dark and high-contrast
sheets as the rebuild does, from upstream's entry files with `0001-build`'s `@import` hooks
and `desktop/shell/data/theme/apex/`, and fails on any sassc error or warning; it downloads
the gnome-shell SRPM from Fedora 45's `fedora` and `updates`, or takes a source tree in
`GNOME_SHELL_SRC`.

Tests whose tools are missing skip locally; CI runs them in Fedora 45 and fails on a skip.
The comment guard is `apex-lint`, from [apex-ci](https://github.com/apex-linux/apex-ci):
`cargo install --locked --git https://github.com/apex-linux/apex-ci apex-lint`. Code
explains itself, and comments say only why
([CONTRIBUTING](https://github.com/apex-linux/apex/blob/main/docs/CONTRIBUTING.md)).

## License

`desktop/shell/` and the patches are GPL-2.0-or-later, as gnome-shell is
(`LICENSE.GPL-2.0`); so are `desktop/control-center/` and the gnome-control-center
patches, gnome-control-center's licence. The libadwaita patch is LGPL-2.1-or-later, as
libadwaita is (`LICENSE.LGPL-2.1`). `lint/eslint.config.js` keeps gnome-shell's MIT OR
LGPL-2.1-or-later. Everything else, `desktop/ptyxis/`, `desktop/nautilus/` and their patches
included (Ptyxis and nautilus are GPL-3.0-or-later), is GPL-3.0-or-later (`LICENSE`).
