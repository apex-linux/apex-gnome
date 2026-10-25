# G2: the headless shell

G2 runs the gnome-shell of a built image headless, at scale 2, and asserts what it
draws and how its safety net behaves ([ARCHITECTURE §11](https://github.com/apex-linux/apex/blob/main/docs/ARCHITECTURE.md#11-quality-gates),
the ROADMAP S1a exit). It needs the built image and rootful podman, so it runs in the builder VM, never
in GitHub's CI:

```bash
just vm-image    # builds localhost/apex:build in the builder VM
just vm-g2       # G2 on it; or: just vm-g2 IMAGE
```

In the VM, apex-image runs `tests/shots/run.sh [IMAGE]` from the apex-gnome commit
`components.lock` pins, with `G2_IMAGE_DIR` set to its `image/` and `G2_REPOS_BASE` to
its Containerfile's `REPOS_BASE`. It runs G2 twice (`G2_RUNS`,
default 2; `just vm-image` always runs it twice), writes each run to
`_build/g2/<UTC time>/run-N/` (`_build/g2/latest` points at the newest, and the newest 5
are kept), asserts each run and then that the second agrees with the first. Each
assertion prints one `PASS`, `FAIL` or `GAP` line (see "Known gaps"); the summary is
`assert.txt` and `stable.txt` in each run directory. `result.txt` names the image, the
number of runs, the sha256 of the lane lock the image carries, and the status. apex-image's
`tools/builder-vm/builder-vm.sh fetch` copies one to the host.

CI runs what needs no image: shellcheck of these scripts, and `selftest.sh`
(`just shots-test`), which tests the capture comparison, the reading of the token file,
the top-bar, clock and layer-cycle assertions, `clock.c`, and `fixtures.py` on a private bus, read
back through libnm, gnome-bluetooth and UPower's D-Bus API as the shell reads it.
`smoke.sh` then runs `direct.sh fedora` on Fedora's own gnome-shell in a Fedora 45
container, with the assertions that need no Apex build: a harness change that keeps the
shell from starting or reporting fails in CI, before a builder VM spends a G2 run on it.
A case that gets no report within `direct.sh`'s timeout stops G2 at once.

## What one run does

| Step | Where | Asserts |
|---|---|---|
| G1's `image/checks/desktop.sh` | a container of the image | it passes on the image under test, so no text file under `/usr` or `/etc` names `APEX_SHELL_TEST_FAULT` |
| `direct.sh main` | a container of the image plus `dbus-daemon` (the image has no `dbus-run-session`), `python3-dbusmock` and `gcc` for `clock.c`; `rpm -V` shows the shell's packages unmodified | each case below: one headless shell with a fresh home, dconf and runtime directory, the fixtures on the system bus and the fixed clock (see "Fixtures and the clock") |
| `direct.sh kernel` | the same, with `apex.safe=1` bound over `/proc/cmdline` | the kernel switch |
| `direct.sh fedora` | the same image with Fedora's own gnome-shell and gnome-shell-common of the tested NVR in place of the Apex build, downloaded from Fedora's repositories; each RPM must report `digests signatures OK` against a keyring that holds Fedora's key alone, so an unsigned RPM fails | the baseline of the captures |
| `guard.sh` | a container of the image booted with its own systemd; a test user's `systemd --user` with the image's unmodified units | the crash guard, and that neither the user manager nor the shell's unit sets `APEX_SHELL_TEST_FAULT` |
| `assert.sh` | the builder VM; `compare.js` in a container of the image | everything below |

The direct cases:

