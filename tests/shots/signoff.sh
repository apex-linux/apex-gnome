#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

usage() {
    cat <<'EOF'
usage: tests/shots/signoff.sh [--goldens] RPM_DIR [OUT]
       tests/shots/signoff.sh --collect G2_RUN SHELL_SHOTS OUT

The owner's sign-off set: each shell board's scene from the gnome-shell RPMs in RPM_DIR (the
lane's _build/gnome-shell/out), headless at scale 2, light and dark, as root in a throwaway
Fedora 45 container. No assertion beyond the scene having opened and the sign-off windows
having shown. It first installs the apex-desktop of
tests/lib/pins.sh (built with its make rpm, or from APEX_DESKTOP_SRC), whose vendor defaults
bring the Facets wallpapers, the Apex icon theme and the fonts, and the apps its dock lists,
then the image's other apps for the launcher (RPMs standing in for its Flatpaks), and takes
away the apps apex-desktop's build dependencies brought.
patched.sh then runs direct.sh's signoff part (main's capture and indicator cases, every
scene saved, and G2_SIGNOFF's real windows for the switcher and the overview);
tests/shell/shoot.sh shoots the greeter, the lock screen, polkit's dialog and the power-off
dialog. OUT (default _build/signoff) gets board-NN-SLUG-light.png and -dark.png for each
board, and signoff.json: each board's number, title, scene and fixture state, the apex-gnome
and apex-desktop pins, the layer's features enabled, the scale, the monitor and the launcher's apps
with the Flatpaks they stand in for; the runs'
logs stay in _build/signoff-work. A board whose scene has no capture, or a probe whose
windows never all reached the overview, fails the run, named. --collect does only that last
step, from a G2 run directory and shoot.sh's captures. --goldens then compares the boards with
the approved goldens (goldens.sh check OUT).
EOF
}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
# shellcheck source=tests/lib/pins.sh
. "$REPO/tests/lib/pins.sh"
# The favourites apex-desktop's override lists that Fedora ships, for the dock, and the fonts.
readonly APPS=(nautilus epiphany gnome-calendar gnome-music gnome-text-editor ptyxis gnome-control-center
    adwaita-sans-fonts jetbrains-mono-fonts-all)
# The image's other apps (apex-image's image/packages/gnome.txt) fill the launcher: GNOME keeps the dock's favourites out of it.
readonly GRID_APPS=(gnome-extensions-app loupe papers showtime decibels snapshot gnome-system-monitor baobab
    gnome-calculator gnome-characters gnome-clocks gnome-contacts gnome-weather gnome-font-viewer gnome-logs yelp
    gnome-disk-utility gnome-firmware gnome-maps)
# Apps the image lacks that Fedora's packages bring in, kept out of the launcher.
readonly NOT_IN_IMAGE=(inkscape gnome-tour firefox)
# ARCHITECTURE's core apps the image's gnome.txt still lacks, installed here as the image will have them.
readonly IMAGE_PENDING=()
# Board 16 shows a banner on purpose; on any other board a banner is a race the scene lost.
readonly BANNER_BOARDS=(16)
# The image's Flatpaks (apex-image's apex.preinstall), each with the RPM that stands in for it, if any.
readonly FLATPAK_STAND_INS='[{"flatpak": "org.gnome.Music", "rpm": "gnome-music"},
    {"flatpak": "io.github.kolunmi.Bazaar", "rpm": null, "standIn": "desktop entry"}]'
readonly SCALE=2
readonly MONITOR=2880x1800
readonly SHOOT=tests/shell/shoot.sh
readonly G2='tests/shots/direct.sh signoff'

