# GNOME Builder (Apex Code) in the rebuild lane

Fedora's gnome-builder SRPM, rebuilt as Apex Code: track E of the
[ROADMAP](https://github.com/apex-linux/apex/blob/main/docs/ROADMAP.md), after
[ADR 0017](https://github.com/apex-linux/apex/blob/main/docs/adr/0017-apex-code-on-builder.md).
E1 gave it the name, toolbox as the default runtime, and the fixes the
[E0 spike](https://github.com/apex-linux/apex/blob/main/docs/reviews/2026-11-03-e0-apex-code.md)
found; E2 adds the typing-stall fix (patch 0005). The lane, `apex-lane`, and the formats of the files here are in
[packaging/README.md](https://github.com/apex-linux/apex-image/blob/main/packaging/README.md#the-rebuild-lane).

| File | Role |
|---|---|
| `pkg.env` | the SRPM, the hold family `gnome-builder`, the one binary package the image takes, and Source1 (`desktop/gnome-builder/`, unpacked as `src/plugins/apex/`) |
| `spec-edit` | anchored edits to Fedora's spec: `.apexN`, `Source1`, the `%prep` line that unpacks it, and the `apex-builder` catalogue in the main package's list |
| `series`, `patches/` | the hook hunks, one patch per concern, and 0005, a fix to propose upstream |
| `check.sh` | the lane checks of this package: upstream's podman plugin still in `/usr/bin/gnome-builder`, the Apex Code plugin's resource (`/plugins/apex/apex.plugin`, the marker), the desktop file named Apex Code with no translated Name, and the vi `apex-builder.mo` |

## What the build does to Fedora's package

- Fedora 45 ships GNOME Builder 50.0 (`gnome-builder-50.0-5.fc45`), on GTK 4.24,
  libadwaita 1.10, libdex and jsonrpc-glib, with one patch of its own
  (`startup-crash.patch`, unnumbered).
- `Release: %{autorelease}.apexN` gives `50.0-5.fc45.apexN`, above Fedora's build and
  below its next one.
- Fedora's spec has only `Source0`, so the Apex archive is `Source1`:
  `apex-builder-<tree>.tar`, the `git archive` of `desktop/gnome-builder/`. `%prep`
  unpacks it after `%autosetup` with `tar -xkf`, which gives `src/plugins/apex/` and never
  replaces an upstream file. The series follows Fedora's patch as `Patch1001` and up, and
  `%autosetup -p1` applies both at fuzz 0; no patch touches `src/plugins/apex/`.
- `%find_lang apex-builder` adds Apex's catalogue to the main package's list.
- The app id stays `org.gnome.Builder`: the desktop file, the D-Bus service, the
  metainfo, the icon and the settings keep their names, so a user's settings and recent
  projects carry over from Fedora's Builder.

## `desktop/gnome-builder/`

Every file is GPL-3.0-or-later, GNOME Builder's licence, and sits under
`src/plugins/apex/`, the one path `source1_paths` allows; `tests/builder/selftest.sh`
checks both.

| Path | What it is |
|---|---|
| `meson.build`, `apex.gresource.xml`, `apex.plugin`, `apex-plugin.c` | the built-in plugin `apex` (Builder links its plugins into the executable): it registers one workbench addin, and depends on `podman` |
| `gbp-apex-workbench-addin.c` | toolbox by default (below), and the notifications for a missing toolbox or a project outside it |
| `gbp-apex-a11y-addins.c` | E0's AT-SPI gaps: the editor named for its file, the icon-only menu buttons, and (E2) the diagnostics button, the tab lists, the progress bar, the project tree and its filter (below) |
| `gbp-apex-sidebar.c`, `style.css` | E2's UI: boards 40 to 42's sidebar view switcher over the start frame, the boards' colours (below) |
| `apex-brand.h` | the name: `apex_code_name()`, `apex_code_title()`, `apex_code_preferences_title()` |
| `apex-toolbox.h` | `apex_podman_container_shares_path()`: whether a container's mounts (from `podman ps --format=json`) hold a path; `apex_podman_bridge_argv()` (E2), the `apex-toolbox-exec` command line patch 0006 runs for a toolbox |
| `apex-toolbox-exec.c`, `apex-toolbox-bridge.c`, `apex-toolbox-bridge.h` | E2: the toolbox bridge's host client and the one bridge per toolbox, installed in `/usr/libexec` (below) |
| `apex-i18n.h`, `po/` | Apex's own gettext domain, `apex-builder`, with `vi.po`; `lint/i18n.sh` holds the template and `vi.po` to the sources |

The three headers are header-only on purpose: libide's hook hunks include them, and
libide's own test programs link libide without the plugins, so a function the hunks call
cannot live in the plugin.

### Toolbox by default

ADR 0017: on bootc, builds and language servers run in a toolbox, never on the host. When
a project loads, the addin lists the toolbox containers (`podman ps --all --no-trunc
--filter label=com.github.containers.toolbox`) and takes the one named
`fedora-toolbox-45`, or else the first from `registry.fedoraproject.org/fedora-toolbox:45`.

- A project whose configuration is Builder's unsaved fallback, "Default" on the host,
  moves to that toolbox (`podman:<id>`), still unsaved: no `.buildconfig` is written into
  the project, and a configuration the user saved keeps its runtime. The move waits until
  the podman provider has listed the runtime, because preparing a configuration for a
  newly found runtime sets its install prefix, which would otherwise mark it changed and
  write `.buildconfig` behind the move. The language servers then start in the toolbox,
  as `ide_lsp_service_create_launcher()` tries the build pipeline's runtime first.
- With no such toolbox, a notification offers "Create Toolbox": `toolbox create` from
  `fedora-toolbox:45`, then `rust-analyzer cargo rust python3-lsp-server python3-pyflakes
  nodejs-npm` from Fedora and `typescript-language-server typescript` from npm (Fedora 45
  packages no typescript-language-server). About 1.5 min here. The podman provider lists
  containers only when a project loads, so once the setup is done the plugin lists the
  toolbox again and adds its runtime to that provider (E2); the move above then runs, and
  the servers restart in the toolbox with no reopen. The button has an icon and is also the
  notification's default action, since the omnibar shows only icon buttons, and only on a
  notification with a default action. Builder's host launcher clears the environment, so
  the plugin sets `SHELL` (toolbox fails without it), `XDG_RUNTIME_DIR` (rootless podman
  needs it) and the session bus. The command is resumable: `podman container exists` skips
  `toolbox create` for a toolbox whose setup stopped halfway. When the project loads with
  the toolbox, the plugin checks its three servers (`command -v` in the toolbox), and a
  missing one brings "Toolbox Setup Incomplete" with a Finish Setup button; each part of
  the setup installs only what is missing (`rpm -q`, `command -v`), so that is quick. A toolbox the
  image or the first login creates is used as is.
- A project outside the folders the toolbox mounts (outside `$HOME`, `/mnt`, `/media`,
  `/run/media`) gets a notification saying so; patch 0004 keeps its servers from starting.

### AT-SPI names

E0 found the editor's text and eight buttons and toggle buttons without a name (four menu
buttons, each a button holding a toggle button), and the Run button's dropdown and main
button both named "More Options". Two addins name them, with no hunk in upstream files:

| Widget | Name | How |
|---|---|---|
| the editor (`IdeSourceView`) | "Editor for e0_typing.py" | an editor page addin sets the accessible label from the page's title, and follows it |
| the header's new-page menu (`list-add-symbolic`) | "New Page" | a workspace addin gives each icon-only menu button without a tooltip one, by its icon |
| the omnibar's dropdown (libpanel's, no icon) | "Build Details" | the same, by its `PanelOmniBar` ancestor |
| the sidebar's menu (`open-menu-symbolic`) | "Sidebar Menu" | the same |
| each tab bar's page menu (`pan-down-symbolic`) | "Open Pages" | the same, again on each page change, for the frames a split adds |
| the Run button's dropdown | "Run Options" | `adw_split_button_set_dropdown_tooltip()` |
| the Run button's main button | "Run Project (Shift+Ctrl+Space)", or "Stop Running Project" | libadwaita labels it by its dropdown; the addin replaces that relation with `IdeRunButton`'s own tooltip, and follows it |
| the status bar's diagnostics button (E2) | "Build Diagnostics: 0 errors, 0 warnings" | GTK named it "0 0" from its two count labels; found by its own tooltip in Builder's catalogue, and named from `IdeBuildManager`'s counts as they change (plurals from `APEX_NG_`) |
| an editor tab bar's two tab lists (E2) | "Pinned Pages", "Pages" | by the accessible role, under `AdwTabBar`, the first being the pinned one |
| a dock's panel switcher (E2) | "Panels" | libpanel's `PanelFrameSwitcher` only: the bottom and end frames', the sidebar's being "Sidebar views" since E2's UI. The lane opens the bottom panel (Ctrl+F9) for a snapshot of its own: its tabs, Build Pipeline, Manuals, TODO/FIXMEs and Unit Tests among them, are named and take keyboard focus, as upstream's do |
| the sidebar's view switcher (E2 UI) | the tab list "Sidebar views", its tabs "Project", "Outline", "Search" and "Version control" | the boards' switcher over the start frame (`gbp-apex-sidebar.c`): an `AdwToggleGroup` built with the tab-list role, so each segment is a tab named for its view, the shown one selected |
| the Search view (E2 UI) | the entry "Search in Project"; each hit a button "Line 5: return undefined_name + a"; "Show 1 result in Find in Files" | the entry by its placeholder; a hit by its line and text, without its indent. The lane searches e1_lsp.py's undefined_name, then hands it to Find in Files |
| the Version control view (E2 UI) | the tab "Version control", badge or not; each change a button "dock.js in desktop/shell/js/ui/apex/dock, 12 added, 2 removed" | the tab is labelled for its view, or GTK would name it for its badge. The captures check the fixture's three changes by these names |
| the palette (E2 UI) | the popover and its entry "Search files, symbols and commands"; the list "Results", a list item per group header and result, a result named "e1_lsp.py, tests", the selected one selected | the board's names. The "nothing unnamed" check leaves list items out: the project tree's rows are unnamed list items in Builder |
| the Outline view (E2 UI) | the tree "Outline of e1_lsp.py", each item named for its symbol and described "Line 4" | the board's names; the current symbol's item is selected. The lane opens it with the cursor at the file's end, and finds pylsp's f there, current |
| the diagnostics popover's switcher (E2) | "Diagnostics" | the `GtkStackSwitcher` between errors and warnings, in the diagnostics button's popover |
| a page's progress bar (E2) | "Progress" | `GtkProgressBar` under an `IdePage`; it shows both loading and saving |
| the project tree's filter (E2) | "Filter…" | a `GtkSearchEntry` is named by its placeholder |
| the project tree (E2) | "Project Tree" | a `GtkListView` in a panel is named by the panel's title |
| empty status bar labels (E2) | — | vim's command bar sits empty in the status bar, and the hidden state does not take it out of the tree, so the label is hidden while it has no text, even when its owner shows it |

### The sidebar (E2 UI)

Boards 40 to 42 (`docs/design/apex-code-boards-40-42.md` in apex, section 6) put one
segmented switcher at the top of the sidebar, four views wide: Project, Outline, Search and
Version control. `gbp-apex-sidebar.c` installs it, in the project workspace and the
editor-only one alike, as the first start frame's header in place of libpanel's
`PanelFrameSwitcher`: an `AdwToggleGroup`, a segment per page of Builder's own
frame, in the boards' order, with the boards' icon and name for each view. `style.css`
draws it in the boards' tokens: a `--btn` track with 3px of padding and a 10px radius,
30px segments with an 8px radius, the selected one `--view` with its shadow. The stylesheet
keys dark on `AdwStyleManager`, which Builder's style variant sets, through a `dark` class.
It takes only the boards' views as drops: a document dragged
there would leave the editor grid, and with it the close prompt for its unsaved edits.
Every start frame is swept, a split one a session restored included: the other panes go
to the bottom panel, the views join the switcher's frame. The moved panes' `presented`
signal is blocked while they move, or TODO/FIXMEs would mine the project at every start.
All four views exist: Project, Outline, Search and Version control.

The Outline view (`gbp-apex-outline-pane.c`) is an `IdePane` on the start frame. It follows
the focused editor's buffer and asks Builder's symbol resolvers for its tree, the last
resolver first, as Builder's own symbol menu does. Under a 26px file caption, each symbol is
a 28px row: the board's kind glyph (C for a class, ƒ for a function or method, fn and impl in
Rust, # otherwise), the name, and the line. The current symbol, the last one at or above
the cursor's line, is drawn `--sel` and bold. Activating a row moves the cursor to the symbol.
An empty tree is retried, 1 to 32 s apart, and again after each save: ctags writes its
first index only after a save, and a language server can answer before it is ready.

The Search view (`gbp-apex-search-pane.c`) is Builder's Find in Files in the sidebar: its
entry runs the grep plugin's `GbpGrepModel` over the project, 300 ms after the last key.
The results come in groups, one per file: the name, the last two folders `--dim`, and a
`--btn` count pill, over 24px mono hit rows with the match on the accent at 24% and the
rest `--dim`. A hit opens its file at its line. The button above the results hands the same
model to Find in Files in the bottom panel, which keeps Builder's list and its Replace.
Choosing the Search segment puts the focus in the entry.

Ctrl+K opens board 41's palette (`gbp-apex-palette.c`): a 600px popover under the header bar
that asks Builder's own search engine, the providers of its global search, for files,
symbols and commands, at most four of each, and shows them in the board's groups and order.
A file is named by its base name over its folder; the query's letters are drawn in the accent
at 800, each at its first place after the last. Up and Down move over the results, the
headers skipped; Enter activates the result as Builder's search does. `>` limits it to
commands, `@` to symbols, and `:N` goes to line N of the page in front.

The Version control view (`gbp-apex-vcs-pane.c`) lists the project's changed files from
Builder's own VCS (`ide_vcs_list_status_async`), refreshed on its `changed` signal: under a
"Changes" header and count pill, a 30px row per file, its name over its folder `--dim`, then
the added lines in `--add` and the removed in `--mod`. Builder's VCS has no line counts, so
they come from `git diff --numstat HEAD` in the project. A row opens its file. The segment
carries the count as its badge. The project tree's changed-file icon, which Builder already
puts at a row's trailing edge, is drawn as the board's 7px `--mod` dot.

#### Not on the board

| Builder's | Where it goes | Why |
|---|---|---|
| Build Pipeline, Manuals, TODO/FIXMEs and Unit Tests in the sidebar | the bottom panel, each a tab beside Builder's own, named and reached as upstream has them | the boards' switcher has exactly four views; the boards' bottom panel is tabbed |
| the Outline's indent | Builder's nesting: 8px, then 14px more for each level | the board indents every row after the first unless it is a class, impl or h1, so feature.js's two top-level functions sit at 8px and 22px |
| an Outline row | activating it moves the cursor to the symbol | the board's rows have no click handler |
| Search's "Open 6 results as one buffer", with no handler | "Show 6 results in Find in Files": the same model in Builder's panel | Builder has no buffer of results; its panel lists them and replaces in them |
| Search's static entry and results | a live search of the project | the board draws one query |
| Version control's counts, badges and list, hard-coded | live: the project's changes, the badge and pill their number | the board draws one branch |
| the tree's dots on dock, dock.js, feature.js, tests and tests/layer only | Builder's own marks, on every ancestor of a changed file | the spec notes the board's skips as a quirk; Builder marks the whole path |
| the commit box and its button | Not on the board yet: commit box (needs staging; the agent text belongs to the agent feature) | a button over the list would commit more than it shows; it comes as its own change, with a choice per file |
| Version control's +N −N | `git diff --numstat HEAD`, run on the host, asynchronously, refreshed with Builder's VCS | Builder's VCS has none; a repository without a HEAD yet lists its changes without counts |
| the palette's results, `dlab` and its five rows | whatever Builder's search providers answer: files from its file index; symbols only where a provider indexes them (C, through the code index); commands | the board draws one query; Builder has no JavaScript symbol index |
| an empty query | an empty list under the input | the board draws none; Builder keeps no recent list for it |
| the palette's Ctrl K chip on the omnibox | Ctrl+K on the workspace | the omnibox comes with the status strip |
| an empty Outline | "No outline for this file", and, unlike Builder's symbol menu, the next resolver tried after an empty tree | the board has no empty state; ctags answers with an empty tree before its first index |

### Translations

Apex's strings (the name and titles, the toolbox notifications) come from the
`apex-builder` domain, which ships Vietnamese. GNOME Builder 50 has no vi catalogue (54
languages, no `vi.po`), so under a Vietnamese locale its own menus and dialogs stay
English beside Apex's Vietnamese, as Ptyxis's do. GLib's `g_dgettext` leaves every domain
untranslated while the application's own has no catalogue for the locale, so
`apex-i18n.h` calls libc's `dgettext`, and binds the domain on first use: `main.c` sets
the application name before any plugin loads. Strings are marked `APEX_()` rather than
`_()`, because the hunks sit in upstream files whose `_()` is Builder's domain.

## The series

| Patch | Upstream files | Changed lines | Hunks |
|---|---|---|---|
| `0001-build` | `src/plugins/meson.build` | +1 | `subdir('apex')` after podman |
| `0002-name` | `src/main.c`, `src/libide/gui/ide-application-actions.c`, `ide-workbench.c`, `src/libide/greeter/ide-greeter-workspace.c`, `src/libide/tweaks/ide-tweaks-window.c`, `data/org.gnome.Builder.desktop.in.in` | +18 −12 | the includes; the application name, the about dialog's name and the "Builder — %s" titles from `apex-brand.h`; `Name=Apex Code` |
| `0003-podman-storage-path` | `src/plugins/podman/gbp-podman-runtime.c` | +1 −1 | `/etc/containers/storage.conf`, which lost its leading `/` |
| `0004-podman-workdir` | `src/plugins/podman/gbp-podman-runtime.c` | +10 | the run handler refuses a working directory no mount of the container holds |
| `0005-program-lookups` | `ide-pipeline.c`, `ide-pipeline-private.h`, `ide-diagnostic-tool.c`, `ide-path-cache.[ch]` (foundry), `ide-lsp-service.c`, `gbp-podman-runtime.[ch]` | +450 −55 | lookups on a worker thread, for podman and host, before a diagnostics pass, a server's start and a pipeline's load; podman's cache, and a way to clear it (E2; see below) |
| `0006-podman-bridge` | `src/plugins/podman/gbp-podman-runtime.c` | +10 | the run handler hands a toolbox's processes without a TTY to `apex-toolbox-exec` (E2; see below) |

No ADR 0014 budget applies to this series (ADR 0017, decision 2); each patch still says
what it changes and why, and the lane's checks apply. In use: +490 −68 lines in 15 files, of
which 0005's +450 −55 is a fix to propose upstream rather than a hook. The
patches are `git format-patch` output against Fedora's `%prep` tree, with `a/` and `b/`
prefixes, applied with `-p1`; write them with apex-image's `just pkg-prep gnome-builder`
and `just pkg-export gnome-builder`.

## E0's findings

- **A project outside `$HOME` respawned its servers every 5 s.** `podman exec
  --workdir=<project>` on a path the toolbox does not mount fails with exit 127, and
  `IdeSubprocessSupervisor` restarted the server at its 5 s rate limit, forever, with no
  error shown. Patch 0004 fails the run context instead, so the server is never spawned,
  and the plugin says why. The check reads the container's `Mounts` from the JSON the
  podman provider already holds, so it costs no extra `podman` call.
- **The storage path lost its leading `/`** (patch 0003). For the system file Builder
  reads only `rootless_storage_path`, which Fedora's `/usr/share/containers/storage.conf`
  leaves commented out and `/etc/containers/storage.conf` overrides when present, so a
  rootless user still gets `~/.local/share/containers/storage`.
- **The 0.76 s typing stall: fixed in E2** (patch 0005). E0 saw one main-loop stall
  about 2.4 s into typing. Its cause is a file's first diagnostics pass:
  `IdeDiagnosticTool`'s `prepare_run_context()` looks up its program (flake8 for Python)
  with `ide_pipeline_contains_program_in_path()`, then on the host. Each lookup spawns
  `which`, through `podman exec` for the toolbox (134–177 ms here), and blocks on
  `ide_subprocess_wait_check()` on the main thread; the runtimes cache the answers, so it
  happens once per program and runtime. Builder's log shows `Failed to locate program
  "flake8"` at the end of the stall; installing flake8 would not help, since a found program
  costs the same lookups. `IdeLspService` does the same when a pipeline finishes loading:
  `ide_lsp_service_create_launcher()` looks up `ruff` and `pylsp` (145 and 160 ms here), so
  the stall also comes when the toolbox's pipeline loads as the file opens. Patch 0005 adds
  `_ide_pipeline_find_programs_async()`, which makes those lookups on a worker thread; the
  diagnostic tool runs it before each pass, the language server once per pipeline before
  it creates its launcher, and the pipeline before it loads its addins, whose build systems
  look up ninja, ninja-build and cargo. All of them then find their answers cached. Only
  the podman and host runtimes are looked up there, as their path caches lock; a Flatpak
  runtime reaches the context for its SDK, which is main-thread only, so the others stay
  on the main thread, and each lookup left there is logged. The podman runtime caches every
  answer but podman's 125 while its `podman start` has not exited, so a container without
  `which`, or one that will not start, costs one lookup per program; a worker waits for that
  start while the main thread never does; it frees what a worker reads in finalize, and
  forgets its programs on request (`gbp_podman_runtime_forget_programs()`). Typing from the moment the file opens, the longest key here went from 313 ms
  (diagnostics) and 320 ms (language servers) to 30.5 ms (median 14.2 ms). With the
  toolbox stopped and its start held 3 s, the code before these last changes cached
  pylsp as missing (no completion) and looked up ninja on the main thread; now neither.
- **One shared `podman exec` per toolbox: done in E2** (patch 0006). Every process
  Builder ran in the toolbox was its own `podman exec`, whose Go client stays alive as the
  process's stdio (about 48 MiB RSS, 26 MiB PSS each) beside a `conmon` (about 2.3 MiB).
  Now the podman run handler hands a toolbox's processes without a TTY to
  `apex-toolbox-exec`, a small C client (`desktop/gnome-builder/src/plugins/apex/`, no
  GLib), which talks to one `apex-toolbox-bridge` per toolbox over a socket in
  `$XDG_RUNTIME_DIR` (the protocol is in `apex-toolbox-bridge.h`):
  - the client sends the argv, the environment and the working directory, and passes its
    descriptors 0 to N − 1 with `SCM_RIGHTS`, so the process writes to Builder's pipes
    directly and nothing copies its stdio;
  - the bridge forks a handler, which spawns the process in its own process group on those
    descriptors, with the client's environment over the toolbox's, as `podman exec --env`
    gives it, then replies with the exit status or the signal;
  - the client passes on SIGTERM, SIGINT, SIGHUP and SIGQUIT, and when the client dies
    (Builder's SIGKILL) the handler kills the group;
  - the first client that finds no bridge starts it with `podman exec … --daemonize`, from
    the host's `/usr/libexec` under `/run/host`; the bridge goes to the background only once
    it listens, so that exit status says whether it started, and a lock beside the socket
    keeps it to one. A start that fails because the bridge cannot run (podman exec's 126 or 127, not its
    125 for a toolbox not running yet) leaves a `.failed` stamp that sends every client
    straight to `podman exec` for ten minutes; a client that cannot reach a bridge execs
    `podman exec` as before, so a dead bridge costs one respawn and no more;
  - the socket's peer gets the process's pipes and environment, so the socket lives only in
    a `$XDG_RUNTIME_DIR` that is an absolute directory of the user's alone (not a link,
    mode `077` clear; without one, `podman exec`, never `/tmp`), both ends check
    `SO_PEERCRED` for the same uid, and the bridge binds only in such a directory;
  - the bridge is linked statically (`-static-pie`, `glibc-static`): it runs inside the
    toolbox, whose glibc may be older than the host's, and it calls no NSS.

  A TTY (the terminal, a build with a PTY), any other container, a folder the container
  does not mount (0004's error), or `APEX_TOOLBOX_BRIDGE=0` keeps `podman exec`.
  `tests/builder/bridge.sh`, which `run.sh` runs first, checks the socket rules, a failed
  start, and the process groups: a forwarded signal or the client's death reaches the
  process from its first moment, as both the bridge and the process set its group. The
  program lookups (`which`, through the bridge) went from 134–177 ms to about 50 ms.

## The sign-off captures

`tests/builder/shoot.sh` renders the boards' states for the owner to compare with boards 40
to 42 (`docs/design/apex-code-boards-40-42.md` in apex). signoff.yml runs it on the lane's
RPM, beside the other apps' shooters, and `signoff.sh` collects its rows:

- `fixture.sh` writes the boards' apex-gnome project: the tree of the spec's section 7.1,
  committed on main, then the branch dock-focus-label with dock.js, feature.js and
  tests/layer/run.sh changed. Its outlines put the boards' symbols on the boards' lines.
- A user `apex` opens it in a headless gnome-shell at scale 2 (2880×1800), with the image's
  fonts, animations and the cursor blink off, and the clock held; dock.js opens with the caret
  at its start, and the window sits at the board's 1240×762 at (100, 48).
- Each capture, light and dark (`style-variant`), must name the editor and the project tree
  over AT-SPI. Two runs here gave byte-identical captures.
- The container has no podman, so Apex Code offers no toolbox; the boards show none.

Until the owner approves goldens, `goldens.sh check` reports the rows as awaiting sign-off,
and the job fails only on a crash, a capture that did not happen or a missing name.
Board 40 is the first row; boards 41 and 42 follow with the UI items that draw them.

## Building it here

```bash
just builder-test   # desktop/gnome-builder's licence and paths, the series, the patches' From: lines
just builder-lane   # podman or docker: apex-lane's container half in fedora:45
just builder-run    # podman or docker, privileged: the built RPM against E0's budgets, names, typing and toolbox
```

`tests/lib/lane.sh gnome-builder` builds `apex-lane` from a pinned apex-image commit and
runs its container half, `apex-lane in-container build gnome-builder`, as the builder VM
does: the SRPM's signature, `spec-edit`, the series at fuzz 0, the exact-tree check,
`rpmbuild -ba` with Fedora's `%check` (appstream and desktop-file validation), the lane
checks and `check.sh`. It leaves out what the VM adds, the signing and the store. The RPMs
and logs land in `_build/gnome-builder/out/`. CI runs it on every push and keeps the RPM as
the `gnome-builder-rpms` artifact.

## The lane case

`tests/builder/run.sh` installs that RPM in a privileged fedora:45 container, copies this repository
to `~/Projects/apex-gnome` (inside the toolbox's shares), and runs gnome-shell headless at
1920×1080 as root, E0's setting. Its automation script, `probe.js`:

- without `fedora-toolbox-45` (always in CI), opens the project and presses the
  notification's Create Toolbox over AT-SPI (`press.py`), then waits for pylsp to start
  through `podman exec` in the new toolbox, without reopening the project;
- starts Apex Code three times on the project, after a discarded start, each after
  `run.sh` drops the page cache; it times the spawn to the first painted frame as E0 did
  (the window's `first-frame`, then the stage's next `after-paint`);
- opens `tests/e1_lsp.py`, maximises the window, waits 30 s, and samples Apex Code's own
  process tree ten times (`mem.py`: RSS and PSS from `smaps_rollup`, the language servers
  and the `podman exec` clients apart, as E0 counted);
- reads buttons, toggle buttons, text, tab lists, progress bars, entries, lists and labels
  over AT-SPI (`atspi.py`) at three points: before any page has focus, with the file open,
  and with the diagnostics popover open;
- starts Apex Code again with its verbose log and opens an empty `tests/e2_typing.py`,
  whose first diagnostics pass starts as it opens. From then it types a line of Python, a
  key every 150 ms for 60 s, and times each key from the press to the frame presented after
  the window's first damage, as E0 did. Then it types `os.pa` and waits for pylsp, in the
  toolbox, to answer the completion request. This session draws with GSK's cairo renderer:
  under lavapipe, the completion popup's first Vulkan pipeline compiles in 290–430 ms on the
  main thread, a cost of the software driver that a GPU does not have.

It fails above E1's column of E0's budgets: a first frame over 1.9 s (median of 3), idle
RSS over 360 MiB or PSS over 270 MiB (median of 10); a missing name of the table above,
a button, toggle button, tab list, progress bar, entry, list or label left unnamed with the
file open (the editor's text is named by the table, not by this check; list items are left
out, the project tree's being unnamed in Builder), or no completion from pylsp. It also fails on E2's
stall budget: any key over 200 ms, or one that drew nothing within 2 s. In the session the desktop
portal is masked: in a headless container it waits 25 s on RealtimeKit and Builder waits
on it. Here (4 vCPUs, software rendering): first frames 1731, 1932 and 1605 ms, idle RSS
338 MiB and PSS 239 MiB with pylsp running, 463 completion items. CI runs it after the lane
and keeps `run.json` and the logs as the `gnome-builder-run` artifact.