| Case | Settings | Asserts |
|---|---|---|
| `default` | `color-scheme` `'default'` | the Apex light sheet with its marker, `prefer-light`, no fault feature, the crash guard's marker created and removed; Super+Space (`toggle-spotlight`) registered in the normal and overview modes; the panel showed the one-time search hint (`search-hint-shown` true; until apex-desktop's schema has the key, the shell reports `no-key`); the top bar's, the dock's and the shell surfaces' metrics, light |
| `default-scale1` | as `default`, on a 1440x900 virtual monitor at scale 1, as the desktop VM runs | the Apex light sheet; the top bar's, the dock's and the shell surfaces' metrics at scale 1 |
| `dark-style` | `prefer-dark` | the Apex dark sheet; the top bar's, the dock's and the shell surfaces' metrics, dark; then the probe clicks Quick Settings' Dark Style toggle (its own `clicked` signal): the toggle turns off, writes `color-scheme` `'default'`, and the running shell loads the Apex light sheet |
| `high-contrast` | the capture settings with `org.gnome.desktop.a11y.interface high-contrast` true | every Apex surface's contrast in the high-contrast sheet (see "Accessibility") |
| `large-text` | the capture settings with `text-scaling-factor` 1.25 | every Apex surface's text whole, on the screen, inside its surface and clear of the rest (see "Accessibility") |
| `dock-intellihide`, `dock-intellihide-dark` | the capture settings, light or dark, without hot corners (the headless pointer starts at 0,0, in the corner); the probe starts `maximised-window.js`, one maximised GTK window | the dock shows, then hides behind the maximised window as the bar turns solid; a virtual pointer pushing against the bottom edge under it reveals it, under the pointer; moving away hides it; the overview shows it; with `dock-intellihide` off it stays, and while it does, `show-focused-app-name`, `dock-icon-size` (small, then large), `dock-running-indicators` and `dock-show-trash` each change the running shell (the name hidden; every icon 46, then 62; the running dot cleared; Trash gone), and each reset changes it back (the name; `$apex_dock_icon_size`; the dot in `$apex_dock_dot`; Trash last); the key back on, it hides again; the window gone, it shows. The maximised and revealed scenes are captured beside board 37's |
| `dock-one-gpu` | the capture settings, after `fixtures.py --gpus 1` (put back to two after it) | switcheroo-control reports one GPU, and the dock's first app's menu offers no "Launch Using Discrete Graphics Card" |
| `no-dock` | the capture settings with `disabled-features` `['dock']`; the probe opens three `window.js` windows and the overview (`G2_OVERVIEW_WINDOWS=1`) | the overview's own dash is back, so the `workspace-bottom` hook gives stock's edge, the monitor's bottom; every caption shows, none over another window's preview or caption |
| `stock-light`, `stock-dark` | `APEX_SHELL_SAFE=1` with `prefer-light` or `prefer-dark` | upstream's sheet of that variant from `theme/stock/`; the overview's thumbnails at upstream's maximum scale 0.05 and at the effective scale of Fedora's build; the rebuilt high-contrast sheet, which safe mode keeps, is Fedora's up to the structure marker (Apex only appends); no Super+Space binding |
| `safe-env`, `layer-disabled`, `kernel-safe` | the three kill switches | upstream's dark sheet from `theme/stock/`, the stock colour scheme, every hook stock, no Super+Space binding, the reason logged; the same sheet in all three; `safe-env`: no search hint |
| `layer-cycles` | the capture settings; the probe sets `layer-enabled` false, then true, three times | while off: upstream's dark sheet from `theme/stock/`, the stock colour scheme, every hook stock, no Super+Space binding; while on: the Apex light sheet, `prefer-light` and Super+Space; each time it is on the stage holds the same actors, type by type, as at startup, and each time it is off the same as the first time (the first count waits out main.js's 20 s timeout for deferred work, which fills the overview's hidden dash; an `St.Icon` counts, not the texture child St gives it once it is first styled, which a dash hidden since startup decides); the layer logs each switch |
| `motion` | the capture settings with `enable-animations` true; the probe lifts the inhibit `main.js` puts on animations without hardware-accelerated rendering, starts `window.js`, a plain GTK 4 window, maximises and restores it once (mutter gives a first size change a 0 × 0 old frame, which stock never animates), maximises it and opens the overview, then sets `enable-animations` false, does both again and plays Locate Pointer | DESIGN's motion (ROADMAP S3c): the window actor's size-change transition and the overview's state transition are `CUBIC_BEZIER` with the control points (.2, .8) and (.2, 1), over 300 and 200 ms; with animations off, neither creates a transition, while Locate Pointer's ripple (`animationRequired`, an a11y aid) still takes stock's 830 ms |
| `idle` | the capture settings without hot corners, every feature of `layer.js`'s `FEATURES_IN_ENABLE_ORDER` on; `idle.js` lets the session settle, then watches the stage for 10 s, four times: the desktop, Quick Settings open, and both with Reduce Transparency | ROADMAP S3c's and S2b's exits: an idle desktop paints no frame and queues no relayout, glass or not (below, "The idle desktop") |
| `glass-load` | the capture settings without hot corners, `dock-intellihide` off while it runs; `glass-load.js` runs ADR 0014's scenarios A, B and C with `load-window.js`, once with the glass and once with Reduce Transparency | forwarded damage re-blurs each glass box in the frame its content changes; the bar and idle popovers do not re-blur; glass adds at most 1 % frames over Reduce Transparency in A and B (below, "Glass under load") |
| `glass-stress` | as `glass-load`, `G2_GLASS_STRESS_SECONDS` long (60 s; 300 s in the VM's G2) | `glass.js`'s stress on its synthetic box, and the real boxes under `load-window.js` for as long (below) |
| `fault-configure`, `fault-enable` | `APEX_SHELL_TEST_FAULT` | only the fault feature is off; the `witness` feature after it still enables; the rest of the layer runs, Super+Space included, and the shell survives |
| `fault-abort` | `abort-after-enable` | SIGABRT (exit 134) with the crash guard's marker left behind |
| `fedora-light`, `fedora-dark` | Fedora's build, `prefer-light` or `prefer-dark` | no Apex module; upstream's sheet at its own path, byte for byte the one safe mode loads from `theme/stock/` |
| `glass`, `fedora-glass` | the capture settings, `G2_GLASS=1` | patch 0003's glass in the frames the shell drew; the stock unlock blur captured in both shells (see "Glass") |

Every case: the probe ran (so the static import graph loaded), from `startup-complete`, and no `JS ERROR`;
the wall clock stands at the fixed time and the top bar's clock shows it (`Mon Sep 28`, EN SPACE, `09:41`).

A probe that runs longer than 30 s keeps `gnome-shell-perf-helper` awake with a call every 10 s:
the helper quits after 30 s without one, and `scripting.js`'s last call to it would then end the
shell with exit 1.

## Fixtures and the clock

Before the first case, `direct.sh` lets root own and call the fixtures' names on the
container's system bus (`/etc/dbus-1/system-local.conf`) and runs `fixtures.py`, which
starts python-dbusmock's `upower`, `networkmanager` and `bluez5` templates there, a bare
mock of switcheroo-control, which has no template, and (`G2_POWER_PROFILES=1`)
`upower_power_profiles_daemon`:

| Service | Fixture | The shell shows |
|---|---|---|
| UPower | a battery at 87 %, discharging (the display device) | `battery-level-80-symbolic` and, with `show-battery-percentage`, "87%" |
| NetworkManager | the primary connection: Wi-Fi "Apex-5G" at signal 90, connected globally, with "Apex-2.4G" (72) and the open "Library Guest" (48) in range, each with WPA2's ciphers or none, as libnm needs to list a network | `network-wireless-signal-excellent-symbolic`, and three networks in the Wi-Fi menu |
| BlueZ | the Bluetooth keyboard "Keychron K3", paired and connected | no glyph: the status pill shows network, volume and battery only (the `panel` feature) |
| switcheroo-control | the laptop's two GPUs, "AMD Radeon Graphics" the default and "NVIDIA GeForce RTX 3050 Laptop GPU" (`HasDualGpu`); `fixtures.py --gpus 1` leaves the iGPU alone | "Launch Using Discrete Graphics Card" in an app's menu, the dock's included |
| power-profiles-daemon | the Balanced profile, with Power Saver and Performance | the Power Mode toggle, lit at Balanced (the `quick-settings` feature); no glyph in the status pill |

`fixtures-PART.txt` holds what the bus reports afterwards, and `assert.sh` checks it for
each container. `direct.sh` builds `clock.c` and preloads it into each shell with
`G2_CLOCK_EPOCH` at 2026-09-28 09:41:00 UTC: reads of the wall clock return that time,
while timers and frames keep the real clocks. It stops before the first case when the
clock does not hold. libfaketime cannot do this: it converts every absolute timer as if
it ran on the wall clock, so mutter's frame timer never fired and no shell started.
The guard's shells, started by systemd, keep the real clock and have no fixtures.

The layer follows `layer-enabled` live in a shell that started with it on
([DESIGN.md](https://github.com/apex-linux/apex/blob/main/docs/DESIGN.md#schema-iogithubapex_linuxapexdesktop): the layer reads
every key live): `false` disables the features, every hook gives stock, and the session
mode recomputes, so `main.js` loads the sheet from `theme/stock/`; `true` brings them
back. `disabled-features` applies live too: a feature put in it is disabled and its hooks
give stock, and one taken out configures and enables afresh. A feature that failed stays
off for the session. A shell that started with `layer-enabled` off stays stock until the
next login, so the crash guard's switch holds. `tests/layer/run.sh` covers these rules.

gnome-shell connects the automation script to `startup-complete` only after it has
imported it, so a startup that completes during the import never runs the script and
leaves the shell up: 8 of 24 starts in a reproduction of the guard's `systemd --user`
sequence. `probe.js`'s `init()` then runs the script itself and prints `APEXG2-LATE`.
In such a shell `main.js`'s `startup-complete` handler (the "GNOME Shell started" line,
the action mode, the GDM registration) has not run, so `direct.sh` runs that case once
more (keeping the first log as `CASE.late.log`), and a second late start fails it. A late
guard phase is listed in `assert.txt`.

The crash-guard phases (`guard.sh`): an abort 65 s after start does not trip the guard;
`abort-after-enable` trips it (the unit fails, `apex-shell-safe.service` runs,
`layer-enabled=false`, the agent's marker exists); the next start is stock;
`layer-enabled=true` brings Apex back; `dark-off`: with `prefer-dark`, the probe clicks
the Dark Style toggle off, the shell turns light, and afterwards no Apex user unit is
active and none, nor an Apex D-Bus service, started (the ROADMAP's "no agent runs");
the trip again with dconf already running. `direct.sh` and `guard.sh` refuse to run
outside run.sh's container (`/run/.containerenv`).

## The backdrop

Every case runs over a pinned backdrop, never whatever the session would load: a shell
without one draws GNOME's solid fallback, and contrast measured over glass would pass or
fail with the wallpaper. `direct.sh` sets `org.gnome.desktop.background` itself, before the
case's own settings: apex-desktop's Facets (`picture-uri` and
`picture-uri-dark` at `/usr/share/backgrounds/apex/apex-facets-{light,dark}.png`, `zoom`),
so a case shows the light or dark one with its style and looks like the product. An Apex
image carries them, and `run.sh` stops before G2 when its image has none; `patched.sh` and
`smoke.sh` first run `backdrops.sh`, which renders the apex-desktop of `tests/lib/pins.sh`
(or `APEX_DESKTOP_SRC`) there as apex-desktop's spec does, unless they are already in place.
`direct.sh` refuses to start without them.

The setting is not trusted alone. After its first report the probe (`backdrop.js`) compares
12 patches of 24 px across the middle of the empty desktop with the expected image, scaled
to the screen as `zoom` draws it, and waits up to 10 s for the shell's asynchronous load:
each patch's mean within 12/255. `backdrop_painted` fails a case whose backdrop never
painted, naming the colour the desktop showed instead, or that painted another backdrop
than its style's.

The contrast cases run once more over a stress backdrop, GNOME's solid fallback `#013b88`,
which the overview's scrim saturates by 1.5: `default-solid`, `dark-style-solid`,
`high-contrast-solid` and `large-text-solid` (`G2_BACKDROP=solid`), with the same
assertions as their Facets twins, so a contrast regression cannot hide behind a friendly
wallpaper.

## Captures

The capture cases (`default`, `default-scale1`, `dark-style`, `stock-light`,
`stock-dark`, `fedora-light`, `fedora-dark`) run with animations and cursor blinking
off, two fixed workspaces, a 24-hour clock and the battery percentage shown. `probe.js` drops the
"Screen Lock disabled" notification a shell without GDM posts, captures two scenes,
`desktop` and `overview` (without key focus, so no cursor blinks), at 2880×1800
(`default-scale1`: 1440×900), and
reports the box of each masked actor. The shells run in containers with SELinux
labelling off (`--security-opt=label=disable`): glycin loads the wallpaper and the SVGs
and writes the captures from a bwrap sandbox, whose devpts mount SELinux denies to a
container. `compare.js` compares two captures pixel for pixel outside the
masks, and writes a difference image to `compare/` when they differ.

| Pair | Masks | Why |
|---|---|---|
| Apex light (`default`) against `fedora-light`; Apex dark against `fedora-dark`, the desktop scene | `panel` and `dock`: the top bar's and the dock's boxes in either capture | ROADMAP S1a: the captures equal Fedora's stock shell outside the masks; S1a and S2a restyle the top bar and add the dock |
| `stock-light` against `fedora-light`; `stock-dark` against `fedora-dark`, each scene | none | safe mode draws exactly Fedora's shell, its clock and status glyphs included |
| each capture case of run 2 against run 1 | none | the clock stands still |

The overview is not compared with Fedora's: the Apex bar is `$apex_bar_height` (32 px),
upstream's 2.2em, so the overview lays out on a work area that starts lower, and every
edge below the bar moves by a few pixels. Each capture case instead asserts that the
overview's work area starts at its bar's height; the Apex overview gets an approved
golden with S1b.

A mask may cover at most 5 % of a capture. A comparison fails unless `compare.js` exits
0, 1 or 2 and wrote one result for every planned pair: a gjs that cannot start, or dies,
fails G2 instead of leaving the captures unchecked.

## The top-bar metrics

`assert.sh`'s `top_bar` reads the bar the probe measured in the desktop scene and takes
every expected value from `desktop/shell/data/theme/apex/_apex-tokens.scss`, for the
case's variant: the bar's height, fill and type; the boxes' insets and gaps; each
button's height and colour; each pill's height, radius, padding, and fill while closed,
hovered and open; the clock's weight; where the pills sit, and that the Activities and
status buttons still reach the screen's left and right edges; the bar's transition; the
bar's glass, a `Shell.BlurEffect` of radius 2 × `$apex_bar_blur` × the monitor scale at
`$apex_bar_saturation` (the glass manager); with `translucent-top-bar` off, the bar `$apex_bar_solid` over a
`0 1px 0 $apex_border` line (the `panel` feature); the
workspace dots' gap, height and radius, the active dot `$apex_bar_dot_active_width` wide and
the others `$apex_bar_dot_size` square at .45; that the top-left pixel reaches the reactive
4 × 4 hot-corner zone; "Desktop" at `$apex_font_bar_emphasis_weight` after the Activities pill,
as nothing has focus; the search button at the start of the right box and the status pill at its end, a
`$apex_bar_search_width` × `$apex_bar_pill_height` pill named "Search (Super+Space)" (both
the `panel` feature); the clock's unread-notification dot (the probe
posts one low-urgency notification); that the diamond is drawn (at least a quarter of
its stroke's area in capture pixels of the bar's colour, left of the dots, at the
capture's scale); the status pill's glyph gap and glyph size, the fixtures' Wi-Fi and
battery glyphs, and the battery's "87%" at `$apex_font_bar_percentage_size`; that neither the
fixtures' Bluetooth keyboard nor Do Not Disturb adds a glyph; on the lock screen and the
greeter (the probe adds the panel's `unlock-screen` style class), that upstream's hover
fill of the status button is centred on its pill; and with Large Text (the probe sets
`text-scaling-factor` 1.25) that the bar, the clock pill and the glyphs keep their px
sizes while the clock text grows to 1.25 × 13.5 px and stays within its pill. The probe
measures in CSS px through St itself, so the values hold whether mutter lays the stage
out in logical or physical pixels.

`dock_metrics` reads the dock the same way, against the same token file: shown, centred
and `$apex_dock_bottom_gap` above the bottom edge; its background's radius
`$apex_radius_dock`; every icon `$apex_dock_icon_size` (`dock-icon-size` medium); the apps
first, then the separator, Show Apps and Trash, with no separator among the apps; the
full-colour Show Apps icon; and in the overview the dock shown, the overview's own dash
hidden and its workspaces laid out above the dock. Its first app's menu, stock's app menu,
offers "Launch Using Discrete Graphics Card" while the fixtures' switcheroo-control
reports two GPUs. In `dock-one-gpu` it reports the iGPU alone, as on the laptop with
`/apex/pair-mode` off, when no NVIDIA driver is bound and the dGPU has no DRM card, and the
same menu offers no such item. The safe-mode cases have no dock, and the Apex captures mask it, as they mask the
bar, against Fedora's, whose desktop has none.

## App indicators

The cases `indicators`, `indicators-scale1` and `indicators-dark` are shells of their own,
set as `default`, `default-scale1` and `dark-style` are plus two input sources (US and
French). `G2_INDICATORS=1` runs `indicators.js`, which starts `sni-items.js`, a gjs process that exports four
StatusNotifierItems, each with a DBusMenu and on its own session-bus connection as separate
apps are, and registers them with the shell's watcher. Every call an item gets lands in
`<case>-sni.log`. `indicator_metrics` asserts, against the token file:

- no indicators and no divider before any item registers, and none after the apps quit;
- the four in the order they registered, then the divider, then the search button;
- each a `$apex_indicator_width` × `$apex_bar_pill_height` pill, radius
  `$apex_radius_bar_pill`, `$apex_bar_gap` apart, its glyph `$apex_bar_icon_size` in
  `$apex_bar_fg` and centred, the theme's `-symbolic` icon for a named one;
- the password manager's red pixmap drawn as a mask: the bar's colour, and no red left;
- Chat's NeedsAttention dot: `$apex_indicator_dot_size`, the accent, at its offsets;
- the divider's size, colour and its distance from both neighbours;
- Chat's menu on a secondary click: radius `$apex_radius_menu`, at least
  `$apex_indicator_menu_width` wide, the title as a `$apex_indicator_menu_header_height`
  header in `$apex_fg_dim`, `$apex_menu_row_height` rows, its two toggles as switches in the
  app's states, "Ctrl+Shift+C" dimmed; the opened, clicked and closed events in the log;
- Activate on a primary click;
- with a fifth item, three shown and "+2", and the overflow menu's two rows: glyph, title
  and chevron;
- board 39's "everything", with the camera and microphone indicators, the recording and
  the sharing buttons shown by the probe: the right box's order (indicators, divider,
  search, recording, input chip, sharing, status pill); the privacy group's size, colour,
  glyphs and place in the status pill, whose start narrows for it and widens again once
  nothing is in use; the recording pill's stop square and tabular timer; the sharing
  pill's glyph, square, name and gap to the status pill; the input chip's "EN", font,
  tracking and minimum width.

The captures `<case>-indicators.png`, `<case>-indicators-everything.png`,
`<case>-indicator-menu.png` and `<case>-indicator-overflow.png` show the bar, the bar in
"everything", Chat's menu and the overflow menu.

## The shell surfaces' metrics

`assert.sh`'s `shell_surfaces` runs in `default`, `default-scale1` and `dark-style`. In
the desktop scene, after its capture, the probe opens a stock popup menu (two rows, a
separator, a row with a glyph), the volume OSD at 62 % and a normal-urgency banner with
one action, together as on canvas board 16, measures them and closes them before the
overview. Every expected value comes from `_apex-tokens.scss`, for the case's variant:

- the popup menu: `$apex_panel_solid`, `$apex_fg`, radius, the ring as a border, the
  shadow, its inset and minimum width, the rows' height, radius, padding, glyph gap and
  hover fill, the 1 px gap between rows, the separator's colour, inset and margins, the
  row glyph's size;
- the OSD: height, radius, `$apex_panel`, ring and shadow, side inset, gap, type, glyph,
  the level's size, track and accent fill, and its distance from the bottom edge;
- the banner: width, radius, `$apex_panel`, ring and shadow, inset, its gap below the
  bar, the header, title and body type, the icon and its gap, the close button, and the
  action buttons' height, radius, fill, type and gap (read from the theme: stock shows
  them only in an expanded banner).

`quick_settings` runs in the same cases. The probe opens Quick Settings and the Wi-Fi
toggle's menu (the fixtures' Wi-Fi checks the toggle), captures them with
`G2_SURFACE_SCENES=1`, and reads: the panel's width, radius, tint, inset, ring and shadow; the grid's gaps and the gap
under the top row; the round buttons and the battery pill; the toggles' size, fills
(checked, unchecked, hovered), padding, type and subtitle opacity; the menu arrow's width
and shade, without a separator; a slider in a stand-in `.quick-slider` row (no slider shows
without audio or a backlight); and the Wi-Fi card, its header glyph circle, title and rows.
The fixtures' NetworkManager lists no access points, so the card's network list is empty.

`window_switcher` runs in the same cases. G2 opens no windows, so the probe shows a stock
`SwitcherList` of five AppIcon-shaped items (a 96 px icon over a name, as `altTab.js`
builds them) with the second selected, and reads the list's tint, radius, inset, ring and
shadow, the tiles' gap, radius, padding and fills, and the names' type.

`modal_dialog` runs in the same cases. The probe opens a stock `ModalDialog` shaped like
polkit's (a `MessageDialogContent`, a password entry, Cancel and a default Authenticate),
captures it with `G2_SURFACE_SCENES=1`, and reads the box's fill, radius, width, ring,
shadow, inset and gaps, the title and text, the entry at rest and focused, and both buttons.
It then opens the shell's own power-off dialog over D-Bus, as gnome-session does, and reads
its width and gaps, the end-session feature's icon circle, the title's tracking, the
countdown's figures, and the row: the buttons' order, widths, gap and fills.
Last, with `update1-mock.py` (python-dbusmock's Update1, started by `direct.sh`) moved to
`staged` and then `ready-for-reboot`, it opens the restart dialog and reads board 14's
update card: its place under the text, inset, radius, gap, fill and ring, the icon, the
title and the versions, the switch (on, sensitive only when staged) and Restart's label,
capturing `end-session-update` and `end-session-ready`.

`date_menu` runs in the same cases. The probe posts two low-urgency notifications (no
banner), opens the calendar menu at the fixed date, captures it with
`G2_SURFACE_SCENES=1`, and reads the popover's tint, inset and column widths, the
notification card's fill, ring, radius, inset, gap, type, icon and close button, the
footer and Clear, the date labels, the month card and its name, headings and days
(weekday, weekend, other month, today), and the events card.

`overview_style` reads the overview scene in the same cases, after its capture: the
scrim, the search field at rest and focused and its gap under the bar, the thumbnails'
gap, radius and ring and the current one's ring, and, as stand-ins since G2 opens no
windows and searches nothing, a window title and a search section.

`app_grid` runs in the same cases. The probe turns the dash's Show Apps on, reads an app
tile (at rest, hovered, focused) and the fixture image's System folder, opens the folder
and reads its dialog, captures it with `G2_SURFACE_SCENES=1`, and reads the hidden
running dot, page indicator and page hint from stand-ins.

`overview_layer` checks the `overview` layer feature in the same cases, in the empty
overview the scene captured: no background card behind the active workspace, "No open
windows" centred on it in `$apex_fg_dim` at `$apex_font_workspace_empty_size`, the
thumbnails at scale .081 (one drawn at .081 of the work area, 117 × 70 on 1440 × 900)
and the threshold of one workspace, and the launcher's grid at 7 columns, 4 rows and
88 px icons. In that overview there is no window, so the `window-title-visible` hook's answer
stands in for a title shown without hover. Then the probe opens three `window.js` windows
(portals off, so the sign-off part's apps cannot delay them), opens the overview, sets a
fixture gradient wallpaper while it shows, and captures `overview-windows`. Every caption is shown, and none overlaps another
window's preview, another caption or the dock. The last row's captions end
`$apex_dock_bottom_gap` or more above the dock. Each workspace thumbnail draws the wallpaper:
its centre's luminance spreads 0.1 or more, where stock's flat fill gives 0, so the
thumbnails also followed the live wallpaper change. The windows and the wallpaper go again
before the next scene. The `no-dock` case (`disabled-features=['dock']`) opens the same
three windows (`G2_OVERVIEW_WINDOWS=1`): there the `workspace-bottom` hook gives the monitor's
bottom edge, stock's, and the captions still clear each other.

`tile_preview` runs in the same cases. G2 opens no window to drag, so a stand-in actor in
the window group plays the window and the stock `TilePreview` opens over the left half of the
work area, captured with `G2_SURFACE_SCENES=1`. It reads the preview's box against the tile, its
clear inset border, the radius inside it, the accent fill and the inset accent ring.

`screenshot_ui` runs in the same cases. The probe opens the stock screenshot UI in its
selection mode, captures it with `G2_SURFACE_SCENES=1`, and reads the panel, the close button
in the heading row, the area buttons (Window insensitive with no window), the pointer toggle,
the capture button and its recording state, the screenshot/screencast switch, the selection's
shade, outline and handles, then the screen mode's frame; a checked window frame is a stand-in.

`quick_settings_layer` checks the `quick-settings` layer feature in the same cases, and
stock in the stock cases. The probe reads the grid's toggles in order (the VPN toggle by
its class: it has no title without a VPN connection), Power Mode, the status pill and Do
Not Disturb's subtitle, then clicks Power Mode twice: VPN right after Airplane Mode, Power
Mode lit through `apex-lit` with `checked` stock, the power-profile indicator out of the
pill, "Off" under a toggle without a subtitle of its own, and the clicks switching to the
last profile and back, still lit. Stock keeps VPN before Airplane Mode and nothing lit.
It also opens the Wi-Fi menu (board 17): the header's subtitle in the grid's column 3, row 0,
at its end; the fixtures' active network the only `:checked` row; each secure network's lock
right after its name, `$apex_quick_menu_lock_size` in `$apex_fg` at
`$apex_quick_menu_lock_opacity`. Stock keeps the subtitle under the title, no row checked
and each lock by its signal icon.

`shadow_layers` checks the `shadows` layer feature in the same cases. The probe opens
Quick Settings, the calendar and a stock `ModalDialog`, and reads each one's layer: shown,
on the surface's box, `0 $apex_shadow_2_y $apex_shadow_2_blur $apex_shadow_2`, Quick
Settings' at its radius, and the dialog's beside its box (above the lightbox). It counts
the stage's paints in the quieter of two idle 2 s windows with the feature on and with
`shadows` in `disabled-features`: the layers add none. The `motion` case, which opens the overview with a
window, checks the window preview's two layers and the `apex-window-preview` radius.

The `motion` case also audits reduced motion. It opens and closes each Apex surface once,
with animations on and then off: the dock's lift (a hovered icon) and intellihide (the window
maximised), the overview with its thumbnails, Spotlight, Quick Settings, the calendar and a
dialog with its shadow layer. Every ease goes through `environment.js`'s `ease`,
`ease_property` and `St.Adjustment.ease` (and their async forms), which the probe wraps to
read the transitions each call left, by the property's canonical name, and whether a
`ui/apex/` frame called it. With animations on, the dock's own eases last: the control. Off,
no ease, Apex's or stock's, leaves a transition above 0 ms but `animationRequired` ones, and a
failure names each that did. St skips CSS transitions itself with animations off
(`st-widget.c`), the top bar's `$apex_bar_transition` included.

`notifications_layer` checks the `notifications` layer feature in the same cases, and stock
in the stock cases. The probe posts three low-urgency notifications from one app, opens the
calendar and reads the cards' boxes, the first card's header line, glyph and icon, and the
footer; clicks Do Not Disturb; then empties the list. The feature lays the cards out one under
another without a group header, the header reads "app · time" without the glyph, a card
without an icon shows the app's, Do Not Disturb sits left of Clear, which ends at the footer's
right edge, the click turns banners off, and Clear stays shown, insensitive, once the list is
empty. Stock stacks the cards, keeps the glyph and hides Clear.

`derived_surfaces` reads surfaces with no board, which G2 never opens, from nested
stand-ins in the same cases: the workspace switcher and its dots, the resize popup, the
input method's candidates and a candidate, the run dialog's entry, an audio device tile
and the monitor number.
`spotlight_style` runs in the same cases. The probe opens Spotlight's own popup over
providers of its own, which return board 38's rows (G2's image has no files or settings to
find), types board 38's queries and, with `G2_SURFACE_SCENES=1`, captures each scene
(`spotlight-empty`, `spotlight-search`, `spotlight-calculator`, `spotlight-copied`, and
`spotlight-none` for a query with no results). It
reads the panel's width, its distance from the monitor's top edge, radius, tint, ring and
shadow; the field, its glyph, text and hint; the results' line and inset; the section
headers in board order; the rows, the selected row's accent tint, verb and Enter chip;
the Settings rows' tiles, their colours read from `settings-tiles.json`; the
calculator's result in tabular figures with Calculator as the first application; that an
empty query shows only the field, and the row of a query with no results; and, after Enter on the result, that Spotlight closed and the toast's size, tint,
inset, check circle, text and distance from the bottom edge. `spotlight_glass` checks that the open panel and
the toast carry their sheet's glass, σ 34 and σ 30 at 1.8, and that the glass feature gave each
a blur of radius 2 × σ × the monitor's scale.
`spotlight_keys` covers S3a's exit items in the real shell: with Settings answering only after the
1 s budget, Applications and Files show at 300 ms and still at 1200 ms, once Settings is cancelled;
Down ×4, Up ×1 and Down ×20, pressed through a virtual keyboard, move one selection across the
sections and stop at the last row; Enter opens that file through its provider; Esc closes, and
both pop Spotlight's modal.
In the overview scene, after its capture, the probe types into the overview's search entry
and checks that Spotlight opened with the text and the overview's own field emptied (patch 0013's hook).
`launcher_search` then checks the app grid's
pill: 400 px with "Search apps", "files" filtering the grid in its own box to apps with Files
first and selected and Spotlight closed, and "No Results" with its hint where board 36 puts it
(scenes `launcher` and `launcher-none`).

