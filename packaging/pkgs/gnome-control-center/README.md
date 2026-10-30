# gnome-control-center in the rebuild lane

Fedora's gnome-control-center SRPM, rebuilt with the Apex Settings inside it: the Apex
Desktop panel, the coloured sidebar tiles and the Software Updates page of the design
canvas's boards 11, 18 and 26, and the restyled Appearance and Power panels of boards
23 and 24.
[ADR 0014](https://github.com/apex-linux/apex/blob/main/docs/adr/0014-engine-level-desktop.md)
puts it in the lane; ROADMAP track C, S2c and S2d define its series. The lane,
`apex-lane`, and the formats of the files here are in
[packaging/README.md](https://github.com/apex-linux/apex-image/blob/main/packaging/README.md#the-rebuild-lane).

| File | Role |
|---|---|
| `pkg.env` | the SRPM, the hold family `gnome-control-center`, the two binary packages the image takes, and Source1 (`desktop/control-center/`, unpacked as `panels/apex/`) |
| `spec-edit` | anchored edits to Fedora's spec: `.apexN`, `License:` with GPL-3.0-or-later for the `Update1` proxy, `Source1`, and the `%prep` line that unpacks it |
| `series`, `patches/` | the hook hunks, one patch per concern |
| `check.sh` | the lane checks of this package: upstream's resource still in `/usr/bin/gnome-control-center`, every resource file of Source1 in `/org/gnome/Settings/apex`, the Apex marker, the panel's template, desktop files and icon, the "Apex Tweaks" entry, the `-filesystem` directories and `org.gnome.Settings.desktop` |

## What the build does to Fedora's package

- Fedora 45 ships gnome-control-center 51.0 (`gnome-control-center-51.0-2.fc45`, in
  `fedora`), on GTK 4.24 and libadwaita 1.10.
- `Release: %{autorelease}.apexN` gives `51.0-2.fc45.apexN`, above Fedora's build and
  below its next one.
- `install=` takes `gnome-control-center` and `gnome-control-center-filesystem`, ADR
  0014's hold family: the main package requires `-filesystem`, a noarch package of
  directories, so holding one without the other could pair a held Settings with a newer
  Fedora `-filesystem`.
- Fedora's spec has only `Source0` and no patch, so the Apex archive is `Source1`:
  `apex-control-center-<tree>.tar`, the `git archive` of `desktop/control-center/`.
  `%prep` unpacks it at the top of the tree with `tar -xkf` right after `%autosetup`,
  which gives `panels/apex/` and never replaces an upstream file. Nothing is moved or
  deleted. The series follows as `Patch1001` and up, and `%autosetup -p1` applies it with
  `patch`, at Fedora's fuzz 0.

### How a panel registers in 51.0

| Piece | Where | What an Apex panel needs |
|---|---|---|
| The panel list | `default_panels[]` in `shell/cc-panel-loader.c`: an id, its `get_type()` and an optional static init function, compiled in; no plugin API | an `extern` and a `PANEL_TYPE ("apex", …)` line |
| Its metadata | `gnome-<id>-panel.desktop` in `/usr/share/applications`, read by `cc_panel_loader_fill_model()`: name, icon, keywords and the category, which picks the sidebar section | an added `gnome-apex-panel.desktop.in` |
| The build | `panels/meson.build` runs `subdir()` for each id, each adding a static library to `panels_libs`; the executable links them | `subdir('apex')` |
| The sidebar order | `panel_order[]` in `shell/cc-panel-list.c`; an id missing from it sorts as index 0, the top; a separator shows above a row whose predecessor in the list is `"separator"` | `"apex"` and a `"separator"` at its head; 0002 (C2) reorders it |
| Opening by name | `gnome-control-center <id>`, through `CcApplication`'s command line and the same list | nothing more |

So a panel is added files plus three short hooks. The Apex panel and its pages live in
`panels/apex/`; the System panel's Software Updates row (C2) is one more hook in
`panels/system/`.

## The Apex Desktop panel

Board 11, both scroll positions: `gnome-control-center apex`, first in the sidebar, and
the launcher's "Apex Tweaks" (`io.github.apex_linux.Apex.Tweaks.desktop`) opens it.

- **The header**, a card: a 72 px tile of the current wallpaper (`picture-uri` or
  `picture-uri-dark`, following Dark Style) with the Apex diamond in the accent, "Apex
  Desktop", and "Version 45.YYYYMMDD.N · GNOME Shell 51.0 on Wayland · Fedora Linux 45":
  the booted image's `version` from `/usr/share/apex/manifest.json`, the shell's
  `ShellVersion` over D-Bus with `XDG_SESSION_TYPE`, and `NAME` and `VERSION_ID` from
  os-release. A part that cannot be read is left out.
- **The rows** are DESIGN's ["Apex Desktop panel rows"](https://github.com/apex-linux/apex/blob/main/docs/DESIGN.md#apex-desktop-panel-rows),
  each bound with `g_settings_bind`, so a change on either side shows at once:
  `AdwSwitchRow`s, and `AdwToggleGroup`s for Icon Size (`dock-icon-size`), Corner
  Radius (0, 8, 14, 20; any other `window-corner-radius` selects none) and Titlebar
  Buttons (`appmenu:minimize,maximize,close` or `appmenu:close`; another layout selects
  none). The two rows that write two keys bind the first and write the second when the
  row changes: Show Date in Clock writes `clock-show-weekday`, and Reduce Motion
  (`enable-animations`, inverted) sets a11y `reduced-motion` to `'reduce'` or resets
  it, as Accessibility does. Their handlers connect after the bindings, so opening the
  panel writes nothing.
- **Without apex-desktop's schema** the panel shows an explanation instead of the rows.
  A schema without one of the Apex keys hides that row and logs it.

## The sidebar

0002 puts each panel's icon on a 24 px tile, radius 7, white on its colour, and orders the
panels as boards 11, 18, 23 and 24 do: Apex Desktop; Wi-Fi, Network, Bluetooth; Displays,
Sound, Power; Appearance (`background`), Multitasking, Notifications, Search, Apps, then
Online Accounts, Sharing, Wellbeing; Privacy & Security, Keyboard, Mouse & Touchpad, then
Color, Printers, Wacom, Accessibility and System. The panels the boards leave out keep
their place next to their group.

The colours are `panels/apex/settings-tiles.json`, `{"<panel id>": "#rrggbb" | "accent"}`,
compiled into the resource and turned into one CSS rule per panel when Settings starts;
`accent` is the user's accent colour, and a panel the table lacks gets a slate tile. It is
the one table of Settings tile colours: the shell's Spotlight keeps a byte-identical copy,
`desktop/shell/js/ui/apex/spotlight/settings-tiles.json`, and compares the two. The selftest checks
its format (sorted keys, two-space indent, a final newline, `#rrggbb` or `accent`).

## Appearance

Board 23 is stock 51.0's Appearance panel (`background`) with its rows unchanged: a
block of `apex.css` restyles stock's own classes, and 0004 adds the board's two texts. Accent swatches are
32 px, and the chosen one gets a 2 px ring in the card colour and a 4 px one in the accent.
The style previews and wallpaper thumbnails are rounded to 10 px, thumbnails get a 1 px
border, and the active wallpaper gets a 3 px accent ring. Stock's check mark stays on the
active wallpaper as a cue that does not rely on colour; the board shows only the ring.
The active wallpaper's name sits beside the Background header and a note under the
chooser says whether it has a dark version and follows the style
(`panels/apex/cc-apex-background.c`); a wallpaper the chooser does not list shows neither.
Stock's chooser lays thumbnails out at a fixed size, so the grid holds as many as fit,
three at the window size the captures use, where the board has four.

## Power

Board 24 is stock 51.0's Power panel, its two pages and every row kept, with one group
added after Power Mode (0005): **Graphics and Display**, `panels/apex/cc-apex-power.c`.

- **The graphics card**, shown only when the machine has an NVIDIA display controller (PCI
  vendor `0x10de`, class `0x03xxxx`, found through gudev): its hwdb name, "GA107M [GeForce
  RTX 3050 Mobile]" shown as "NVIDIA GeForce RTX 3050 Mobile", and a pill with its state
  from `power/runtime_status`: Off and green while the card is suspended, On and amber
  while it draws power. The kernel sends no uevent when runtime PM changes the state, so
  the row reads the attribute every 2 s while it is on screen; reading it does not wake
  the card.
- **Lower Refresh Rate on Battery**, bound to apex-desktop's
  `lower-refresh-rate-on-battery` and hidden without that key. Its subtitle names the
  rates apex-session-agent switches between, "60 Hz on battery, 90 Hz when plugged in": the
  built-in panel's (`is-builtin`) rates of 60 Hz or more at its current resolution, from
  Mutter's `DisplayConfig.GetCurrentState`, read again on `MonitorsChanged`. Without a
  built-in panel it states the rule instead.

The group's logic is GLib-only, `cc-apex-power-state.c`, and `state-test.sh` covers it.
Stock's headings (Battery Level, General), its charging radio pair and its two pages stay
where the board draws one page with a hero card; that is option A, which keeps every
stock feature.

## The Software Updates page

System's Software Updates row opens it (0003), and so does
`gnome-control-center system software-updates`. It is board 18 on apex-updated's
`Update1` interface, on the system bus; every change goes through an `Update1` method,
and polkit asks in the daemon, never in Settings.

- **The hero**: the wallpaper tile with a badge, a title and a line for each `State`,
  and the buttons that state offers: Check Now (`Check`), Download (`Download(false)`),
  Download Anyway (`Download(true)`, while `DeferredReason` holds an update back),
  Restart Now (`Apply` with the staged digest, then `org.gnome.SessionManager.Reboot`;
  `Reboot` alone once the update is applied), Keep Current Version (calls nothing: the
  hero turns to "Update Downloaded" and the image waits), and for a health failure Go
  Back… (`Rollback(true)`) and Keep This Version (`AcknowledgeHealthFailure`). An
  available update shows its `download-size`; while downloading, the hero shows
  "264 of 412 MB · about 2 minutes left" from `Progress`, the size and the rate since
  the page saw the download start. A failed call shows the daemon's message under the
  buttons; a refusal from polkit shows nothing.
- **Board 26**: with `HealthFailure` or `LastFallback` set, the page raises an
  `AdwAlertDialog` once per digest when it shows: the failed checks
  (`HealthFailureChecks`), Keep This Version (`AcknowledgeHealthFailure`) and Go Back…
  (`Rollback(true)`) after a failed check; Show Changes (`GetChangesFor` the set-aside
  digest, listed in a second dialog) and OK (`AcknowledgeHealthFailure`, which clears
  `LastFallback`) after a fallback, whose hero says so too. These three members, and
  `Kept`, come from apex-system K4; the page reads them through a proxy without the
  compiled interface and offers each only when the daemon has it, so the page also runs
  against a daemon from before K4. apex-session-agent's notification opens this page.
- **Notes** for every family in the newest deployment's `held` list, with each of its
  `holds` records when there are some ("Settings 51.1 is held back … Not a security
  update. Held for up to 14 days, then Apex ships the stock 51.1."; the kernel pair's
  records name Linux or the NVIDIA driver by their side), for every family in `stock`,
  with the reason the daemon gives, and for every `degraded` one. `holds` is read as
  `a(sstbts)` or, from a daemon before apex-system K4, `a(sstbt)`.
- **What's New**: `GetChanges` for the staged digest, summed up as its GNOME, Linux and
  Mesa versions (then other packages), with every change in the expanded row.
- **Versions**: Booted, Staged and Rollback, each as version, short digest and build
  date, and "Kept by Apex: …" with the `pin-reason` of a deployment the daemon pinned;
  a Kept row for each deployment in `Kept`, the daemon's other pinned ones;
  Use at Next Restart… on the previous one calls `Rollback(false)`.
- **Preferences**: Automatic Downloads (`AutomaticDownloads`, set with
  `SetAutomaticDownloads`; polkit's `update.configure` is auth_admin, so the daemon asks
  each time and a refusal puts the switch back), the channel, the last check and Check
  Now.
- With no `Update1` on the bus, the page says the update service is missing.

`cc-apex-updates-state.c` holds the page's logic without GTK: each state's hero, the
dates, digests and the changes' summary. `tests/control-center/state-test.sh` tests it.

`panels/apex/io.github.apex_linux.Apex.Update1.xml` is apex-system's
`crates/apex-dbus/data/io.github.apex_linux.Apex.Update1.xml` at 4082998, copied byte for
byte;
gdbus-codegen makes the page's proxy from it, and apex-image's contracts job compares the
two. Change it there first, then copy it here.

## `desktop/control-center/`

Every file but the `Update1` copy and the JSON tile table, which cannot carry a comment, is
GPL-2.0-or-later, gnome-control-center's licence,
and sits under `panels/apex/`, the one path `source1_paths` allows;
`tests/control-center/selftest.sh` checks both, and that every patch is the owner's. The
copy keeps apex-system's bytes and licence, GPL-3.0-or-later, so the built package is
`License: GPL-2.0-or-later AND GPL-3.0-or-later AND CC0-1.0` (`spec-edit`).

| Path | What it is |
|---|---|
| `panels/apex/meson.build` | the panel's static library in `panels_libs`; `apex_shell_sources`, the Apex resource, compiled into the executable's sources by 0001; the two desktop files and the icon |
| `panels/apex/apex.gresource.xml` | the Apex resource, `/org/gnome/Settings/apex`: the panel's template and the sheet; outside the files libadwaita loads from the base path by itself |
| `panels/apex/apex.css` | the Apex sheet, with the marker `/*! apex-control-center */`: the header's tile, diamond and type |
| `panels/apex/cc-apex-panel.{c,h,blp}` | the panel: its rows and their bindings, and the missing-schema page |
| `panels/apex/cc-apex-header.{c,h}` | the header: the tile and the version line |
| `panels/apex/gnome-apex-panel.desktop.in` | the panel's name, icon, keywords and section for the sidebar and search |
| `panels/apex/io.github.apex_linux.Apex.Tweaks.desktop.in` | "Apex Tweaks" in the launcher |
| `panels/apex/icons/org.gnome.Settings-apex-symbolic.svg` | the Apex diamond, the panel's sidebar icon |
| `panels/apex/cc-apex-sidebar.{c,h}` | the sidebar's tiles from `settings-tiles.json`, and the one loader of the Apex sheets |
| `panels/apex/settings-tiles.json` | the tile colours by panel id, shared with the shell's Spotlight |
| `panels/apex/cc-apex-tile.{c,h}` | the wallpaper tile with the Apex diamond, and a badge, shared by the panel's header and the updates page |
| `panels/apex/cc-apex-updates-page.{c,h,blp}` | the Software Updates page |
| `panels/apex/cc-apex-updates-state.{c,h}` | its logic, without GTK |
| `panels/apex/cc-apex-background.{c,h}` | Appearance's wallpaper name and note (0004) |
| `panels/apex/cc-apex-power.{c,h}` | Power's Graphics and Display group (0005) |
| `panels/apex/cc-apex-power-state.{c,h}` | its logic, without GTK |
| `panels/apex/io.github.apex_linux.Apex.Update1.xml` | apex-system's interface, the one file without an SPDX line: a byte-identical copy |

## The series

| Patch | Upstream files | Changed lines | Hunks |
|---|---|---|---|
| `0001-apex-desktop` | `panels/meson.build`, `shell/meson.build`, `shell/cc-panel-loader.c`, `shell/cc-panel-list.c` | +7 | `subdir('apex')` after upstream's panels; `apex_shell_sources` added to `shell_sources`; the panel registered as `apex`; `"apex"` and a separator at the head of `panel_order[]` |
| `0002-sidebar-tiles` | `shell/cc-panel-list.c` | +8 −7 | the include; each row's icon handed to `cc_apex_sidebar_tile()`; `panel_order[]` in the design's order |
| `0003-software-updates` | `panels/system/cc-system-panel.c`, `panels/system/cc-system-panel.blp` | +6 −3 | the include; the `software-updates` subpage; the Software Updates group always shown; its row pushes the page (`navigation.push`) instead of spawning gnome-software, with a forward arrow for the external-link one |
| `0004-appearance` | `panels/background/cc-background-chooser.c` | +4 | the include; the active item's name and whether it has a dark version handed to `cc_apex_background_show()` where the chooser marks it, and cleared when it gets a new one |
| `0005-power` | `panels/power/cc-power-panel.c` | +2 | the include; `cc_apex_power_add()` after `setup_general_section()`, handed the General page and Power Mode's group |

The resource goes into the executable as sources, not as a static library in
`panels_libs`: the linker takes an archive member only when something references it,
and nothing upstream does.

Budget (ADR 0014): at most 150 changed lines in upstream files, in hook hunks only; the
added files under `panels/apex/` do not count. In use: 37 lines in 8 files.

The patches are `git format-patch` output against Fedora's `%prep` tree, with `a/` and
`b/` prefixes, applied with `-p1`. Write them with apex-image's
`just pkg-prep gnome-control-center` and `just pkg-export gnome-control-center`, as for
gnome-shell ([its README](../gnome-shell/README.md#changing-a-patch-or-rebasing)).

## Building it here

```bash
just control-center-test   # desktop/control-center's licence and paths; the patches' From: lines
just control-center-lane   # podman or docker: apex-lane's container half in fedora:45
just control-center-run    # podman or docker: the built Settings in a headless gnome-shell
```

For C, `just app-dev gnome-control-center` in apex-image rebuilds the Apex build the desktop VM runs
incrementally and runs it there ([desktop/README.md](../../../desktop/README.md#c-in-the-apps-just-app-dev)).

`tests/lib/lane.sh gnome-control-center` builds `apex-lane` from a pinned apex-image commit and
runs its container half, `apex-lane in-container build gnome-control-center`, as the
builder VM does: the SRPM's signature, `spec-edit`, the series at fuzz 0, the exact-tree
check, `rpmbuild -ba` with Fedora's `%check`, the lane checks and `check.sh`. It leaves
out what the VM adds, the signing and the store. The RPMs and logs land in
`_build/gnome-control-center/out/`. CI runs it on every push.

`tests/control-center/run.sh` installs those RPMs in a fedora:45 container and runs
gnome-shell headless at scale 2 for the user `apex`, with apex-desktop's schema from
`tests/layer/fixtures/`, a `manifest.json`, two flat test wallpapers, G2's `fixtures.py`
on the system bus and its `clock.c` holding the wall clock. Its automation script,
`probe.js`, opens `gnome-control-center apex` at board 11's window size and captures it
at the top and scrolled to the end, light and dark. `bindings.py` then checks every row
through AT-SPI, both ways: each key written with GSettings shows on its row, and each
switch or toggle the row offers writes its key (and the second key of the two-key rows).
A third run without the schema checks the explanation. CI runs it after the lane and
keeps the captures as the `control-center-shots` artifact.

A second part of the run starts `update1.py`, a stand-in for apex-updated, on the system
bus, and opens `gnome-control-center system software-updates` on its scenarios: board
18's "ready" state (captured light and dark, at the top and scrolled), up to date, an
update available, a download under way, a health failure and a fallback (board 26's
dialog in each), and no service at all. `updates.py` checks each
state's texts through AT-SPI, that board 26's dialog shows, and presses each button and
the Automatic Downloads switch: `update1.py`'s log must show the method call each makes,
with its arguments, and the switch must go back when `update1.py` refuses it as polkit
would.

In these captures the sidebar has no separator under Apex Desktop: the fixtures offer no
Wi-Fi device, so the Wi-Fi row, the one after the separator in `panel_order[]`, is not
there, and upstream draws a separator only above the row that follows one in the list.
On the laptop the Wi-Fi row is there and the separator shows.
