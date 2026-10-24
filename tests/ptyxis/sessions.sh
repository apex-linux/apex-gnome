#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# What fixture.c prints for each program of board 32's sessions, and how each ends.
set -euo pipefail

dir=${1:?usage: sessions.sh DIR}
mkdir -p -- "$dir"

esc=$'\e'
dim="${esc}[2m" red="${esc}[31m" green="${esc}[32m" blue="${esc}[34m" bold="${esc}[1m" off="${esc}[0m"

cat >"$dir/claude.out" <<EOF
${dim}> ${off}Turn on dock glass in the Apex layer

${blue}● ${off}Updated ${bold}desktop/shell/js/ui/apex/layer.js${off}
${dim}    10 ${off}${red}- const FEATURES = [];${off}
${dim}    10 ${off}${green}+ const FEATURES = ['dock-glass'];${off}
${blue}● ${off}Updated ${bold}…/theme/apex/_apex-tokens.scss${off}${dim}  +10 −4${off}

  Run the checks before I open the pull request?
${dim}  \$ ${off}${bold}just check${off}

${blue}${bold}❯ 1. Yes${off}
  2. Yes, and don't ask again for just check here
  3. No, and tell claude what to do instead
EOF
printf '4\n' >"$dir/claude.bell"

cat >"$dir/just.out" <<EOF
${bold}== 1/4 the apex RPM (apex-system) and apex-desktop (apex-desktop)${off}
${green}${bold}    Finished${off} \`release\` profile [optimized] target(s) in 28.87s
${bold}== 2/4 libfprint (apex-kernel)${off}
${bold}== 3/4 rebuild lane${off}
${green}built ${off}gnome-shell-0:51.0-1.fc45.apex18.x86_64 ${dim}b750e7d992087e4f…${off}
${green}built ${off}gnome-shell-common-0:51.0-1.fc45.apex18.noarch ${dim}9db5e70975c10576…${off}
${bold}== 4/4 image${off}
${bold}== Pull base images${off}
Copying blob ${dim}2b9f61c84e07${off} [${blue}=========================>${off}           ] 412.3MiB / 563.0MiB
$esc]9;4;1;73$esc\\
EOF

cat >"$dir/cargo.out" <<EOF
${green}${bold}   Compiling${off} apex-session-agent v0.1.0 (~/src/apex-system/crates/apex-session-agent)
${green}${bold}    Finished${off} \`test\` profile [unoptimized + debuginfo] target(s) in 41.27s

running 214 tests
test result: ${green}${bold}ok${off}. 214 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.92s
EOF
printf '0\n' >"$dir/cargo.exit"

cat >"$dir/rpmbuild.out" <<EOF
Processing files: apex-desktop-0.1.0-0.fc45.noarch
${red}error: ${off}File not found: …/usr/share/glib-2.0/schemas/io.github.apex_linux.Desktop.gschema.xml

${bold}RPM build errors:${off}
    File not found: …/usr/share/glib-2.0/schemas/io.github.apex_linux.Desktop.gschema.xml
EOF
printf '1\n' >"$dir/rpmbuild.exit"

cat >"$dir/ssh.out" <<EOF
${dim}Last login: Sat Oct 24 08:51:12 2026 from 10.0.2.2${off}
${green}builder@apex-builder${off}${dim}:${off}${blue}~${off}${dim}\$ ${off}podman images
${bold}REPOSITORY                    TAG    IMAGE ID      CREATED       SIZE${off}
localhost/apex                build  3c1e9a2f7b4d  2 hours ago   4.12 GB
quay.io/fedora/fedora-bootc   45     8f02d6a1c9e3  3 days ago    1.71 GB
${green}builder@apex-builder${off}${dim}:${off}${blue}~${off}${dim}\$ ${off}
EOF

cat >"$dir/git.out" <<EOF
${red} M${off} desktop/shell/data/theme/apex/_apex-tokens.scss
${red} M${off} desktop/shell/js/ui/apex/layer.js
EOF
printf '0\n' >"$dir/git.exit"
