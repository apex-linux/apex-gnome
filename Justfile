# SPDX-License-Identifier: GPL-3.0-or-later

set shell := ["bash", "-euo", "pipefail", "-c"]

ptyxis_shots_packages := "gnome-shell mesa-dri-drivers dbus-daemon python3-dbusmock gcc util-linux jq jetbrains-mono-fonts-all adwaita-sans-fonts"
ptyxis_image := "registry.fedoraproject.org/fedora:45@sha256:1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb"

# List the recipes.
default:
    @just --list

# The tests, eslint, the theme compile, the script self-test and the comment guard, as ci.yml runs them (tests that need a missing tool skip).
check: layer-test shots-test eslint theme selftest ptyxis-test control-center-test
    apex-lint comments

# The Apex layer's safety net in gjs: kill switches, fault injection, crash guard, live layer cycles.
layer-test:
    tests/layer/run.sh

# G2's own logic without the VM: the capture comparison, the token file, the top-bar assertions, the fixtures.
shots-test:
    tests/shots/selftest.sh

# gnome-shell 51.0's eslint rules on the layer and the gjs tests (node and npm; npm ci into lint/node_modules).
eslint:
    lint/eslint.sh

# The three sheets compiled with sassc as the rebuild does, against Fedora's gnome-shell SRPM (or GNOME_SHELL_SRC, a source tree).
theme:
    lint/theme.sh

# desktop/ptyxis: its licence lines, the recipe's source1_paths and its series; the sessions' status logic (gcc, glib2-devel).
ptyxis-test:
    tests/ptyxis/selftest.sh
    tests/ptyxis/status-test.sh

# Ptyxis rebuilt as the lane builds it (apex-lane's container half), in fedora:45 with podman or docker; RPMs in _build/ptyxis/out.
ptyxis-lane:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{ptyxis_image}} tests/ptyxis/lane.sh

# The Ptyxis that ptyxis-lane built, captured in a headless gnome-shell, light and dark (podman or docker); in _build/ptyxis/shots.
ptyxis-shots:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{ptyxis_image}} bash -c 'dnf5 -y -q --setopt=install_weak_deps=False install {{ptyxis_shots_packages}} && tests/ptyxis/shoot.sh _build/ptyxis/out'

# The Ptyxis that ptyxis-lane built: a user palette rewritten under an open terminal must show within 1 s (podman or docker).
ptyxis-palette:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{ptyxis_image}} bash -c 'dnf5 -y -q --setopt=install_weak_deps=False install {{ptyxis_shots_packages}} && tests/ptyxis/palette-test.sh _build/ptyxis/out'

control_center_image := "registry.fedoraproject.org/fedora:45@sha256:1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb"

# desktop/control-center: its licence lines, the recipe's source1_paths, its series and the patches' From: lines.
control-center-test:
    tests/control-center/selftest.sh

# gnome-control-center rebuilt as the lane builds it (apex-lane's container half), in fedora:45 with podman or docker; RPMs in _build/control-center/out.
control-center-lane:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{control_center_image}} tests/control-center/lane.sh

control_center_run_packages := "gnome-shell mesa-dri-drivers dbus-daemon python3-dbusmock python3-gobject at-spi2-core gcc util-linux adwaita-sans-fonts"

# The Settings that control-center-lane built, in a headless gnome-shell: board 11's captures, light and dark, and every row's binding; in _build/control-center/shots.
control-center-run:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{control_center_image}} bash -c 'dnf5 -y -q --setopt=install_weak_deps=False install {{control_center_run_packages}} && tests/control-center/run.sh _build/control-center/out'

# The script self-tests, as ci.yml runs them.
selftest:
    .github/scripts/selftest.sh

# The comment guard on every tracked file, or on the given ones (cargo install --git https://github.com/apex-linux/apex-ci apex-lint).
[positional-arguments]
lint-comments *paths:
    apex-lint comments "$@"
