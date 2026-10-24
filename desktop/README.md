# The Apex layer

The Apex layer of gnome-shell ([ADR 0014](https://github.com/apex-linux/apex/blob/main/docs/adr/0014-engine-level-desktop.md),
[ARCHITECTURE 7.4](https://github.com/apex-linux/apex/blob/main/docs/ARCHITECTURE.md#74-desktop-layer),
[DESIGN.md](https://github.com/apex-linux/apex/blob/main/docs/DESIGN.md)). It reads its settings from
[apex-desktop](https://github.com/apex-linux/apex-desktop)'s schema. The `just` recipes named here are
[apex-image](https://github.com/apex-linux/apex-image)'s, which holds the lane and the builder VMs.

## `desktop/shell/`

The lane ([packaging/README.md](https://github.com/apex-linux/apex-image/blob/main/packaging/README.md#the-rebuild-lane)) packs this
directory with `git archive` and unpacks it at the top of Fedora's gnome-shell tree in
`%prep`, with `tar -k`, so a file here can never replace an upstream file.

| Path | What it is |
|---|---|
| `apex.gresource.xml` | the Apex resource: `/org/gnome/shell/ui/apex` (the layer), `/org/gnome/shell/theme/apex` (the sheets' assets) and `/org/gnome/shell/theme/stock` (upstream's compiled light and dark sheets, the safe-mode sheets). Patch 0001-build compiles it and links it into libshell next to upstream's JS resource. |
| `js/ui/apex/hooks.js` | the only Apex module upstream files import: `safe()`, `value()`, `run()`, and `loadLayer()` for `main.js` |
| `js/ui/apex/layer.js` | the layer: the configure and enable phases, one `try/catch` per feature, the session-mode colour hook, the crash guard's marker file |
| `js/ui/apex/spotlight/feature.js` | Super+Space (below) |
| `js/ui/apex/panel/feature.js` | the top bar of S2a (below): its parts in `panel/`, one module each |
| `js/ui/apex/fault/feature.js` | the fault-injection feature: loaded only when `APEX_SHELL_TEST_FAULT` names a phase, it fails in that phase (below) |
| `data/theme/apex/_apex-tokens.scss` | the design tokens as SCSS variables, imported after upstream's `_colors` |
| `data/theme/apex/_apex.scss` | the Apex sheet, imported last by the light and dark entry files |
| `data/theme/apex/_top-bar.scss` | the top bar over upstream's panel, in the user session and the overview. Its text sizes are in pt (`apex-text-size`), so Large Text grows the text and nothing else: the bar, the pills and the glyphs keep SPEC's px sizes, where upstream sizes the bar in em. The unread-notification dot is `$apex_bar_fg` until S1b brings the wallpaper SPEC's accent dot was drawn over; over Fedora's wallpaper the light bar hides an accent dot. G2 asserts both ([tests/shots](../tests/shots/README.md)) |
| `data/theme/apex/diamond-{light,dark}.svg` | the Apex diamond in the Activities pill, stroked in each variant's `$apex_bar_fg` |
| `data/theme/apex/_apex-structure.scss` | Apex actors' geometry for the high-contrast sheet |
| `data/theme/apex/meson.build` | adds the partials to upstream's `theme_sources`, so an edit recompiles the sheets |

Rules, which the lane and `.github/scripts/selftest.sh` enforce:

- Every path must be new to upstream and match `source1_paths` in
  [pkg.env](../packaging/pkgs/gnome-shell/pkg.env). That is why this directory has no
  README, licence file, top-level `meson.build` or ESLint configuration: each would
  collide with an upstream file.
- Every file carries `SPDX-License-Identifier: GPL-2.0-or-later` in its first three
  lines.
- A new JS module is one `<file>` line in `apex.gresource.xml`; the lane fails when a
  `js/ui/apex/` module is missing from the built resource.
- An Apex asset is referenced as `url("resource:///org/gnome/shell/theme/apex/<file>")`,
  as upstream does for its own, and needs its `<file>` line in `apex.gresource.xml`; the
  lane fails when a sheet names an asset the resource lacks.

### The layer

`FEATURES_IN_ENABLE_ORDER` in `layer.js` lists `spotlight` (S1b) and `panel` (S2a), by
the names DESIGN's `disabled-features` uses. `spotlight`
registers `toggle-spotlight` from `io.github.apex_linux.Apex.Desktop.Keybindings`
(`['<Super>space']`) with `Main.wm.addKeybinding` at enable, in the normal and overview
action modes and without autorepeat, and removes it at disable. Until S3a's Spotlight it
opens the stock overview with its search entry focused, and pressed while the overview is
up it hides it. apex-desktop's override moves `switch-input-source` to Super+Alt+Space,
so nothing else owns Super+Space; a Super tap (the overview) and Super+A (the launcher)
are upstream's. The feature follows the kill switches and `disabled-features` like any
other, and a missing Keybindings child schema turns off only this feature, logged once.

`panel` is the top bar. Its parts provide the hooks of patch 0010-panel
([the series](../packaging/pkgs/gnome-shell/README.md#the-series)); the feature follows the
kill switches and `disabled-features=['panel']` as a whole, and each part restores the
stock bar when it is disabled:

- `panel/workspace-dots.js`: the active dot as wide as `.workspace-dot`'s `-apex-active-width`
  (`$apex_bar_dot_active_width`), the others full size at .45, where stock widens the
  active one by a factor of the workspace count and shrinks the rest to .75 at .5.
- `panel/hot-corner.js`: each hot corner's actor becomes a reactive 4 × 4 zone in the chrome (in
  scaled px, left of the corner right to left, hidden under fullscreen windows). Entering
  it triggers the corner's pressure barrier, so the pressure that follows does not toggle
  the overview back; the barrier stays. Both exist only with `enable-hot-corners`.
- `panel/status-pill.js`: takes brightness, Thunderbolt, Night Light, Dark Style, Do Not Disturb,
  backlight, Bluetooth, Airplane Mode, auto-rotate and the power profile out of the status
  pill. Network, volume, battery, the camera, microphone, location and remote-access
  indicators, unsafe mode and other panel buttons (input source, accessibility,
  recording) stay. Their Quick Settings toggles stay too.

The layer also does what every feature relies on:

- In the user and unlock-dialog modes it gives the session mode the colour scheme
  `'prefer-light'`, so GNOME's `'default'` draws a light shell and Dark Style draws a
  dark one. The gdm mode keeps upstream's `'prefer-dark'`.
- `enable()` creates `$XDG_RUNTIME_DIR/apex-shell-starting` and removes it after 60 s
  or at shutdown, for the crash guard (ADR 0014).
- `APEX_SHELL_TEST_FAULT` in the shell's environment adds the `fault` feature after
  every real one, for the safety net's tests (ROADMAP S1a exit). `configure` makes its
  `configure()` throw and `enable` its `enable()`: the feature is off for the session,
  its hook `test-fault` gives the stock value, and the rest of the layer runs.
  `abort-after-enable` aborts the shell (SIGABRT) 5 s after enable, while the crash
  guard's marker exists. Any other value injects nothing. The image never sets the
  variable: G1 fails on it (`image/checks/desktop.sh`).

Kill switches, strongest first: `apex.safe=1` on the kernel command line or
`APEX_SHELL_SAFE=1` in the shell's environment (every session); `layer-enabled=false`
(one user); `disabled-features` (one user, per feature). Safe mode loads no layer (only
`hooks.js` runs, and every hook gives its stock value) and takes the stylesheets from
`/org/gnome/shell/theme/stock/`. The high-contrast sheet has no stock copy, so safe mode
with high contrast uses the rebuilt one, whose Apex part styles only Apex actors. G2
checks that it is Fedora's sheet apart from the structure marker; a structure rule that
restyles upstream's actors fails there, and then needs a stock high-contrast copy.

`tests/layer/run.sh` (`just layer-test`, and ci.yml) runs `hooks.js` and `layer.js` in
gjs outside the shell: every kill switch, `apex.safe=1` through a bubblewrap bind over
`/proc/cmdline`, the gdm mode, the three fault phases, the crash guard after an
aborted shell, and Super+Space: its registration and removal through enable, the kill
switches, `layer-enabled` and `disabled-features` cycles and a missing Keybindings schema,
and the top bar's hooks with stub dots, indicators and hot corners, against
`tests/layer/main-stub.js` for `main.js`, fixture typelibs for Meta and Shell, and
`tests/layer/stubs/` for the features' St and Clutter imports, which gjs outside the shell
cannot load.

For the fault injection in the VM, the variable goes into the shell's environment with
a user drop-in on its unit, which the image never ships:

```bash
mkdir -p ~/.config/systemd/user/org.gnome.Shell@.service.d
printf '[Service]\nEnvironment=APEX_SHELL_TEST_FAULT=abort-after-enable\n' \
    >~/.config/systemd/user/org.gnome.Shell@.service.d/90-fault.conf
systemctl --user daemon-reload
# log out and in: the shell aborts 5 s after the layer's enable; the next login is stock
rm ~/.config/systemd/user/org.gnome.Shell@.service.d/90-fault.conf
systemctl --user daemon-reload
gsettings set io.github.apex_linux.Apex.Desktop layer-enabled true
```

### The dev loop

| Change | Loop | Time |
|---|---|---|
| Apex JS, SCSS and assets in `shell/`; upstream JS in the lane's work tree | `just shell-dev`: a nested shell in the desktop VM | 2 to 3 s (the S1a exit asks for 15 s) |
| C in gnome-shell | `just shell-c` prints the procedure: ninja in an F45 toolbox, `bootc usroverlay` | under 30 s with the nested shell's restart |
| the lane's RPM | `just pkg-build gnome-shell` | 10 to 15 minutes |
| the image | `just vm-image`, then `just desktop-update` | about 3 minutes after the build, with the reboot |

Every recipe that targets the desktop VM takes it from `APEX_DESKTOP_DIR` (the owner's
VM by default) and prints it first; tests set `APEX_DESKTOP_THROWAWAY=1`
([tools/builder-vm/README.md](https://github.com/apex-linux/apex-image/blob/main/tools/builder-vm/README.md), "Which VM a command
targets"), where `just desktop-update` is described too.

#### JS and SCSS: `just shell-dev`

```bash
just shell-dev fetch   # once per gnome-shell build the VM runs; uses the builder VM
just shell-dev         # log in to GNOME in the VM window first; Ctrl+C stops it
```

`fetch` reads which gnome-shell build the VM runs (its `/usr/share/apex/rpms.lock`, or
the builder VM's `rpms.lock.next` while the VM is off) and copies from the builder VM:

- `js/` and `data/theme/` of the lane's work tree, `_build/pkg/gnome-shell/tree`, without
  the tree's own copy of the Apex files. When there is no tree, `lane.sh prep` makes one
  from the same Fedora build; a tree of another build is refused, never replaced;
- `mutter-devkit`, the exact build of the VM's mutter, and the Apex SRPM, from the
  lane's store.

They stay in `shell-dev/` in the VM's directory on this host.

`just shell-dev` then:

1. sends them and `shell/` into the VM, as tar over `desktop-vm.sh`'s ssh, to
   `/var/lib/apex-shell-dev`;
2. makes `/usr` writable until the VM's next reboot (`bootc usroverlay`) and installs
   `mutter-devkit` there;
3. compiles the light, dark and high-contrast sheets: upstream's entry files and
   partials with the Apex partials, by sassc in a podman container of
   `image/Containerfile`'s `REPOS_BASE` (made once per digest, as
   `localhost/apex-shell-dev-sassc`);
4. starts `gnome-shell --devkit --unsafe-mode` as the user logged in to GNOME, on its
   own session bus (a private `dbus-broker`: the image has no `dbus-run-session`), as
   the transient user unit `apex-shell-dev.service`. Its window opens in the VM. `G_RESOURCE_OVERLAYS` points it at the files:

   | Resource path | Files in `/var/lib/apex-shell-dev` |
   |---|---|
   | `/org/gnome/shell/ui/apex` | `src/js/ui/apex/`, this checkout's layer |
   | `/org/gnome/shell/theme/apex` | `src/data/theme/apex/`, the sheets' assets |
   | `/org/gnome/shell/theme` | `theme/`, the compiled sheets |
   | `/org/gnome/shell/ui`, `misc`, `gdm` | `inputs/tree/js/`, upstream JS with the series |

   GLib takes the first overlay whose file exists and the built-in resource otherwise,
   so a new Apex module or asset works before `apex.gresource.xml` lists it (the lane
   still needs the line);
5. looks for changes in `shell/` and in the fetched tree every second. SCSS recompiles
   and reloads the sheets (`Main.loadTheme()`); JS or a theme asset restarts the nested
   shell, because modules and textures load once per process. Each reload prints how
   long it took; the nested shell's journal follows, prefixed `[shell]`.

An upstream hunk is edited in the builder VM's work tree, as for `just pkg-export`;
`just shell-dev fetch` in a second terminal then brings it in, and the running loop
restarts the nested shell.

| Command | Does |
|---|---|
| `just shell-dev eval 'JS'` | runs `JS` in the nested shell and prints Eval's reply, for example `'Main.panel.height'` |
| `just shell-dev screenshot [FILE]` | saves the nested shell's screen as PNG, even with OpenGL |
| `just shell-dev stop` | stops the nested shell |
| `just shell-dev push` | sends the fetched inputs and `shell/` only |
| `just shell-dev probe` | with the loop running: appends a rule to `_top-bar.scss`, then a line to `layer.js`, times each until the nested shell shows it, takes each line out again, and exits 1 when one took over 15 s (the S1a exit). A file saved meanwhile keeps its edit: the probe takes out only its own last line, or leaves the file as it is and says so. The files as they were wait in the VM directory's `.shell-dev-probe/` until the probe ends; one left there by a killed probe stops the next |

Limits:

- None of it enters the image. G1 fails an image whose `/usr` or `/etc` names
  `G_RESOURCE_OVERLAYS` or `--unsafe-mode`, so the guest's half,
  `tools/builder-vm/shell-dev-guest.sh`, is copied to `/var/lib/apex-shell-dev/bin`.
- A VM reboot drops `mutter-devkit`; the next `just shell-dev` installs it again.
- The nested shell's bus starts no services: `dbus-broker` activates through the
  session's systemd, which that bus never reaches. Portals, gvfs, the calendar server
  and AT-SPI are missing in the nested shell, and each call to them fails at once. The
  bus also refuses `UpdateActivationEnvironment`, which would otherwise point the
  session's `WAYLAND_DISPLAY` and `DISPLAY` at the nested shell until the next login.
- The nested shell uses the session's runtime directory and settings. Its layer
  creates the crash guard's marker there too. A stop removes it: the unit signals only
  the shell, so its shutdown handlers run while its bus is still up. A nested shell
  that dies within 60 s of its start leaves the marker, and a session shell failure
  after that trips the guard
  (`gsettings set io.github.apex_linux.Apex.Desktop layer-enabled true`).

#### C: `just shell-c`

The C loop builds in the desktop VM, from the Apex SRPM of the build the VM runs, so the
tree and Fedora's meson options (`redhat-linux-build`) are exactly the package's.
`just shell-c` prints the commands:

1. On this host, `just shell-dev fetch && just shell-dev push` puts the SRPM in
   `/var/lib/apex-shell-dev/inputs/rpms/`.
2. In a terminal in the VM window, as your user, once per shell build: the SRPM copied
   to `~/apex-shell-c` (a toolbox sees the home directory, not `/var/lib`), an F45
   toolbox with `rpm-build`, `dnf builddep` of the SRPM, and `rpmbuild -rc`, which runs
   `%prep` and the first full build. The toolbox image and the build dependencies take
   about 15 minutes to download the first time, the build itself under a minute
   (`APEX_DESKTOP_MEM=6G just desktop` gives the VM room). `_package_note_status 0`
   leaves out Fedora's package notes, whose link flags read variables only rpmbuild
   sets, so `ninja` alone can link.
3. Each round, in the tree: `ninja`, `meson install --destdir`, then the install
   unpacked over `/usr` with tar, which replaces files rather than rewriting the
   libraries a running shell has mapped. `bootc usroverlay` keeps `/usr` writable until
   the next reboot, which drops the build.
4. `just shell-dev` (the nested shell) or a new login (the session shell) runs it.

The tree is a git repository (Fedora's `%autosetup -S git`). A change to keep is
committed there, applied as a commit to the builder VM's work tree, and written out with
`just pkg-export gnome-shell`.

