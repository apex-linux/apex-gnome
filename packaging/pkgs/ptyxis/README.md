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
just ptyxis-palette  # the built RPM: a palette rewritten under an open terminal
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

`tests/ptyxis/palette-test.sh` runs the same headless shell. Its automation script,
`palette-probe.js`, opens a terminal on a user palette with a red background, rewrites
the file with a green one, and samples the terminal's pixels; the test fails unless the
terminal is green within 1 s. On Fedora's own ptyxis it stays red. CI runs it after the
captures.
