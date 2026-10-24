# SPDX-License-Identifier: GPL-3.0-or-later

set shell := ["bash", "-euo", "pipefail", "-c"]

ptyxis_shots_packages := "gnome-shell mesa-dri-drivers dbus-daemon python3-dbusmock gcc util-linux jq jetbrains-mono-fonts-all adwaita-sans-fonts"
ptyxis_image := "registry.fedoraproject.org/fedora:45@sha256:1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb"

# List the recipes.
default:
    @just --list

# The tests, eslint, the theme compile, the script self-test and the comment guard, as ci.yml runs them (tests that need a missing tool skip).
check: layer-test shots-test eslint theme selftest ptyxis-test control-center-test nautilus-test
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
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{ptyxis_image}} tests/lib/lane.sh ptyxis

# The Ptyxis that ptyxis-lane built, captured in a headless gnome-shell, light and dark (podman or docker); in _build/ptyxis/shots.
ptyxis-shots:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{ptyxis_image}} bash -c 'dnf5 -y -q --setopt=install_weak_deps=False install {{ptyxis_shots_packages}} && tests/ptyxis/shoot.sh _build/ptyxis/out'

# The Ptyxis that ptyxis-lane built: a user palette rewritten under an open terminal must show within 1 s (podman or docker).
ptyxis-palette:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{ptyxis_image}} bash -c 'dnf5 -y -q --setopt=install_weak_deps=False install {{ptyxis_shots_packages}} && tests/ptyxis/palette-test.sh _build/ptyxis/out'

libadwaita_image := "registry.fedoraproject.org/fedora:45@sha256:1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb"

# libadwaita rebuilt as the lane builds it (apex-lane's container half), in fedora:45 with podman or docker; RPMs in _build/libadwaita/out.
libadwaita-lane:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{libadwaita_image}} tests/lib/lane.sh libadwaita

# The libadwaita that libadwaita-lane built: an open window must take a rewritten apex.css within 1 s, and Fedora's must not (podman or docker).
libadwaita-radius:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{libadwaita_image}} bash -c 'dnf5 -y -q --setopt=install_weak_deps=False install ptyxis {{ptyxis_shots_packages}} && tests/libadwaita/radius-test.sh --stock && tests/libadwaita/radius-test.sh _build/libadwaita/out'

control_center_image := "registry.fedoraproject.org/fedora:45@sha256:1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb"

# desktop/control-center: its licence lines, the recipe's source1_paths, its series and the patches' From: lines; the Software Updates logic (gcc, glib2-devel).
control-center-test:
    tests/control-center/selftest.sh
    tests/control-center/state-test.sh

# gnome-control-center rebuilt as the lane builds it (apex-lane's container half), in fedora:45 with podman or docker; RPMs in _build/gnome-control-center/out.
control-center-lane:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{control_center_image}} tests/lib/lane.sh gnome-control-center

control_center_run_packages := "gnome-shell mesa-dri-drivers dbus-daemon python3-dbusmock python3-gobject at-spi2-core gcc util-linux adwaita-sans-fonts python3-dbus systemd gnome-backgrounds umockdev"

# The Settings that control-center-lane built, in a headless gnome-shell: board 11's captures, light and dark, and every row's binding; in _build/control-center/shots.
control-center-run:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{control_center_image}} bash -c 'dnf5 -y -q --setopt=install_weak_deps=False install {{control_center_run_packages}} && tests/control-center/run.sh _build/gnome-control-center/out'

nautilus_shots_packages := "gnome-shell mesa-dri-drivers dbus-daemon python3-dbusmock gcc util-linux at-spi2-core python3-gobject inkscape git-core glycin-thumbnailer adwaita-sans-fonts jetbrains-mono-fonts-all"
nautilus_image := "registry.fedoraproject.org/fedora:45@sha256:1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb"

# desktop/nautilus: its licence lines, the recipe's source1_paths, its series and the patches' From: lines; the footer's and count's texts (gcc, glib2-devel).
nautilus-test:
    tests/nautilus/selftest.sh
    tests/nautilus/format-test.sh

# nautilus rebuilt as the lane builds it (apex-lane's container half), in fedora:45 with podman or docker; RPMs in _build/nautilus/out.
nautilus-lane:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{nautilus_image}} tests/lib/lane.sh nautilus

# The nautilus that nautilus-lane built, captured in a headless gnome-shell with board 27's home, light and dark, and its assertions (podman or docker); in _build/nautilus/shots.
nautilus-shots:
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{nautilus_image}} bash -c 'dnf5 -y -q --setopt=install_weak_deps=False install {{nautilus_shots_packages}} && tests/nautilus/shoot.sh _build/nautilus/out'

s2c_image := "registry.fedoraproject.org/fedora:45@sha256:1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb"
s2c_packages := "ptyxis gnome-shell mesa-dri-drivers dbus-daemon dconf python3-dbusmock python3-gobject at-spi2-core gcc util-linux jq adwaita-sans-fonts"

# S2c's live radius end to end, after libadwaita-lane, control-center-lane and nautilus-lane: apex-session-agent from the pinned apex-system, Settings' Corner Radius pressed under open windows (podman or docker); in _build/s2c/radius.
s2c-radius:
    mkdir -p _build/s2c/rpms
    cp _build/libadwaita/out/*.rpm _build/gnome-control-center/out/*.rpm _build/nautilus/out/*.rpm _build/s2c/rpms/
    engine=$(command -v podman || command -v docker) && "$engine" run --rm -v "{{justfile_directory()}}:/apex-gnome:z" -w /apex-gnome {{s2c_image}} \
        bash -c 'tests/s2c/agent.sh && dnf5 -y -q --setopt=install_weak_deps=False install {{s2c_packages}} && tests/s2c/radius-test.sh _build/s2c/rpms _build/s2c/apex-session-agent'

# The script self-tests, as ci.yml runs them.
selftest:
    .github/scripts/selftest.sh

# The comment guard on every tracked file, or on the given ones (cargo install --git https://github.com/apex-linux/apex-ci apex-lint).
[positional-arguments]
lint-comments *paths:
    apex-lint comments "$@"
