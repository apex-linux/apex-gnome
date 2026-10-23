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

[apex-image](https://github.com/apex-linux/apex-image) pins this repository by commit in
`components.lock`, builds gnome-shell from the recipe in its builder VM, and runs G2 on the
image. The `just vm-*` and `just pkg-*` recipes the READMEs here name are apex-image's.
The design is in the [apex](https://github.com/apex-linux/apex) repository:
[DESIGN.md](https://github.com/apex-linux/apex/blob/main/docs/DESIGN.md) and
[ARCHITECTURE §11](https://github.com/apex-linux/apex/blob/main/docs/ARCHITECTURE.md#11-quality-gates).

The layer reads its settings from apex-desktop's schema, and apex-desktop's crash guard
unit turns it off after an early shell failure. `tests/layer/fixtures/` holds copies of
both, so this repository's CI needs no other checkout; apex-image runs the layer tests
against the pinned apex-desktop with `APEX_DESKTOP_SRC`.

## Development

```bash
just check        # the layer tests, G2's self-test, the script self-test and the comment guard
just layer-test   # gjs and glib-compile-schemas; bwrap for the kernel command-line cases
just shots-test   # gjs, GdkPixbuf and jq; dbus-daemon and python3-dbusmock for the fixtures
```

Tests whose tools are missing skip locally; CI runs them in Fedora 45 and fails on a skip.
The comment guard is `apex-lint`, from [apex-ci](https://github.com/apex-linux/apex-ci):
`cargo install --locked --git https://github.com/apex-linux/apex-ci apex-lint`. Code
explains itself, and comments say only why
([CONTRIBUTING](https://github.com/apex-linux/apex/blob/main/docs/CONTRIBUTING.md)).

## License

`desktop/shell/` and the patches are GPL-2.0-or-later, as gnome-shell is
(`LICENSE.GPL-2.0`). Everything else is GPL-3.0-or-later (`LICENSE`).
