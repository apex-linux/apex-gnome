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
| `stock-light`, `stock-dark` | `APEX_SHELL_SAFE=1` with `prefer-light` or `prefer-dark` | upstream's sheet of that variant from `theme/stock/`; the overview's thumbnails at upstream's maximum scale 0.05 and at the effective scale of Fedora's build; the rebuilt high-contrast sheet, which safe mode keeps, is Fedora's apart from the structure marker; no Super+Space binding |
| `safe-env`, `layer-disabled`, `kernel-safe` | the three kill switches | upstream's dark sheet from `theme/stock/`, the stock colour scheme, every hook stock, no Super+Space binding, the reason logged; the same sheet in all three; `safe-env`: no search hint |
| `layer-cycles` | the capture settings; the probe sets `layer-enabled` false, then true, three times | while off: upstream's dark sheet from `theme/stock/`, the stock colour scheme, every hook stock, no Super+Space binding; while on: the Apex light sheet, `prefer-light` and Super+Space; each time it is on the stage holds the same actors, type by type, as at startup, and each time it is off the same as the first time (the first count waits out main.js's 20 s timeout for deferred work, which fills the overview's hidden dash; an `St.Icon` counts, not the texture child St gives it once it is first styled, which a dash hidden since startup decides); the layer logs each switch |
| `motion` | the capture settings with `enable-animations` true; the probe lifts the inhibit `main.js` puts on animations without hardware-accelerated rendering, starts `window.js`, a plain GTK 4 window, maximises and restores it once (mutter gives a first size change a 0 × 0 old frame, which stock never animates), maximises it and opens the overview, then sets `enable-animations` false, does both again and plays Locate Pointer | DESIGN's motion (ROADMAP S3c): the window actor's size-change transition and the overview's state transition are `CUBIC_BEZIER` with the control points (.2, .8) and (.2, 1), over 300 and 200 ms; with animations off, neither creates a transition, while Locate Pointer's ripple (`animationRequired`, an a11y aid) still takes stock's 830 ms |
| `fault-configure`, `fault-enable` | `APEX_SHELL_TEST_FAULT` | only the fault feature is off; the `witness` feature after it still enables; the rest of the layer runs, Super+Space included, and the shell survives |
| `fault-abort` | `abort-after-enable` | SIGABRT (exit 134) with the crash guard's marker left behind |
| `fedora-light`, `fedora-dark` | Fedora's build, `prefer-light` or `prefer-dark` | no Apex module; upstream's sheet at its own path, byte for byte the one safe mode loads from `theme/stock/` |
| `glass`, `fedora-glass` | the capture settings, `G2_GLASS=1` | patch 0003's glass in the frames the shell drew; the stock unlock blur captured in both shells (see "Glass") |

Every case: the probe ran (so the static import graph loaded), from `startup-complete`, and no `JS ERROR`;
the wall clock stands at the fixed time and the top bar's clock shows it (`Mon Sep 28`, EN SPACE, `09:41`).

## Fixtures and the clock

Before the first case, `direct.sh` lets root own and call the fixtures' names on the
container's system bus (`/etc/dbus-1/system-local.conf`) and runs `fixtures.py`, which
starts python-dbusmock's `upower`, `networkmanager` and `bluez5` templates there, and
(`G2_POWER_PROFILES=1`) `upower_power_profiles_daemon`:

| Service | Fixture | The shell shows |
|---|---|---|
| UPower | a battery at 87 %, discharging (the display device) | `battery-level-80-symbolic` and, with `show-battery-percentage`, "87%" |
| NetworkManager | the primary connection: Wi-Fi "Apex-5G" at signal 90, connected globally, with "Apex-2.4G" (72) and the open "Library Guest" (48) in range, each with WPA2's ciphers or none, as libnm needs to list a network | `network-wireless-signal-excellent-symbolic`, and three networks in the Wi-Fi menu |
| BlueZ | the Bluetooth keyboard "Keychron K3", paired and connected | no glyph: the status pill shows network, volume and battery only (the `panel` feature) |
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
as nothing has focus; the search button just before the status pill, a
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
hidden and its workspaces laid out above the dock. The safe-mode cases have no dock, and the Apex captures mask it, as they mask the
bar, against Fedora's, whose desktop has none.

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
shadow, inset and gaps, the title and text, the entry at rest and focused, and both buttons; the
end-session width comes from a stand-in `.end-session-dialog` box.

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
88 px icons. G2 opens no windows, so the `window-title-visible` hook's answer stands in for
a title shown without hover.

`quick_settings_layer` checks the `quick-settings` layer feature in the same cases, and
stock in the stock cases. The probe reads the grid's toggles in order (the VPN toggle by
its class: it has no title without a VPN connection), Power Mode, the status pill and Do
Not Disturb's subtitle, then clicks Power Mode twice: VPN right after Airplane Mode, Power
Mode lit through `apex-lit` with `checked` stock, the power-profile indicator out of the
pill, "Off" under a toggle without a subtitle of its own, and the clicks switching to the
last profile and back, still lit. Stock keeps VPN before Airplane Mode and nothing lit.

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
headers in board order; the rows, the selected row's accent tint, verb and Enter chip; the
calculator's result in tabular figures with Calculator as the first application; that an
empty query shows only the field, and the row of a query with no results; and, after Enter on the result, that Spotlight closed and the toast's size, tint,
inset, check circle, text and distance from the bottom edge.

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
| a tile changes | the first frame's redraw clip leaves the box out and the effect redraws it on the next; that frame is `blur-ref.js`'s reference per channel within 4/255 inside, 12/255 in the band ds/2 px wide along the edges (ds the effect's own downscale) and 1/255 on average over the box. The first run fixed these (ROADMAP S2b): at ds 16 the edge band is the low-resolution blur's own clamping and upsampling, the interior's 4 is 8-bit intermediates times the saturation; llvmpipe is the reference renderer |
| a tile changes and the box's redraw is queued, as the glass manager forwards damage | the same frame is the box a full redraw draws, pixel for pixel |
| a tile changes, nothing forwarded | the frame draws the last result, pixel for pixel, and the next one is the full redraw's |
| the same with `fine` off | stock's effect in that frame differs from the full redraw and misses the tolerances above: the stale sampling the redraw-clip rule prevents, so the case can see it |

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
| `probe.js` | the shell (`--automation-script`) | prints `APEXG2 {…}` and, for the capture cases, `APEXG2-SCENES {…}` |
| `assert.sh`, `stable.sh`, `lib.sh` | the builder VM | the assertions |
| `png.js`, `compare.js` | gjs | PNG with GLib's zlib only, and the masked comparison |
| `glass.js`, `blur-ref.js` | the shell; gjs | the glass cases, and their CPU reference |
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

## Not yet

- A bar-text contrast check over the fixture wallpapers.
- The metrics of the other surfaces (launcher, overview, notifications, windows, keys),
  the dock's intellihide and edge reveal, and approved goldens.
