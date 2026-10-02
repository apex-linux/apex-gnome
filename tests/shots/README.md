# G2: the headless shell

G2 runs the gnome-shell of a built image headless, at scale 2, and asserts what it
draws and how its safety net behaves ([ARCHITECTURE §11](../../docs/ARCHITECTURE.md#11-quality-gates),
[design/SPEC.md §7.2](../../design/SPEC.md#72-g2-headless-shell-from-s1a), the ROADMAP S1a
exit). It needs the built image and rootful podman, so it runs in the builder VM, never
in GitHub's CI:

```bash
just vm-image    # builds localhost/apex:build in the builder VM
just vm-g2       # G2 on it; or: just vm-g2 IMAGE
```

In the VM, `tests/shots/run.sh [IMAGE]` does the same. It runs G2 twice (`G2_RUNS`,
default 2; `just vm-image` always runs it twice), writes each run to
`_build/g2/<UTC time>/run-N/` (`_build/g2/latest` points at the newest, and the newest 5
are kept), asserts each run and then that the second agrees with the first. Each
assertion prints one `PASS`, `FAIL` or `GAP` line (see "Known gaps"); the summary is
`assert.txt` and `stable.txt` in each run directory. `result.txt` names the image, the
number of runs, the sha256 of the lane lock the image carries, and the status. Copy one
to the host with
`tools/builder-vm/builder-vm.sh fetch apex-fedora/_build/g2/latest/run-1/assert.txt .`.

CI runs what needs no image: shellcheck of these scripts, and `selftest.sh`
(`just shots-test`), which tests the capture comparison, the reading of the token file
and the top-bar assertions.

## What one run does

| Step | Where | Asserts |
|---|---|---|
| G1's `image/checks/desktop.sh` | a container of the image | it passes on the image under test, so no text file under `/usr` or `/etc` names `APEX_SHELL_TEST_FAULT` |
| `direct.sh main` | a container of the image plus `dbus-daemon` (the image has no `dbus-run-session`); `rpm -V` shows the shell's packages unmodified | each case below: one headless shell with a fresh home, dconf and runtime directory |
| `direct.sh kernel` | the same, with `apex.safe=1` bound over `/proc/cmdline` | the kernel switch |
| `direct.sh fedora` | the same image with Fedora's own gnome-shell and gnome-shell-common of the tested NVR in place of the Apex build, downloaded from Fedora's repositories; each RPM must report `digests signatures OK` against a keyring that holds Fedora's key alone, so an unsigned RPM fails | the baseline of the captures |
| `guard.sh` | a container of the image booted with its own systemd; a test user's `systemd --user` with the image's unmodified units | the crash guard, and that neither the user manager nor the shell's unit sets `APEX_SHELL_TEST_FAULT` |
| `assert.sh` | the builder VM; `compare.js` in a container of the image | everything below |

The direct cases:

| Case | Settings | Asserts |
|---|---|---|
| `default` | `color-scheme` `'default'` | the Apex light sheet with its marker, `prefer-light`, no fault feature, the crash guard's marker created and removed; the top bar's metrics, light |
| `default-scale1` | as `default`, on a 1440x900 virtual monitor at scale 1, as the desktop VM runs | the Apex light sheet; the top bar's metrics at scale 1 |
| `dark-style` | `prefer-dark` | the Apex dark sheet; the top bar's metrics, dark; then the probe clicks Quick Settings' Dark Style toggle (its own `clicked` signal): the toggle turns off, writes `color-scheme` `'default'`, and the running shell loads the Apex light sheet |
| `stock-light`, `stock-dark` | `APEX_SHELL_SAFE=1` with `prefer-light` or `prefer-dark` | upstream's sheet of that variant from `theme/stock/`; the overview's thumbnails at upstream's maximum scale 0.05 and at the effective scale of Fedora's build; the rebuilt high-contrast sheet, which safe mode keeps, is Fedora's apart from the structure marker |
| `safe-env`, `layer-disabled`, `kernel-safe` | the three kill switches | upstream's dark sheet from `theme/stock/`, the stock colour scheme, every hook stock, the reason logged; the same sheet in all three |
| `fault-configure`, `fault-enable` | `APEX_SHELL_TEST_FAULT` | only the fault feature is off; the `witness` feature after it still enables; the rest of the layer runs, and the shell survives |
| `fault-abort` | `abort-after-enable` | SIGABRT (exit 134) with the crash guard's marker left behind |
| `fedora-light`, `fedora-dark` | Fedora's build, `prefer-light` or `prefer-dark` | no Apex module; upstream's sheet at its own path, byte for byte the one safe mode loads from `theme/stock/` |

Every case: the probe ran (so the static import graph loaded), from `startup-complete`, and no `JS ERROR`.

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
off, two fixed workspaces and a 24-hour clock. `probe.js` drops the
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
| Apex light (`default`) against `fedora-light`; Apex dark against `fedora-dark`, each scene | `panel`: the top bar's box in either capture | ROADMAP S1a: the captures equal Fedora's stock shell outside the masks; S1a restyles only the top bar |
| `stock-light` against `fedora-light`; `stock-dark` against `fedora-dark`, each scene | `clock`: the clock button's box | safe mode draws exactly Fedora's shell; the clock shows the minute each case ran in |
| each capture case of run 2 against run 1 | `clock` | the time |

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
workspace dots' gap, height and radius; the clock's unread-notification dot (the probe
posts one low-urgency notification); that the diamond is drawn (at least a quarter of
its stroke's area in capture pixels of the bar's colour, left of the dots, at the
capture's scale); the status pill's glyph gap and glyph size; on the lock screen and the
greeter (the probe adds the panel's `unlock-screen` style class), that upstream's hover
fill of the status button is centred on its pill; and with Large Text (the probe sets
`text-scaling-factor` 1.25) that the bar, the clock pill and the glyphs keep their px
sizes while the clock text grows to 1.25 × 13.5 px and stays within its pill. The probe
measures in CSS px through St itself, so the values hold whether mutter lays the stage
out in logical or physical pixels.

Because every metric follows the token file, `lib.sh`'s `tokens_are_spec` also checks
each top-bar token, in both variants, against its literal value in design/SPEC.md (§2.1,
§2.6 to §2.9, §3.4 and §7.2): a token edit that leaves SPEC fails there.

## Known gaps

`top_bar_gaps` asserts the rest of SPEC §3.4 and the top-bar row of §7.2, which S1a's
SCSS cannot draw (the look step's report). Each names the roadmap step that builds it.
Until then its failure prints `GAP <step>: …`, counts as a known gap, and is listed at
the end of `assert.txt` and of `run.sh`'s output; it does not fail G2. Once it passes it
fails, until it moves into `top_bar` as a plain assertion.

`top_bar_today` pins each gap's side of today: what S1a measures (the table's last
column), as plain assertions within a tolerance. A change in either direction fails G2,
so a regression there shows before the roadmap step lands; the step that closes a gap
removes its pin.

| Until | Assertion | S1a measures |
|---|---|---|
| S2a (patch 0010) | the active workspace dot is 22 × 7 | 25 × 7 (stock's 3.625 × at two workspaces) |
| S2a (patch 0010) | an inactive dot is 7 × 7 at .45 | 5.25 × 5.25 at .5 |
| S2a (patch 0010) | the top-left pixel reaches a reactive 4 × 4 hot-corner zone | the Activities button, 84 × 32 |
| S2a (patch 0010) | Do Not Disturb adds no glyph to the status pill | it adds `notifications-disabled-symbolic` |
| S2a (the layer) | "Desktop" at 700 follows the Activities pill while nothing has focus | no item |
| S2a (the layer) | a 32 × 24 search button named "Search…" | none |
| S2a (the layer) | with `translucent-top-bar` off the bar is `$apex_bar_solid` over a `0 1px 0 $apex_border` line | the key does not exist yet |
| S2b (patch 0003, the glass manager) | a 24 px blur at 160 % saturation behind the bar | no blur effect |
| S1b (the override's `clock-show-weekday`) | the clock starts with the weekday | it does not |
| S1b (the Aurora wallpaper and the light overview) | the unread-notification dot is the raw accent (SPEC 2.3, 3.4) | `$apex_bar_fg`: over Fedora's wallpaper an accent dot is about 1.4:1 against the light bar |
| no step yet (a clock hook, or the owner accepts it) | `$apex_bar_clock_gap` between the date and the time | about 7 px with G2's 24-hour clock: one label, an EN SPACE. The mockup's en-US 12-hour clock adds a FIGURE SPACE before a one-digit hour ("Tue Sep 29" EN SPACE FIGURE SPACE "5:23 AM"): about 14 px |
| no step yet (a clock hook, or the owner accepts it) | with the dot, the clock pill is padding + text + gap + dot + padding wide | 13 px wider: upstream's invisible pad left of the text |

Not asserted here: the maximised-window trigger of the solid bar (G2 opens no window
yet), the battery's "87%" at 12.5 px and the network, volume and battery glyphs (no
battery or network without the dbusmock fixtures), Reduce Transparency (S2b), the bar
text's contrast over other wallpapers (S2b's solid fallback; over the fixture wallpaper
it is at least 4.8:1), and what the goldens judge: the Hugeicons glyphs (S5), `ss03`
(S1b, fontconfig) and the light bar over the still-dark overview (S1b).

## Files

| File | Runs in | Does |
|---|---|---|
| `run.sh` | the builder VM | the runs, the bus image, the containers, then `assert.sh` and `stable.sh` |
| `direct.sh`, `guard.sh` | containers of the image | the cases and the crash-guard phases |
| `probe.js` | the shell (`--automation-script`) | prints `APEXG2 {…}` and, for the capture cases, `APEXG2-SCENES {…}` |
| `assert.sh`, `stable.sh`, `lib.sh` | the builder VM | the assertions |
| `png.js`, `compare.js` | gjs | PNG with GLib's zlib only, and the masked comparison |
| `selftest.sh`, `png-test.js` | CI and the host | the tests of the above |

## Not yet

- python-dbusmock fixtures (battery, Wi-Fi, keyboard) and a fixed clock (SPEC §7.2):
  until then the status pill holds what a bare container offers, and the clock is
  masked. With them: the status pill's glyphs and the percentage label.
- A bar-text contrast check over the fixture wallpapers.
- The other SPEC §7.2 rows (dock, launcher, overview, notifications, windows, keys), the
  enable and disable cycles, and approved goldens.
