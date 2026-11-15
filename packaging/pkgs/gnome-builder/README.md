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
| `gbp-apex-a11y-addins.c` | E0's AT-SPI gaps: the editor named for its file, and the icon-only menu buttons named (below) |
| `apex-brand.h` | the name: `apex_code_name()`, `apex_code_title()`, `apex_code_preferences_title()` |
| `apex-toolbox.h` | `apex_podman_container_shares_path()`: whether a container's mounts (from `podman ps --format=json`) hold a path |
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
  containers only when a project loads, so the notification asks to reopen the project.
  A toolbox the image or the first login creates is used as is.
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

E0's gaps 3 to 6 that remain (the diagnostics button's "0 0", the progress bar, the tab
lists and the filter entry, the empty status label) are E2's, with the status strip.

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
| `0005-program-lookups` | `src/libide/foundry/ide-pipeline.c`, `ide-pipeline-private.h`, `ide-diagnostic-tool.c`, `src/libide/lsp/ide-lsp-service.c`, `src/plugins/podman/gbp-podman-runtime.c` | +404 −54 | `_ide_pipeline_find_programs_async()` makes the program lookups on a worker thread, for the podman and host runtimes; a diagnostic tool runs it before each pass, a language server before it starts, the pipeline before it loads; the podman runtime caches only `which`'s own answer and lets a worker wait for `podman start` (E2; see below) |

No ADR 0014 budget applies to this series (ADR 0017, decision 2); each patch still says
what it changes and why, and the lane's checks apply. In use: +434 −67 lines in 12 files, of
which 0005's +404 −54 is a fix to propose upstream rather than a hook. The
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
  on the main thread. The podman runtime caches only `which`'s own answer (0 or 1), not
  podman's 125 while the container is still starting, and a worker waits for its
  `podman start` while the main thread never does; it frees what a worker reads in
  finalize. Typing from the moment the file opens, the longest key here went from 313 ms
  (diagnostics) and 320 ms (language servers) to 30.5 ms (median 14.2 ms). With the
  toolbox stopped and its start held 3 s, the code before these last changes cached
  pylsp as missing (no completion) and looked up ninja on the main thread; now neither.
- **One shared `podman exec` per toolbox: feasible.** Today every process Builder runs in
  the toolbox is its own `podman exec`, whose Go client stays alive as the server's stdio
  (about 48 MiB RSS, 26 MiB PSS each) beside a `conmon` (about 2.3 MiB). The shared form:
  one `podman exec --detach` per toolbox runs a small bridge inside it, which listens on a
  socket in `$XDG_RUNTIME_DIR` (toolbox shares it with the host) and spawns each server
  with the argv, environment and working directory Builder sends, and the stdio fds Builder
  passes with `SCM_RIGHTS`. Nothing then copies a server's stdio, and the host keeps one
  `conmon` per toolbox: about 2 MiB in all, under E2's ≤ 20 MiB. The bridge can ship on
  the host and run inside the toolbox from `/run/host/usr/libexec/` (toolbox mounts the
  host's root at `/run/host`); it needs the same Fedora or a static link. In Builder it is
  a second run handler in the podman runtime for toolbox containers, about 400 lines in
  all; exit status and signals travel over the socket.

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

`tests/builder/run.sh` installs that RPM in a privileged fedora:45 container, creates
`fedora-toolbox-45` with the setup Apex Code's Create Toolbox runs, copies this repository
to `~/Projects/apex-gnome` (inside the toolbox's shares), and runs gnome-shell headless at
1920×1080 as root, E0's setting. Its automation script, `probe.js`:

- starts Apex Code three times on the project, after a discarded start, each after
  `run.sh` drops the page cache; it times the spawn to the first painted frame as E0 did
  (the window's `first-frame`, then the stage's next `after-paint`);
- opens `tests/e1_lsp.py`, maximises the window, waits 30 s, and samples Apex Code's own
  process tree ten times (`mem.py`: RSS and PSS from `smaps_rollup`, the language servers
  and the `podman exec` clients apart, as E0 counted);
- reads every button, toggle button and text over AT-SPI (`atspi.py`);
- starts Apex Code again with its verbose log and opens an empty `tests/e2_typing.py`,
  whose first diagnostics pass starts as it opens. From then it types a line of Python, a
  key every 150 ms for 60 s, and times each key from the press to the frame presented after
  the window's first damage, as E0 did. Then it types `os.pa` and waits for pylsp, in the
  toolbox, to answer the completion request. This session draws with GSK's cairo renderer:
  under lavapipe, the completion popup's first Vulkan pipeline compiles in 290–430 ms on the
  main thread, a cost of the software driver that a GPU does not have.

It fails above E1's column of E0's budgets: a first frame over 1.9 s (median of 3), idle
RSS over 360 MiB or PSS over 270 MiB (median of 10); a missing name of the table above,
any unnamed button or toggle button, or no completion from pylsp. It also fails on E2's
stall budget: any key over 200 ms, or one that drew nothing within 2 s. In the session the desktop
portal is masked: in a headless container it waits 25 s on RealtimeKit and Builder waits
on it. Here (4 vCPUs, software rendering): first frames 1731, 1932 and 1605 ms, idle RSS
338 MiB and PSS 239 MiB with pylsp running, 463 completion items. CI runs it after the lane
and keeps `run.json` and the logs as the `gnome-builder-run` artifact.