None of these surfaces is in a capture compared with Fedora, so the comparison with Fedora's build
is unchanged: the Apex overview is compared only run to run, and safe mode's with Fedora's.

## Glass

`glass.js` runs in the `glass` case on the Apex build and in `fedora-glass` on Fedora's.
It reads the frames the shell drew, as they went out, at the stage's `after-paint`: Cogl's
`read_pixels` writes to a caller's buffer, which gjs cannot pass, so `frame.c` wraps it
and `G2Frame-1.gir` declares it. `direct.sh` builds both into `/run/g2-frame` with gcc
and glib2-devel's `gi-compile-repository`; `paint-view` gives each frame's redraw clip.

A grid of 24 px tiles lies under a 320×80 glass box with the top bar's glass (ADR 0014:
σ 24, saturation 1.6, corners 18), `fine` on. Tiles under the box change colour, which
damages the tile alone:

| Step | Asserts |
|---|---|
| a tile changes | in each step below that needs a frame whose clip misses the box, another redraw can cover it (then a full redraw): the tile is damaged again, up to 5 times. The first frame's redraw clip leaves the box out and the effect redraws it on the next; that frame is `blur-ref.js`'s reference per channel within 4/255 inside, 12/255 in the band ds/2 px wide along the edges (ds the effect's own downscale) and 1/255 on average over the box. The first run fixed these (ROADMAP S2b): at ds 16 the edge band is the low-resolution blur's own clamping and upsampling, the interior's 4 is 8-bit intermediates times the saturation; llvmpipe is the reference renderer |
| a tile changes and the box's redraw is queued, as the glass manager forwards damage | the same frame is the box a full redraw draws, pixel for pixel |
| a tile changes, nothing forwarded | the frame draws the last result, pixel for pixel, and the next one is the full redraw's |
| the same with `fine` off | stock's effect in that frame differs from the full redraw and misses the tolerances above: the stale sampling the redraw-clip rule prevents, so the case can see it. |

`blur-ref.js` is a clamp-to-edge Gaussian at full resolution, CSS `saturate()` and the
rounded box's coverage, over the box alone; `blur-ref-test.js` tests it in `selftest.sh`.
In the same case the glass manager (`js/ui/apex/glass/`) is read on the live shell, light:
`glass_manager` asserts that the bar's blur is `$apex_bar_blur` at `$apex_bar_saturation`,
and Quick Settings', the calendar's (each opened) and a banner's `$apex_panel_blur` at
`$apex_panel_saturation`, each a `fine`, opacity-following background blur of radius
2 × sigma × the monitor scale; that with `reduce-transparency`, and with high contrast, no
actor on the stage carries a `Shell.BlurEffect` and the root carries `apex-solid`; that
with `disabled-features=['glass']` no actor carries one and the tints stay; and that the
glass comes back after each.

`shadows_under_glass` checks the `shadows` feature against the glass in the same case, light
and dark: `glass.js` lays the tile grid under Quick Settings, a popup menu and a dialog and
reads each box with `framePixels()`, once with the shadows on and once with `shadows` in
`disabled-features`. The pixels the rounded box covers fully, 2 device px in from its edges,
are the same in both frames; the 2 px rim's covered pixels are within 12/255; the reactive
pick just inside the box is the same actor in both, never a layer; the menus draw no arrow.
It writes `shadow-corners-light.png` and `shadow-corners-dark.png`, Quick Settings' four
corners at 4×, for review.

`G2_GLASS=1 G2_GLASS_STRESS=SECONDS` runs a stress instead, by hand: for that long a
stand-in window moves and tiles change under the box, every other change forwarded. Each
frame must have no black pixel; a frame whose clip misses the box must equal the last one
wherever the box covers fully (its corners show what lies beneath); every 20th covered frame
must equal a full redraw. `G2_GLASS_STRESS_STOCK=1` runs stock's effect as the control, which
draws stale frames. With `CLUTTER_PAINT=damage-region`, mutter 51 repaints the whole view
each frame (`meta-stage-impl.c`) and draws the damage on top, so no clip ever misses the box
there: that run shows the damage, not the redraw-clip rule.

Both shells capture `unlockDialog.js`'s blur (actor mode, radius 90 × scale, brightness
.65) over a grid, with a background-mode blur over it, every property of 0003 at its
default: `glass-unlock.png` against `fedora-glass-unlock.png` differs by 0 pixels.

