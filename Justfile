# SPDX-License-Identifier: GPL-3.0-or-later

set shell := ["bash", "-euo", "pipefail", "-c"]

# List the recipes.
default:
    @just --list

# The tests, eslint, the theme compile, the script self-test and the comment guard, as ci.yml runs them (tests that need a missing tool skip).
check: layer-test shots-test eslint theme selftest
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

# The script self-tests, as ci.yml runs them.
selftest:
    .github/scripts/selftest.sh

# The comment guard on every tracked file, or on the given ones (cargo install --git https://github.com/apex-linux/apex-ci apex-lint).
[positional-arguments]
lint-comments *paths:
    apex-lint comments "$@"