# number|slug|title|source|light capture|dark capture|fixture state
readonly BOARDS="12|greeter|GDM greeter|$SHOOT|greeter-light-list|greeter-dark-list|the user list, apex and guest, on apex-desktop's greeter background
13|polkit|Authentication dialog|$SHOOT|polkit-light-open|polkit-dark-open|the shell's own dialog for an administrator, its PAM session never answering
14|power-off|Power off dialog|$SHOOT|end-session-light-power-off|end-session-dark-power-off|power off with an update staged (update1-mock.py), the update card on; no other user logged in, the greeter's session being of class greeter
15|alt-tab|Window switcher|$G2|default-signoff-alt-tab|dark-style-signoff-alt-tab|Text Editor, Calendar and Terminal open, the app switcher up
16|transients|OSD, banner and popup menu|$G2|default-surfaces|dark-style-surfaces|the volume OSD at 62 %, a banner with an action, a three-row popup menu
17|wifi-menu|Quick Settings: Wi-Fi submenu|$G2|default-quick-settings|dark-style-quick-settings|Quick Settings with the Wi-Fi menu open: Apex-5G connected, three networks in range, battery at 87 %
19|screenshot|Screenshot UI|$G2|default-screenshot|dark-style-screenshot|the screenshot UI over the desktop
20|lock|Lock screen|$SHOOT|lock-light-open|lock-dark-open|locked, the prompt asking for a password
22|tiling|Edge tiling|$G2|default-tile-preview|dark-style-tile-preview|the tile preview of the left half
34|date-menu|Calendar and notifications|$G2|default-datemenu|dark-style-datemenu|Monday 28 September 2026, two low-urgency notifications
35|overview|Overview|$G2|default-signoff-overview|dark-style-signoff-overview|the overview with Text Editor, Calendar and Terminal open, two workspaces
36|launcher|Launcher|$G2|default-launcher|dark-style-launcher|the app grid's first page, no folder open: the image's apps outside the dock
37|desktop|Desktop: dock and top bar|$G2|default-desktop|dark-style-desktop|the desktop with the dock and the bar, no window open
38|spotlight|Spotlight|$G2|default-spotlight-search|dark-style-spotlight-search|Spotlight with \"disk\" typed
39|indicators|Top bar: indicators|$G2|indicators-indicators-everything|indicators-dark-indicators-everything|everything: two input sources and the StatusNotifierItems sni-items.js starts"

die() { echo "signoff.sh: $*" >&2; exit 1; }

not_in_image() {
    local app
    for app in "${NOT_IN_IMAGE[@]}"; do
        ! rpm -q "$app" >/dev/null || die "$app is installed, and the image has no $app for the launcher to show"
    done
}

png() {
    [[ -s $1 && $(head -c 8 "$1" | od -An -tx1 | tr -d ' \n') == 89504e470d0a1a0a ]]
}

