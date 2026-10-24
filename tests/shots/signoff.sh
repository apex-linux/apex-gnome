#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/signoff.sh RPM_DIR [OUT]
       tests/shots/signoff.sh --collect G2_RUN SHELL_SHOTS OUT

The owner's sign-off set: each shell board's scene from the gnome-shell RPMs in RPM_DIR
(the lane's _build/gnome-shell/out), headless at scale 2, light and dark, as root in a
throwaway Fedora 45 container. Review captures, not tests: no golden and no assertion
beyond the scene having opened. patched.sh runs direct.sh's signoff part (main's capture
and indicator cases, every scene saved); tests/shell/shoot.sh then shoots the greeter,
the lock screen, polkit's dialog and the power-off dialog. OUT (default _build/signoff)
gets board-NN-SLUG-light.png and -dark.png for each board, and signoff.json: each board's
number, title, scene and fixture state, the apex-gnome commit, the layer's features
enabled, the scale and the monitor; the runs' logs stay in _build/signoff-work. A board
whose scene has no capture fails the run, named. --collect does only that last step, from a G2 run directory and shoot.sh's
captures.
EOF
}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
readonly SCALE=2
readonly MONITOR=2880x1800
readonly SHOOT=tests/shell/shoot.sh
readonly G2='tests/shots/direct.sh signoff'

# number|slug|title|source|light capture|dark capture|fixture state
readonly BOARDS="12|greeter|GDM greeter|$SHOOT|greeter-light-list|greeter-dark-list|the user list, apex and guest, on apex-desktop's greeter background
13|polkit|Authentication dialog|$SHOOT|polkit-light-open|polkit-dark-open|the shell's own dialog for an administrator, its PAM session never answering
14|power-off|Power off dialog|$SHOOT|end-session-light-power-off|end-session-dark-power-off|power off with an update staged (update1-mock.py), the update card on; shoot.sh's logind mock also holds the greeter's session, so stock lists it under Other users are logged in
15|alt-tab|Window switcher|$G2|default-switcher|dark-style-switcher|five apps, the second highlighted
16|transients|OSD, banner and popup menu|$G2|default-surfaces|dark-style-surfaces|the volume OSD at 62 %, a banner with an action, a three-row popup menu
17|wifi-menu|Quick Settings: Wi-Fi submenu|$G2|default-quick-settings|dark-style-quick-settings|Quick Settings with the Wi-Fi menu open: Apex-5G connected, three networks in range, battery at 87 %
19|screenshot|Screenshot UI|$G2|default-screenshot|dark-style-screenshot|the screenshot UI over the desktop
20|lock|Lock screen|$SHOOT|lock-light-open|lock-dark-open|locked, the prompt asking for a password
22|tiling|Edge tiling|$G2|default-tile-preview|dark-style-tile-preview|the tile preview of the left half
34|date-menu|Calendar and notifications|$G2|default-datemenu|dark-style-datemenu|Monday 28 September 2026, two low-urgency notifications
35|overview|Overview|$G2|default-overview|dark-style-overview|the overview, two workspaces, no window open
36|launcher|Launcher|$G2|default-appgrid|dark-style-appgrid|the app grid's first page
37|desktop|Desktop: dock and top bar|$G2|default-desktop|dark-style-desktop|the desktop with the dock and the bar, no window open
38|spotlight|Spotlight|$G2|default-spotlight-search|dark-style-spotlight-search|Spotlight with \"disk\" typed
39|indicators|Top bar: indicators|$G2|indicators-indicators-everything|indicators-dark-indicators-everything|everything: two input sources and the StatusNotifierItems sni-items.js starts"

die() { echo "signoff.sh: $*" >&2; exit 1; }

png() {
    [[ -s $1 && $(head -c 8 "$1" | od -An -tx1 | tr -d ' \n') == 89504e470d0a1a0a ]]
}

collect() {
    local g2=$1 shots=$2 out=$3 number slug title source light dark fixture variant scene from missing=() boards=()
    local commit features
    mkdir -p "$out" || die "cannot create $out"
    while IFS='|' read -r number slug title source light dark fixture; do
        for variant in light dark; do
            scene=$light
            [[ $variant == dark ]] && scene=$dark
            from=$g2/captures/$scene.png
            [[ $source == "$SHOOT" ]] && from=$shots/$scene.png
            if png "$from"; then
                cp "$from" "$out/board-$number-$slug-$variant.png"
            else
                missing+=("board $number ($title), $variant: no capture of $scene ($source)")
            fi
        done
        boards+=("$(jq -nc --argjson board "$((10#$number))" --arg title "$title" --arg slug "$slug" --arg source "$source" \
            --arg light "$light" --arg dark "$dark" --arg fixture "$fixture" \
            '{board: $board, title: $title, slug: $slug, source: $source, fixture: $fixture, scene: {light: $light, dark: $dark},
              files: {light: "board-\($board)-\($slug)-light.png", dark: "board-\($board)-\($slug)-dark.png"}}')")
    done <<<"$BOARDS"
    if ((${#missing[@]})); then
        printf 'signoff.sh: %s\n' "${missing[@]}" >&2
        die "${#missing[@]} scene(s) did not open"
    fi
    commit=$(git -c safe.directory='*' -C "$REPO" rev-parse HEAD 2>/dev/null || echo "${GITHUB_SHA:-unknown}")
    features=$(sed -n 's/.*Apex: feature \([a-z-]*\) enabled.*/\1/p' "$g2/default.log" 2>/dev/null | sort -u | jq -Rsc 'split("\n") | map(select(. != ""))')
    printf '%s\n' "${boards[@]}" | jq -s --arg commit "$commit" --argjson features "${features:-[]}" \
        --argjson scale "$SCALE" --arg monitor "$MONITOR" \
        '{commit: $commit, scale: $scale, monitor: $monitor, features: $features, boards: .}' >"$out/signoff.json" ||
        die "cannot write $out/signoff.json"
    echo "signoff.sh: $(jq '.boards | length' "$out/signoff.json") boards, light and dark, in $out"
}

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    --collect)
        (($# == 4)) || { usage >&2; exit 2; }
        collect "$2" "$3" "$4"
        exit ;;
    '') usage >&2; exit 2 ;;
esac
[[ -e /run/.containerenv || -e /.dockerenv ]] || die "only inside a throwaway container"
rpms=$(cd -- "$1" && pwd) || die "no RPM directory $1"
out=${2:-$REPO/_build/signoff}
work=$REPO/_build/signoff-work
rm -rf "$work"

PATCHED_RPMS=$rpms PATCHED_OUT=$work/g2 PATCHED_PART=signoff bash "$HERE/patched.sh" ||
    echo "signoff.sh: patched.sh exited $?; the boards it shoots are checked below"
# shoot.sh starts its own system bus and fixtures.
pkill -f /w/fixtures.py
pkill -x dbus-daemon
rm -f /run/dbus/pid /run/dbus/system_bus_socket
# Its own assertions are G2's business; a scene that did not open shows below.
bash "$REPO/$SHOOT" "$rpms" || echo "signoff.sh: shoot.sh exited $?; the boards it shoots are checked below"
collect "$work/g2/run" "$REPO/_build/gnome-shell/shots" "$out"
