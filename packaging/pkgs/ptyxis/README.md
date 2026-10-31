# Ptyxis in the rebuild lane

Fedora's ptyxis SRPM, rebuilt with the Apex terminal inside it: the sessions sidebar and
split panes of the design canvas's boards 32 and 33. It is the lane's second package
after gnome-shell, an owner decision of 2026-10-24 under
[ADR 0014](https://github.com/apex-linux/apex/blob/main/docs/adr/0014-engine-level-desktop.md)'s
escalation rule. The lane, `apex-lane`, and the formats of the files here are in
[packaging/README.md](https://github.com/apex-linux/apex-image/blob/main/packaging/README.md#the-rebuild-lane).

| File | Role |
|---|---|
| `pkg.env` | the SRPM, the hold family `ptyxis`, the one binary package the image takes, and Source1 (`desktop/ptyxis/`, unpacked as `src/apex/`) |
| `spec-edit` | anchored edits to Fedora's spec: `.apexN`, `Source100`, and the `%prep` line that unpacks it |
| `series`, `patches/` | the hook hunks, one patch per concern |
| `check.sh` | the lane checks of this package: upstream's resource still in `/usr/bin/ptyxis`, every resource file of Source1 in `/org/gnome/Ptyxis/apex`, the Apex marker and the sidebar's sheet, and Fedora's gschema override |

## What the build does to Fedora's package

- Fedora 45 ships Ptyxis 50.1 (`ptyxis-50.1-6.fc45`), on VTE 0.84, GTK 4.24 and
  libadwaita 1.10. It has tabs, the tab overview and a per-tab monitor of the foreground
  process; it has no split panes and no sidebar.
- `Release: %{autorelease}.apexN` gives `50.1-6.fc45.apexN`, above Fedora's build and
  below its next one.
- Fedora's own `Source1` is its gschema override, so the Apex archive is `Source100`:
  `apex-ptyxis-<tree>.tar`, the `git archive` of `desktop/ptyxis/`. `%prep` unpacks it
  at the top of the tree with `tar -xkf`, which gives `src/apex/` and never replaces an
  upstream file. Nothing is moved or deleted.
- Fedora's spec has no patch of its own; the series follows as `Patch1001` and up, and
  `%autosetup -p1` applies it with `patch`, at Fedora's fuzz 0.
- Checked 2026-10-30 against GNOME 51.1 (FEDORA-2026-2812a1754d): no ptyxis update is
  pending for F45. The series applies at fuzz 0 to ptyxis-50.1-6.fc45 and the lane
  builds it with the 51.1 update in the buildroot.

## `desktop/ptyxis/`

Every file is GPL-3.0-or-later, Ptyxis's licence, and sits under `src/apex/`, the one
path `source1_paths` allows; `tests/ptyxis/selftest.sh` checks both.

| Path | What it is |
|---|---|
| `src/apex/meson.build` | adds the Apex sources and resource to `ptyxis_sources` |
| `src/apex/apex.gresource.xml` | the Apex resource, `/org/gnome/Ptyxis/apex`; outside the resource base path, so libadwaita loads nothing from it by itself |
| `src/apex/apex.css` | the sheet: board 32's colours as variables on `window.apex`, dark ones on `window.apex.apex-dark` |
| `src/apex/apex-window.c` | `apex_window_attach()`: an `AdwOverlaySplitView` with the sidebar beside the window's content, the header bar restyled (session title, path and tag; Find; the session menu), the sheet loaded, and `apex-dark` following `AdwStyleManager:dark`. `APEX_PTYXIS_STOCK=1` keeps the stock window |
| `src/apex/apex-sidebar.c` | the "Terminal" header (New Session, the main menu), the sessions grouped by where they run, the group headers with "N needs you", and the footer counts |
| `src/apex/apex-session.c` | one session per tab: it feeds the status logic from the terminal's precmd, preexec and postexec signals, the bell, the agent's foreground command line and leader kind, the container termprops, OSC 7 and OSC 9;4 |
| `src/apex/apex-session-state.c` | the status logic, without GTK: idle, running, done, failed, needs you; the subtitle; the relative time; the ssh host |
| `src/apex/apex-panes.c` | board 33's splits: `ApexPanes` wraps the tab view in a `GtkPaned`; Split Right and Split Down (header toggles, Ctrl+Alt+R and Ctrl+Alt+D, `apex.split-right`/`-down`) give the selected session a second `PtyxisTab` beside it, in its working directory and container; each pane gets a 34 px header (its running command or "Shell", path, tag, the needs-you glyph, Close Pane on the second); the unfocused pane is dimmed (.7 header, .62 body); a session remembers its focused pane, and focusing a pane clears its "needs you". A session's row shows the stronger status of its two panes |
| `src/apex/apex-palette.c` | `apex_profile_follow_palette_files()`: a profile notifies `palette` when the palette list reloads a file with its palette id, so open terminals and the window dressing take a rewritten user palette (apex-session-agent's `apex.palette`) |
| `src/apex/apex-session-row.c`, `apex-glyph.c` | a row (title, subtitle, time, glyph, the 2 px progress bar) and the Apex Symbolic glyphs drawn from their 16 px paths |

### What a session shows

| Status | From | Subtitle |
|---|---|---|
| running | `vte.shell.preexec` | `<command> · running` |
| done, failed | `vte.shell.postexec=N` then `vte.shell.precmd`, after a preexec | `<command> · done`, `<command> · exit N` |
| needs you | the bell while the session is not the focused tab of the active window; it holds until the session is focused | `<command> · needs you` |
| idle | a new session, or a remote one (ssh, mosh, telnet in the foreground): its prompts never reach this side | the last command, or the shell |

`<command>` is the foreground command line the agent reports, its program shown by name.
Groups: "This computer"; a container from the `vte.container.name` and `.runtime`
termprops, or the tab's own container; a remote host parsed from the ssh command line.
The header tag is the running program, `ssh` for a remote session, or the user's shell.

Two limits of Fedora 45, raised with apex-desktop:

- VTE 0.84 hands an application no desktop notification (OSC 777, 9 or 99): only the
  bell marks a session "needs you".
- Fedora's `PROMPT_COMMAND` is an array whose first entries reset `$?`, and vte.sh's
  `__vte_precmd` reads `$?` after a `local`, so bash always reports exit 0, and zsh
  sends no preexec. Until the prompt snippet reports the status first, no session
  reads "failed". `tests/ptyxis/shoot.sh`'s `.bashrc` does what that snippet needs to.

## The series

| Patch | Upstream files | Changed lines | Hunks |
|---|---|---|---|
| `0001-build` | `src/meson.build` | +1 | `subdir('apex')` after upstream's resources |
| `0002-sidebar` | `src/ptyxis-window.c` | +5 −1 | the include; `apex_window_attach()` at the end of `ptyxis_window_init()`; the tab bar hidden while the sidebar shows |
| `0003-palette-reload` | `src/ptyxis-profile.c` | +4 | the include; `apex_profile_follow_palette_files()` at the end of `ptyxis_profile_constructed()` |
| `0004-panes` | `src/ptyxis-window.c`, `src/ptyxis-tab.c` | +8 | `ptyxis_window_get_active_tab()` returns the focused second pane; a second pane whose process exits with the close action closes itself (`apex_pane_exited()`) |

Budget (ADR 0014, as amended for Ptyxis): at most 400 changed lines in upstream files,
in hook hunks only; the added files under `src/apex/` do not count. In use: 19 lines in
4 files.

The patches are `git format-patch` output against Fedora's `%prep` tree, with `a/` and
`b/` prefixes, applied with `-p1`. Write them with apex-image's `just pkg-prep ptyxis`
and `just pkg-export ptyxis`, as for gnome-shell
([its README](../gnome-shell/README.md#changing-a-patch-or-rebasing)).

## Building it here

```bash
just ptyxis-test     # desktop/ptyxis's licence and paths; the status logic's unit test
just ptyxis-lane     # podman or docker: apex-lane's container half in fedora:45
just ptyxis-shots    # the built RPM in a headless gnome-shell, light and dark
just ptyxis-palette  # the built RPM: a palette rewritten, and the accent's caret, under an open terminal
just ptyxis-panes    # the built RPM: board 33's panes split, focused, closed, each with its status
```

For C, `just app-dev ptyxis` in apex-image rebuilds the Apex build the desktop VM runs
incrementally and runs it there ([desktop/README.md](../../../desktop/README.md#c-in-the-apps-just-app-dev)).

`tests/lib/lane.sh ptyxis` builds `apex-lane` from a pinned apex-image commit and runs its
container half, `apex-lane in-container build ptyxis`, as the builder VM does: the
SRPM's signature, `spec-edit`, the series at fuzz 0, the exact-tree check,
`rpmbuild -ba` with Fedora's `%check`, the lane checks and `check.sh`. It leaves out
what the VM adds, the signing and the store. The RPMs and logs land in
`_build/ptyxis/out/`. CI runs it on every push.

`tests/ptyxis/shoot.sh` installs that RPM in a fedora:45 container and runs gnome-shell
headless at scale 2 for the user `apex`, with apex-desktop's fonts and profile values,
G2's `fixtures.py` on the system bus and its `clock.c` holding the wall clock, as
`tests/shots/direct.sh` runs a case (`tests/lib/headless.sh`, shared with `palette-test.sh` and the libadwaita test).
Its automation script, `probe.js`, opens board 32's five sessions with `ptyxis --tab`,
types each command with a virtual keyboard into bash with vte.sh, selects apex-image
and captures the window (`light`, `dark`). The `split` scene (`split-light`,
`split-dark`, board 33) splits apex-gnome to the right with Ctrl+Alt+R right after
`claude` starts, runs `git status --short` in the second pane, and captures apex-gnome
once the other sessions are open: its first pane rang while unfocused. `fixture.c`,
installed as `claude`, `just`, `cargo`, `rpmbuild`, `ssh` and `git`, prints what `sessions.sh` wrote for that program and then waits, exits 0 or
1, or rings the bell, so every status comes from the real shell integration. CI runs
it after the lane and keeps the captures as the `ptyxis-shots` artifact.

`tests/ptyxis/contrast-test.sh` checks boards 32 and 33's contrast in those captures. With
`APEX_PTYXIS_TARGETS=1`, as CI sets it, `probe.js` runs `contrast-atspi.py` once each
capture is taken: over AT-SPI it lists the sidebar's labels and status glyphs (in a row, the
selected row, a group heading, the footer), the content header's labels, each pane header's,
and each pane's terminal, the unfocused pane's marked dimmed. GTK's extents leave out each
ancestor's padding and margin, so `contrast.py` moves each container's boxes by the one offset
that holds the most strokes. It takes a target's ground as the colour most of its box is and its ink
as its strongest strokes as drawn, so a translucent ink, the .62 dim or the unfocused pane's .7
and .62 are measured as they look. Text wants 4.5:1 and a glyph 3:1 (WCAG 1.4.3, 1.4.11),
and the footer's needs-you and running glyphs CIELAB L* 10 apart (light 42.6 and 54.9, dark
74.8 and 54.9), so they differ in lightness and not hue alone. A shortfall is a known gap
at today's ratio, pending the owner: a lower ratio fails, and so does one that reaches its
threshold, so the fix also removes the pin. The unfocused pane's output passes (4.73:1 light,
7.24:1 dark). The gaps:

| Capture | Target | Today |
|---|---|---|
| light, split-light | the selected row's dim program and time, on its `--apex-selected` fill | 4.26:1 |
| light, dark | the selected row's running glyph, the accent on that fill | 2.81:1, 2.70:1 |
| light, split-light | a group's `toolbox` and `ssh` tags, dim on `--apex-btn` | 4.26:1 |
| light, split-light | the content header's and the focused pane header's tag | 4.39:1 |
| split-light, split-dark | the unfocused pane header's path, `--apex-dim` at .7 | 2.68:1, 3.96:1 |
| split-light, split-dark | the unfocused pane header's tag | 2.53:1, 3.53:1 |

The four scenes are taken again with `org.gnome.desktop.a11y.interface high-contrast` on
(`hc-light`, `hc-dark`, `hc-split-light`, `hc-split-dark`), for this test alone: libadwaita
switches (14,000 to 25,000 pixels change per capture, its borders and outlines), but
`apex.css` keeps its own colours, so the same targets fall short there and are pinned the same
way, as the owner's item 10b. One pair moves, in light: libadwaita's dimming of the unfocused pane's
header greys its path and tag.

| Capture | Target | Today |
|---|---|---|
| hc-light, hc-split-light | the selected row's dim program and time | 4.26:1 |
| hc-light, hc-dark | the selected row's running glyph | 2.81:1, 2.70:1 |
| hc-light, hc-split-light | a group's `toolbox` and `ssh` tags | 4.26:1 |
| hc-light, hc-split-light | the content header's and the focused pane header's tag | 4.39:1 |
| hc-split-light, hc-split-dark | the unfocused pane header's path | 3.07:1, 3.96:1 |
| hc-split-light, hc-split-dark | the unfocused pane header's tag | 2.95:1, 3.53:1 |

`contrast.py --selftest` measures a drawn label in the foreground and again in its row's
fill colour, and the test fails unless its checks catch every session name in its row's
fill. CI runs it after the captures.

`tests/ptyxis/layout-test.sh` checks boards 32 and 33's layout in the same captures and in two
more, `large` and `split-large`, taken in light with GNOME's Large Text
(`org.gnome.desktop.interface text-scaling-factor` 1.25). `contrast-atspi.py` also records
each label's laid-out text over AT-SPI's text extents, and which row and slot (title, subtitle,
time) it fills. `layout.py` fails a label whose text runs to its box's right edge, as Pango's
ellipsized text does, two labels of one row or header over each other, and a label outside the
window. A row's subtitle may end in an ellipsis: the design cuts it (the rpmbuild row's does).
Nothing is cut, overlapped or outside the window in any of the six. `apex.css` sizes its text in
pt, which GTK scales with the setting, where px stays put: under Large Text the sidebar widens
(176 px to 244 px, as libadwaita sizes it in sp) and a title's text grows from 16 px to 21 px. At
1.0 each pt size is its old px size exactly (×0.75), and the captures are byte for byte the same.
The test fails unless the titles grow by 1.15x, and unless its checks catch a session's title cut
short. CI runs it after `contrast-test.sh`.

`tests/ptyxis/palette-test.sh` runs the same headless shell. Its automation script,
`palette-probe.js`, opens a terminal on a user palette with a red background, rewrites
the file with a green one, and samples the terminal's pixels; the test fails unless the
terminal is green within 1 s. On Fedora's own ptyxis it stays red. It then starts
apex-session-agent, built by `tests/s2c/agent.sh`, with the accent blue, finds the
terminal's caret in the accent (Ptyxis's `cursor-blink-mode` off), turns the accent
green, and fails unless the caret is green within 1 s. CI runs it after the captures.

`tests/ptyxis/panes-test.sh` runs the same headless shell on one apex-gnome session,
with `fixture.c` and `sessions.sh` as `shoot.sh` uses them. Its automation script,
`panes-probe.js`, reads Ptyxis over AT-SPI and drives it with a virtual keyboard and
pointer. It splits with the header's Split Right and Split Down toggles and with
Ctrl+Alt+R and Ctrl+Alt+D. It focuses each pane by a click and measures the other's
dimming against DESIGN's .7 header and .62 body. It runs `cargo` and `claude` in the
second pane and `rpmbuild` and `just` in the first, so each header shows its own
command, OSC 9;4 progress, exit status and bell. The bell's needs-you clears on focus,
and the session row keeps the stronger status. Close Pane on the second pane's header
then unsplits. A `true` typed first, which ends within one VTE batch, must leave the
session done. CI runs it after the palette test.

## S6 (Fedora 46)

Checked 2026-10-30 against rawhide, the base of apex-image's `next` lane
(`image/fedora/46.env`, `REPOS_BASE`). Rawhide has not rebuilt Ptyxis or VTE yet:

| Package | Fedora 45 | Rawhide (46) |
|---|---|---|
| ptyxis | 50.1-6.fc45 | 50.1-6.fc45, F45's build signed with F46's key |
| vte291-gtk4 | 0.84.1-1.fc45 | 0.84.1-1.fc45 |
| libadwaita | 1.10.0-2.fc45 | 1.10.0-3.fc46 |
| gtk4, glib2 | F45's | 4.24.1-1.fc46, 2.90.1-1.fc46 |
| gnome-shell, mutter | 51.1 | 51.1-1.fc46, 51.1-2.fc46 |

- **The lane:** `tests/lib/lane.sh ptyxis` in that container (`APEX_FEDORA=46`)
  downloads and verifies the SRPM, then stops: "stock release 6.fc45 does not end in
  the container's %dist .fc46". apex-lane builds only a stock release of the
  container's own Fedora, so the `next` lane builds Ptyxis once Fedora rebuilds it for
  46 (the mass rebuild, or Ptyxis 52). Whether it should also take an inherited build is
  apex-image's call.
- **The series, built by hand there:** the F45 lane's Apex SRPM
  (`ptyxis-50.1-6.fc45.apex1.src.rpm`), rebuilt with `rpmbuild --rebuild` in the same
  container, applies its four patches at fuzz 0. `src/apex/` compiles with no warning
  against rawhide's libadwaita, GTK and GLib; the build's one warning, an unused `self`
  in `ptyxis-window.c` when `g_assert` compiles out, is upstream's and F45's too.
  Fedora's `%check` passes.
- **The tests**, on that build in that container: `status-test.sh` 18 of 18;
  `palette-test.sh` takes the rewritten palette in 57 ms and the accent's caret in
  52 ms (apex-session-agent 70fa599); `panes-test.sh` passes all 23 checks, its
  dimming included.

Nothing needed fixing for 46. Left for S6:
- the first real F46 Ptyxis and VTE: re-run this, then rebase the series. Ptyxis 52's
  `ptyxis-window.c` and `ptyxis-tab.c` are where the hunks' contexts can move;
- apex-session reads a batch of shell marks in VTE's termprop id order
  (`VTE_PROPERTY_ID_SHELL_PRECMD` 6, `PREEXEC` 7, `POSTEXEC` 8): a VTE that renumbers
  them, or emits them apart, is checked by `status-test.sh` and the panes test's `true`;
- the lane's stop on an inherited build, above, if 46 branches before Fedora rebuilds
  Ptyxis.