banners_of() {
    local g2=$1 shots=$2 log
    {
        for log in "$g2"/*.log; do
            [[ $log == *.late.log ]] || sed -n 's/.*APEXG2-CAPTURE //p' "$log"
        done
        for log in "$shots"/*.log; do
            sed -n 's/.*APEXLOCK //p' "$log" | jq -sc --arg shot "$(basename "$log" .log)" '
                add // {} | to_entries | map(select(.key | test("^(banner|bluetooth)[.]")))
                | group_by(.key | sub("^[a-z]+[.]"; ""))[] | select(any(.key | startswith("banner.")))
                | {file: "\($shot)-\(.[0].key | sub("^[a-z]+[.]"; "")).png",
                   banner: (map(select(.key | startswith("banner.")))[0].value),
                   bluetooth: (map(select(.key | startswith("bluetooth.")))[0].value // false)}'
        done
    } 2>/dev/null | jq -sc 'map({(.file): {banner, live: (.live // []), bluetooth: (.bluetooth // false)}}) | add // {}'
}

collect() {
    local g2=$1 shots=$2 out=$3 number slug title source light dark fixture variant scene from missing=() boards=()
    local commit features dock banners banner live
    mkdir -p "$out" || die "cannot create $out"
    banners=$(banners_of "$g2" "$shots")
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
                continue
            fi
            banner=$(jq -c --arg f "$scene.png" 'if has($f) then .[$f].banner else "unrecorded" end' <<<"$banners")
            live=$(jq -r --arg f "$scene.png" '.[$f].live // [] | join(", ")' <<<"$banners")
            if [[ $banner == '"unrecorded"' ]]; then
                missing+=("board $number ($title), $variant: no banner record for $scene")
            elif [[ $banner != null && " ${BANNER_BOARDS[*]} " != *" $number "* ]]; then
                missing+=("board $number ($title), $variant: a banner over $scene: $banner")
            fi
            [[ -z $live ]] || missing+=("board $number ($title), $variant: still live in $scene: $live")
            [[ $(jq -r --arg f "$scene.png" '.[$f].bluetooth // false' <<<"$banners") != true ]] ||
                missing+=("board $number ($title), $variant: the Bluetooth indicator shows in $scene")
        done
        boards+=("$(jq -nc --argjson board "$((10#$number))" --arg title "$title" --arg slug "$slug" --arg source "$source" \
            --arg light "$light" --arg dark "$dark" --arg fixture "$fixture" \
            '{board: $board, title: $title, slug: $slug, source: $source, fixture: $fixture, scene: {light: $light, dark: $dark},
              files: {light: "board-\($board)-\($slug)-light.png", dark: "board-\($board)-\($slug)-dark.png"}}')")
    done <<<"$BOARDS"
    for variant in default dark-style; do
        { cat "$g2/$variant.log" "$g2/$variant.late.log" 2>/dev/null || :; } | sed -n 's/.*APEXG2-SIGNOFF //p' |
            jq -se 'any(.previews == true)' >/dev/null ||
            missing+=("boards 15 and 35, $variant: the sign-off windows never all showed in the overview")
        scene=$(sed -n 's/.*APEXG2-SIGNOFF //p' "$g2/$variant.log" 2>/dev/null | jq -r '.error // empty' 2>/dev/null | head -n 1)
        [[ -z $scene ]] || missing+=("boards 15 and 35, $variant: $scene")
    done
    if ((${#missing[@]})); then
        printf 'signoff.sh: %s\n' "${missing[@]}" >&2
        die "${#missing[@]} scene(s) did not open as their boards need"
    fi
    commit=$(git -c safe.directory='*' -C "$REPO" rev-parse HEAD 2>/dev/null || echo "${GITHUB_SHA:-unknown}")
    features=$(sed -n 's/.*Apex: feature \([a-z-]*\) enabled.*/\1/p' "$g2/default.log" 2>/dev/null | sort -u | jq -Rsc 'split("\n") | map(select(. != ""))')
    dock=$({ cat "$g2/default.log" "$g2/default.late.log" 2>/dev/null || :; } | sed -n 's/.*APEXG2[A-Z-]* \({.*\)/\1/p' |
        jq -sc 'map(.dock?.items? // empty) | first // [] | map(select(.kind == "app") | .name)' 2>/dev/null)
    printf '%s\n' "${boards[@]}" | jq -s --arg commit "$commit" --arg desktop "$APEX_DESKTOP_REV" \
        --argjson features "${features:-[]}" --argjson scale "$SCALE" --arg monitor "$MONITOR" \
        --arg grid "${GRID_APPS[*]}" --argjson standIns "$FLATPAK_STAND_INS" --argjson dock "${dock:-[]}" \
        --arg pending "${IMAGE_PENDING[*]}" \
        '{commit: $commit, pins: {apexGnome: $commit, apexDesktop: $desktop}, scale: $scale, monitor: $monitor,
          features: $features, apps: {dock: $dock, grid: ($grid | split(" ")), flatpakStandIns: $standIns,
          notYetInImage: ($pending | split(" "))}, boards: .}' >"$out/signoff.json" ||
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
goldens=0
if [[ $1 == --goldens ]]; then
    goldens=1
    shift
    (($#)) || { usage >&2; exit 2; }
fi
[[ -e /run/.containerenv || -e /.dockerenv ]] || die "only inside a throwaway container"
rpms=$(cd -- "$1" && pwd) || die "no RPM directory $1"
out=${2:-$REPO/_build/signoff}
work=$REPO/_build/signoff-work
rm -rf "$work"
mkdir -p "$work"

# What an Apex image draws with: the pinned apex-desktop's wallpapers, icon theme, fonts and
# vendor defaults (its 90_apex.gschema.override), built as its own Makefile builds the RPM.
desktop=${APEX_DESKTOP_SRC:-$work/apex-desktop}
if [[ -z ${APEX_DESKTOP_SRC:-} ]]; then
    git -c safe.directory='*' init -q "$desktop"
    git -c safe.directory='*' -C "$desktop" fetch -q --depth 1 "$APEX_DESKTOP_URL" "$APEX_DESKTOP_REV" ||
        die "cannot fetch apex-desktop $APEX_DESKTOP_REV"
    git -c safe.directory='*' -C "$desktop" checkout -q --detach FETCH_HEAD
fi
dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install dnf5-plugins rpm-build make git-core \
    "${APPS[@]}" "${GRID_APPS[@]}" || die "cannot install the apps, the fonts and rpm-build"
rpm -qa --qf '%{NAME}\n' | sort >"$work/before-builddep.txt"
dnf5 -y -q --repo=fedora --repo=updates builddep "$desktop/packaging/apex-desktop.spec" || die "cannot install apex-desktop's build dependencies"
git config --global --add safe.directory '*'
make -C "$desktop" rpm BUILD_DIR="$work/apex-desktop-build" >"$work/apex-desktop-rpm.log" 2>&1 ||
    die "apex-desktop's make rpm failed; see $work/apex-desktop-rpm.log"
# Its build dependencies that bring an app go again, so the launcher holds none the image lacks (Inkscape).
mapfile -t apps < <(rpm -qa --qf '%{NAME}\n' | sort | comm -13 "$work/before-builddep.txt" - |
    while read -r p; do rpm -ql "$p" | grep '^/usr/share/applications/.*\.desktop$' >/dev/null && echo "$p"; done)
((${#apps[@]} == 0)) || dnf5 -y -q remove "${apps[@]}" || die "cannot remove apex-desktop's build dependencies ${apps[*]}"
not_in_image
# gnome-shell recommends Tour, and patched.sh installs the shell with its weak dependencies.
mkdir -p /etc/dnf/libdnf5.conf.d || die "cannot create /etc/dnf/libdnf5.conf.d"
printf '[main]\nexcludepkgs=%s\n' "$(IFS=,; echo "${NOT_IN_IMAGE[*]}")" >/etc/dnf/libdnf5.conf.d/90-signoff.conf ||
    die "cannot keep dnf5 from installing ${NOT_IN_IMAGE[*]}"
dnf5 -y -q --setopt=install_weak_deps=False --repo=fedora --repo=updates install "$work"/apex-desktop-build/rpm/RPMS/noarch/apex-desktop-*.rpm ||
    die "cannot install apex-desktop"
# Bazaar, a dock favourite, is a Flatpak Fedora has no RPM of: an entry with its name and the Apex theme's icon stands in.
[[ -e /usr/share/icons/Apex/scalable/apps/io.github.kolunmi.Bazaar.svg ]] || die "the Apex icon theme has no Bazaar icon"
printf '[Desktop Entry]\nType=Application\nName=Bazaar\nIcon=io.github.kolunmi.Bazaar\nExec=true\n' \
    >/usr/share/applications/io.github.kolunmi.Bazaar.desktop || die "cannot write Bazaar's stand-in entry"

PATCHED_RPMS=$rpms PATCHED_OUT=$work/g2 PATCHED_PART=signoff bash "$HERE/patched.sh" ||
    echo "signoff.sh: patched.sh exited $?; the boards it shoots are checked below"
# shoot.sh starts its own system bus and fixtures.
pkill -f /w/fixtures.py
pkill -x dbus-daemon
rm -f /run/dbus/pid /run/dbus/system_bus_socket
# Its own assertions are G2's business; a scene that did not open shows below.
bash "$REPO/$SHOOT" "$rpms" || echo "signoff.sh: shoot.sh exited $?; the boards it shoots are checked below"
not_in_image
collect "$work/g2/run" "$REPO/_build/gnome-shell/shots" "$out"
((goldens == 0)) || exec bash "$HERE/goldens.sh" check "$out"
