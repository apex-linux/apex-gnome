# GNOME Builder (Apex Code) in the rebuild lane

Fedora's gnome-builder SRPM, rebuilt as Apex Code: track E of the
[ROADMAP](https://github.com/apex-linux/apex/blob/main/docs/ROADMAP.md), after
[ADR 0017](https://github.com/apex-linux/apex/blob/main/docs/adr/0017-apex-code-on-builder.md).
This is E1: the name, toolbox as the default runtime, and the fixes the
[E0 spike](https://github.com/apex-linux/apex/blob/main/docs/reviews/2026-11-03-e0-apex-code.md)
found. The lane, `apex-lane`, and the formats of the files here are in
[packaging/README.md](https://github.com/apex-linux/apex-image/blob/main/packaging/README.md#the-rebuild-lane).

| File | Role |
|---|---|
| `pkg.env` | the SRPM, the hold family `gnome-builder`, the one binary package the image takes, and Source1 (`desktop/gnome-builder/`, unpacked as `src/plugins/apex/`) |
| `spec-edit` | anchored edits to Fedora's spec: `.apexN`, `Source1`, the `%prep` line that unpacks it, and the `apex-builder` catalogue in the main package's list |
| `series`, `patches/` | the hook hunks, one patch per concern |
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

No ADR 0014 budget applies to this series (ADR 0017, decision 2); each patch still says
what it changes and why, and the lane's checks apply. In use: +30 −13 lines in 8 files. The
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
- **The 0.76 s typing stall: cause found, not fixed in E1.** E0 saw one main-loop stall
  about 2.4 s into typing; with the toolbox runtime it is 0.63 s, 2.7 s in. Its cause is
  the first diagnostics run after the first edit: `IdeDiagnosticTool`'s
  `prepare_run_context()` looks up its program (flake8 for Python) with
  `ide_pipeline_contains_program_in_path()` for the program path and the program name,
  then `ide_runtime_contains_program_in_path()` on the host. Each lookup spawns `which`,
  through `podman exec` for the toolbox (134–177 ms here) or a login shell for the host
  (61–151 ms), and blocks on `ide_subprocess_wait_check()` on the main thread. The
  runtimes cache both answers, so it happens once per program and runtime; Builder's log
  shows `Failed to locate program "flake8"` at the end of the stall. A fix moves the
  lookup off the main thread: prime the runtimes' path caches from a libdex fiber when the
  pipeline is ready, or make `prepare_run_context()` asynchronous. It touches
  `ide-diagnostic-tool.c` and both runtimes, so it is E2's, against E2's ≤ 200 ms stall
  budget. Installing flake8 in the toolbox would not help: a found program costs the same
  lookup.
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
```

`tests/lib/lane.sh gnome-builder` builds `apex-lane` from a pinned apex-image commit and
runs its container half, `apex-lane in-container build gnome-builder`, as the builder VM
does: the SRPM's signature, `spec-edit`, the series at fuzz 0, the exact-tree check,
`rpmbuild -ba` with Fedora's `%check` (appstream and desktop-file validation), the lane
checks and `check.sh`. It leaves out what the VM adds, the signing and the store. The RPMs
and logs land in `_build/gnome-builder/out/`. CI runs it on every push and keeps the RPM as
the `gnome-builder-rpms` artifact.
