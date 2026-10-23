# SPDX-License-Identifier: GPL-3.0-or-later

set shell := ["bash", "-euo", "pipefail", "-c"]

# List the recipes.
default:
    @just --list

# The tests, the script self-test and the comment guard, as ci.yml runs them (tests that need a missing tool skip).
check: layer-test shots-test selftest
    apex-lint comments

# The Apex layer's safety net in gjs: kill switches, fault injection, crash guard, live layer cycles.
layer-test:
    tests/layer/run.sh

# G2's own logic without the VM: the capture comparison, the token file, the top-bar assertions, the fixtures.
shots-test:
    tests/shots/selftest.sh

# The script self-tests, as ci.yml runs them.
selftest:
    .github/scripts/selftest.sh

# The comment guard on every tracked file, or on the given ones (cargo install --git https://github.com/apex-linux/apex-ci apex-lint).
[positional-arguments]
lint-comments *paths:
    apex-lint comments "$@"