## Accessibility

`G2_A11Y=1` (the `default`, `dark-style`, `high-contrast` and `large-text` cases, and their
`-solid` twins over the stress backdrop) runs
`a11y.js`, which opens each Apex surface in turn: the bar, the dock, a popup menu, the OSD,
a banner, Quick Settings and its Wi-Fi menu, the date menu with two notifications, the
window switcher, a polkit-shaped dialog, the shell's own power-off dialog, Spotlight with
"disk" typed and its toast, the overview and the app grid. Its targets are the visible
labels, entries and symbolic icons under the surface. Their ink is hidden while the shell
draws the surface, so the capture holds what is behind them, glass and its blur included,
with an icon's own fill put back over it. Each target's foreground colour, times its alpha
and paint opacity, is composited over every sampled pixel of its box, and the pixel at the
5th percentile counts, which drops an antialiased corner. `a11y_contrast` wants WCAG AA:
4.5:1 for text and 3:1 for a glyph (1.4.3 and 1.4.11). A disabled button's content is exempt,
and so is a target wholly outside the capture, another workspace's label. `a11y_layout`
wants, at 1.25, no text cut short (a collapsed notification's body expands, so it may),
none partly off the screen or outside its surface, and none overlapping text in the same
filled box (a notification stack's cards overlap by design). Quick Settings is measured once
more under each of the nine `accent-color` values, since a checked toggle takes its fill from
the accent. The failures left are known gaps (`A11Y_GAPS`), all in upstream's high-contrast
sheet, and they stay gaps: restyling an upstream actor there would need a stock
copy of the sheet for safe mode. A report for upstream, which is the owner's to file:

> **High contrast: checked quick toggles fall below WCAG AA.** In gnome-shell 51.0's
> high-contrast sheet, a checked quick toggle draws white text on the accent: 3.15:1 for the
> default blue (WCAG 1.4.3 wants 4.5:1), and the menu arrow beside it 2.31:1 (1.4.11 wants
> 3:1). Measured from the stage's pixels with the toggle's own colours.

## The idle desktop

ROADMAP S3c's last exit: an idle desktop shows no extra repaints. The `idle` case runs the
patched shell with every feature `layer.js` lists in `FEATURES_IN_ENABLE_ORDER`, and
`assert.sh` reads that list from the source, so a new feature is idle-tested as soon as it
joins it. `idle.js` lets the session settle first: startup over, the overview hidden, the
startup notifications dropped, the dock at rest (no transition on its box), the bar's and
the dock's glass on, no actor easing, and the pointer left at 0,0 (hot corners off). Then it
counts the stage's `after-paint` over 10 s, on the fixed clock, and expects none. It does so
four times: on the desktop, with Quick Settings open (its glass sits right under the bar's),
and both again with Reduce Transparency, which S2b's exit asks of the glass. After the
control, it opens the overview, its thumbnails drawing the wallpaper, takes the search entry's
key focus away so no cursor blinks, and counts another 10 s: no frame and no relayout either.

A failure names what repainted. Each frame's `paint-view` hands over its redraw clip, an
`MtkRegion`: the probe takes its extents by bisecting it with `intersect_rectangle`, since
gjs cannot take the region's rectangles, which its getters return by value, and names the
actors a pick finds inside it, innermost first. `queue-relayout`, which runs up the tree, is
counted on every actor, so the innermost entry is the one that asked. `assert.sh` adds the
`ui/apex/` file of each JS class and `apex-` style class among them. The control opens Quick
Settings inside a window of the same counter: it must count frames and name their damage.

## Glass under load

ADR 0014's acceptance runs on the laptop: Sysprof's frame times, `gpu_busy_percent` and the
energy rate are the laptop's, and G2 records none of them, since llvmpipe's times are the
CPU's. What G2 measures is the work, frame by frame, from `paint-view`'s redraw clip: a glass
box the clip covers fully re-blurs (patch 0003's rule e), one it only touches draws its last
result and queues another frame. `glass-load.js` runs each scenario for 5 s with the glass and
again with `reduce-transparency`, the same script:

| Scenario | Stand-in | Asserts |
|---|---|---|
| A | `load-window.js`, a GTK 4 window repainting in a new colour every 33 ms from a timer, over the dock and under Quick Settings, which is open | every change under a glass box re-blurs it in the same frame; the dock re-blurs exactly as often as the window changes, Quick Settings and the bar never; glass draws at most 1 % more frames per change than Reduce Transparency |
| B | the same window, still, moved under the dock, then under Quick Settings, then under the calendar, a step every 33 ms | the same; the bar, which it never passes under, re-blurs at most once per open or close of a bar menu (4), since its own buttons repaint there: a patch 0003 effect cannot tell its own content from its backdrop |
| C | 20 overview and app-grid toggles over the repainting window, then Spotlight over it | every change under a glass box re-blurs it in the same frame; the frame counts are reported. The overview's and the launcher's scrims join with S3a's glass |

Each scenario prints the modelled glass cost per frame: the re-blurs it saw, each costed by
`0014-blurcost.py`'s model at the box's device size and sigma. It is for the laptop run to
compare with, never asserted. A failure names the counts per surface and the first frames'
clips. The black and stale frames of ROADMAP S2b's exit are `glass.js`'s stress, on its
synthetic box: on a real surface, its own content may be black. `glass-stress` runs that
stress for `G2_GLASS_STRESS_SECONDS` (60 s; `run.sh` sets 300 s in the VM, ROADMAP S2b's five
minutes) and then scenario A for as long, every change under a glass box re-blurring it.

## Sign-off captures

Every slice ends with the owner signing off its boards, light and dark, which then become
approved goldens. `signoff.sh RPM_DIR` shoots them in one place, on what an Apex image
draws with: it first builds and installs the apex-desktop of `tests/lib/pins.sh` (its own
`make rpm`), whose vendor defaults bring the Facets wallpapers, the Apex icon theme (Colloid
app icons, Apex Symbolic, the folders and the trash) and Adwaita Sans with ss03 and JetBrains
Mono, and installs the apps its dock lists. `patched.sh` with `PATCHED_PART=signoff` then runs
`direct.sh signoff`: the `default`, `dark-style`, `indicators` and `indicators-dark` cases
with `G2_SURFACE_SCENES=1`, the first two with `G2_SIGNOFF=1`, which opens Text Editor, Calendar
(Nautilus refuses root) and Terminal (through `scopeless/systemd-run`, as G2 has no user
manager) and captures the overview and the real app switcher over them, after the
scenes that want an empty desktop. The launcher's board is its grid, captured before the
probe opens a folder. `tests/shell/shoot.sh` shoots the greeter, the lock screen, polkit's
dialog and the power-off dialog with an update staged. Each board's scene is copied to
`board-NN-SLUG-light.png` and `-dark.png`, and `signoff.json` records its title, its scene
and fixture state, the apex-gnome and apex-desktop pins, the layer's features enabled, the
scale and the monitor. These are review captures: nothing is compared, and only a scene
without a capture, or a probe whose three windows never all reached the overview, fails the
run, named. The `signoff` workflow (`workflow_dispatch` only)
uploads the set as `signoff-SHA`.

## Known gaps

`top_bar_gaps` asserts the rest of the designed top bar ([docs/DESIGN.md](https://github.com/apex-linux/apex/blob/main/docs/DESIGN.md)),
which S1a's SCSS cannot draw (the look step's report). Each names the roadmap step that builds it.
Until then its failure prints `GAP <step>: …`, counts as a known gap, and is listed at
the end of `assert.txt` and of `run.sh`'s output; it does not fail G2. Once it passes it
fails, until it moves into `top_bar` as a plain assertion.

`top_bar_today` pins each gap's side of today: what S1a measures (the table's last
column), as plain assertions within a tolerance. A change in either direction fails G2,
so a regression there shows before the roadmap step lands; the step that closes a gap
removes its pin.

| Until | Assertion | S1a measures |
|---|---|---|
| S1b (the Facets wallpaper and the light overview) | the unread-notification dot is the raw accent | `$apex_bar_fg`: over Fedora's wallpaper an accent dot is about 1.4:1 against the light bar |
| no step yet (a clock hook, or the owner accepts it) | `$apex_bar_clock_gap` between the date and the time | about 7 px with G2's 24-hour clock: one label, an EN SPACE. An en-US 12-hour clock adds a FIGURE SPACE before a one-digit hour ("Tue Sep 29" EN SPACE FIGURE SPACE "5:23 AM"): about 14 px |
| no step yet (a clock hook, or the owner accepts it) | with the dot, the clock pill is padding + text + gap + dot + padding wide | 13 px wider: upstream's invisible pad left of the text |

Not asserted here: the maximised-window trigger of the solid bar (G2 opens no window
yet; the layer tests cover it), the volume glyph (the container has no audio server), the bar
text's contrast over other wallpapers (S2b's solid fallback; over the fixture wallpaper
it is at least 4.8:1), and what the goldens judge: the Apex Symbolic glyphs (S1b), `ss03`
(S1b, fontconfig) and the light bar over the still-dark overview (S1b).

## Files

| File | Runs in | Does |
|---|---|---|
| `run.sh` | the builder VM | the runs, the bus image, the containers, then `assert.sh` and `stable.sh` |
| `direct.sh`, `guard.sh` | containers of the image | the cases and the crash-guard phases |
| `fixtures.py` | the direct cases' containers | the python-dbusmock services on the system bus |
| `clock.c` | the direct cases' shells (`LD_PRELOAD`) | the fixed wall clock |
| `smoke.sh` | CI's Fedora 45 container | `direct.sh fedora` on Fedora's gnome-shell, and the assertions that need no Apex build |
| `patched.sh` | a throwaway Fedora 45 container, by hand | the patched shell before a builder VM: rebuilds Fedora's SRPM with this checkout's recipe and `desktop/shell/`, runs `direct.sh main`, and asserts the logs and the top bar (below) |
| `maximised-window.js` | the `dock-intellihide` cases' shells (gjs, GTK 4) | one maximised window, which the probe starts and stops |
| `probe.js` | the shell (`--automation-script`) | prints `APEXG2 {…}` and, for the capture cases, `APEXG2-SCENES {…}` |
| `assert.sh`, `stable.sh`, `lib.sh` | the builder VM | the assertions |
| `png.js`, `compare.js` | gjs | PNG with GLib's zlib only, and the masked comparison |
| `glass.js`, `blur-ref.js` | the shell; gjs | the glass cases, and their CPU reference |
| `signoff.sh` | a throwaway Fedora 45 container; `.github/workflows/signoff.yml` on demand | the owner's sign-off captures (below) |
| `a11y.js` | the shell | the accessibility cases: contrast against what is drawn, and the Large Text layout |
| `backdrop.js`, `backdrops.sh` | the shell; a throwaway container | whether the pinned backdrop painted, and the Facets it pins rendered where an image has them |
| `indicators.js`, `sni-items.js` | the shell; gjs | the app-indicator part of `default`, `default-scale1` and `dark-style`, and the StatusNotifierItems it starts |
| `idle.js` | the `idle` case's shell | the settled desktop, its paints and relayouts over 10 s, and the counter's control |
| `glass-load.js`, `load-window.js` | the `glass-load` and `glass-stress` cases' shells; gjs, GTK 4 | ADR 0014's scenarios as work counts, and the client that stands in for a video; `tests/laptop` runs both on the laptop, the client with `measure=` |
| `frame.c`, `G2Frame-1.gir` | the glass cases' shells | `G2Frame.read()`, a region of the frame the shell drew |
| `selftest.sh`, `png-test.js`, `blur-ref-test.js` | CI and the host | the tests of the above |

## The patched shell without a VM

`patched.sh` checks a change to the series or the layer in minutes, before `just vm-image`:

```bash
docker run --rm --network=host -v "$PWD:/src:ro" registry.fedoraproject.org/fedora:45 \
    /src/tests/shots/patched.sh
```

It applies `spec-edit` and the series as the lane does (the mutter pin is the newest
`mutter-devel` in Fedora's repositories), so a patch that stops applying with fuzz 0 fails
the build. Then it installs the RPMs with the layer's schema fixture, runs `direct.sh main`,
and asserts each case's log, the top bar of `default`, `default-scale1` and `dark-style`
(the metrics, today's pins and the known gaps) and the layer cycles. G1, the crash guard,
the captures against Fedora's and `rpm -V` stay with G2 in the builder VM. With
`PATCHED_RPMS=DIR` it installs built RPMs instead; `PATCHED_OUT=DIR` keeps the RPMs and logs.
It also asserts the shell surfaces of the same three cases (below). With
`-e G2_SURFACE_SCENES=1`, `direct.sh` passes the variable to the shells, and the capture
cases also save a scene per surface group (`surfaces`, `quick-settings`, `switcher`,
`dialog`, `datemenu`, `appgrid`), for placing beside the boards.

## The authentication dialog

G2 has no polkit case. `tests/shell/shoot.sh`'s polkit cases capture board 13 from the
lane's RPMs: they call the shell's own polkit component's `_onInitiate()` with a stubbed
`PolkitAgent.Session`, which asks for the password (and sends pam_fprintd's prompt in
`polkit-fingerprint`) and is never answered. They are for captures and style checks only:
PAM, polkit-agent-helper-1 and polkitd's verdict never run, and polkitd only describes the
action. The real `pkexec` path is G4's.

## Not yet

- A bar-text contrast check over the fixture wallpapers.
- The metrics of the other surfaces (launcher, overview, notifications, windows, keys),
  and approved goldens.
