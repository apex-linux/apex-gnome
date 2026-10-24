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
| `js/ui/apex/motion/feature.js` | DESIGN's motion (below): one curve and fixed durations through patch 0016's hooks |
| `js/ui/apex/spotlight/` | Spotlight (below): `feature.js` (Super+Space), `search.js` (the sections, caps and budget), `providers.js` (the stock providers), `popup.js` and `toast.js` |
| `js/ui/apex/quick-settings/feature.js` | DESIGN's Quick Settings (below): VPN after Airplane Mode, Power Mode lit, On/Off subtitles, through patch 0011's hook |
| `js/ui/apex/panel/feature.js` | the top bar of S2a (below): its parts in `panel/`, one module each |
| `js/ui/apex/glass/feature.js` | the glass manager of S2b (below), with `glass/surfaces.js`, the layer's own glass, and `glass/registry.js`, where any feature registers an actor |
| `js/ui/apex/dock/feature.js`, `dock.js`, `trash.js` | the dock of S2a (below): ApexDock, a subclass of upstream's `Dash`, and its Trash |
| `js/ui/apex/fault/feature.js` | the fault-injection feature: loaded only when `APEX_SHELL_TEST_FAULT` names a phase, it fails in that phase (below) |
| `data/theme/apex/_apex-tokens.scss` | the design tokens as SCSS variables, imported after upstream's `_colors` |
| `data/theme/apex/_apex.scss` | the Apex sheet, imported last by the light and dark entry files: `apex-text-size()`, the `apex-surface()` mixin of the shell's own surfaces, and the partials |
| `data/theme/apex/_glass.scss` | each glass surface's `-apex-glass-blur` and `-apex-glass-saturation`, from the tokens of ADR 0014's table, and the solid tints under `.apex-solid` |
| `data/theme/apex/_top-bar.scss` | the top bar over upstream's panel, in the user session and the overview. Its text sizes are in pt (`apex-text-size`), so Large Text grows the text and nothing else: the bar, the pills and the glyphs keep SPEC's px sizes, where upstream sizes the bar in em. The unread-notification dot is `$apex_bar_fg` until S1b brings the wallpaper SPEC's accent dot was drawn over; over Fedora's wallpaper the light bar hides an accent dot. G2 asserts both ([tests/shots](../tests/shots/README.md)) |
| `data/theme/apex/diamond-{light,dark}.svg` | the Apex diamond in the Activities pill, stroked in each variant's `$apex_bar_fg` |
| `data/theme/apex/_popup-menus.scss` | stock popup menus (board 16): solid `$apex_panel_solid`, radius 14, 34 px rows, the board's inset ring as a 1 px border and its first shadow (St draws one). The calendar and Quick Settings popovers take it too until their own partials |
| `data/theme/apex/_osd.scss` | the OSD (board 16): a 40 px pill tinted `$apex_panel`, its level 180 × 6 in the accent, 104 px above the screen's bottom edge |
| `data/theme/apex/_notification-banner.scss` | the notification banner (board 16) on stock structure: 460 px, tinted `$apex_panel`, 12 px below the bar. Stock shows the action buttons only once a banner expands; they are the board's 32 px pills. The OSD and the banner are glass: the tint now, S2b's glass manager blurs behind it |
| `data/theme/apex/_quick-settings.scss` | Quick Settings and its stock submenus (board 17): a 376 px glass panel, radius 26, 14 px inset; 36 px round buttons and battery pill; 54 px toggles, the accent when checked, the menu arrow shaded 12 % with black; accent sliders with a white 20 px handle; submenus as `$apex_card` cards with 38 px rows. BoxPointer's one `-arrow-rise` sets both the 6 px gap under the bar and the side clamp, so the panel sits 6 px from the right edge, not the board's 8 |
| `data/theme/apex/_switcher.scss` | the window and app switcher (board 15): a glass list, radius 26, 14 px inset, tiles 6 px apart with radius 16, the selected tile in `$apex_button_hover`, names at 13.5/600. `altTab.js` sizes the icons (96 px at most) and labels every tile, so the tiles are larger than the board's 120 × 116 with 84 px icons, the window dots and the one name under the list; those need a hook |
| `data/theme/apex/_dialogs.scss` | modal dialogs (boards 13 and 14): solid `$apex_panel_solid`, radius 26, inset 28 (22 at the bottom), 18 px between parts; a 20/700 title over `$apex_fg_dim` text; 36 px round buttons, the default one in the accent; polkit's password entry a 38 px round field with a 2 px accent ring when focused; 440 px polkit and 460 px end-session widths. `dialog.js` keeps its 12 px gap between buttons, and the lightbox its 0.4 dim |
| `data/theme/apex/_date-menu.scss` | the calendar and notifications popover (board 34) on stock structure: glass like Quick Settings, a 400 px list beside a 318 px column 14 px apart; notification cards radius 18 (opaque `$apex_message_card`, since a group stacks its cards), a 40 px footer with a 32 px Clear pill; the weekday over a 20/800 date; the month, events, World Clocks and Weather as `$apex_glass_card` cards; 36 px round days filling seven columns, the accent today, `$apex_fg_faint` other months. Stock keeps the Do Not Disturb switch in Quick Settings, Clear on the left, grouped notifications, the month name between the pagers and its event-dot asset |
| `data/theme/apex/_overview.scss` | the overview (board 35): the `$apex_scrim` tint over everything (S2b's glass manager blurs behind it with `$apex_scrim_blur`), the search field a 440 × 40 `$apex_pill` 20 px under the bar with a 2 px accent focus ring, workspace thumbnails in an unpadded box (`$apex_thumbnails_padding`, so they keep the full .081), radius 8 and 10 px apart in a `$apex_pill_border` ring with the current one in a 2 px accent ring, window titles 28 px pills at 12.5/700; search sections, which have no board until Spotlight, as glass cards. "No open windows" (`.apex-workspace-empty`) at 18/700 in `$apex_fg_dim`. The workspace background cards and always-visible window titles are the `overview` feature's |
| `data/theme/apex/_app-grid.scss` | the launcher (board 36): unfilled app tiles radius 22, padded 12, names at 13/600 in `$apex_fg` 8 px under the icon, `$apex_button` when hovered and an accent ring when focused; folders filled `$apex_folder` (stock fills the whole tile, the board only the icon); the folder dialog 600 px of `$apex_folder_panel` glass, radius 26, a 16/700 title and a 28 px button; 4 px running dots; and flat page hints, without upstream's gradients. `appDisplay.js` sets the grid's columns and icon sizes and the dialog's 720 px height |
| `data/theme/apex/_derived.scss` | stock surfaces with no board, from their nearest board (DESIGN.md): the workspace switcher and resize popup take the OSD's tint, ring and radius, with `$apex_fg_faint` and `$apex_fg` dots; the input method's candidates the popup menu's; the run dialog's entry the password entry; audio device tiles the switcher's; the monitor number the OSD's radius. Glass surfaces take only the tint here: the glass manager registers them for the blur |
| `data/theme/apex/_tile-preview.scss` | the edge-tiling preview (board 22): `$apex_tile_preview_inset` inside the tile mutter gives it (a clear border, since mutter sets its size), radius `$apex_radius_tile_preview`, the accent at `$apex_tile_preview_fill_opacity` ringed `$apex_tile_preview_ring` in the accent at `$apex_tile_preview_ring_opacity` (an inset shadow). The board's blur waits for the glass manager |
| `data/theme/apex/_spotlight.scss` | Spotlight and its toast (board 38): a 680 px glass panel tinted `$apex_panel`, radius 24, 96 px below the monitor's top edge; the 60 px field with 20/500 text and a 20 px glyph; 11.5/700 uppercase section headers; 48 px rows with 32 px icons, 14/600 titles over 12.5 px subtitles, the selected one in the accent at 16 % with its verb and an Enter chip; the calculator's result at 18/700 in tabular figures; the "Copied" toast a 40 px glass pill 92 px above the screen's bottom edge. Both are glass: `popup.js` and `toast.js` register the panel (`spotlight`) and the toast's pill (`toast`) with `glass/registry.js`, and `_glass.scss` gives them `$apex_spotlight_blur` and `$apex_spotlight_saturation` (σ 34, 1.8) and `$apex_toast_blur` and `$apex_toast_saturation` (σ 30, 1.8, ADR 0014's toast row), `$apex_panel_solid` under Reduce Transparency |
| `data/theme/apex/_greeter.scss` | the greeter (board 12) beyond `_lock.scss`: the login dialog over apex-desktop's pre-blurred Facets (`$apex_greeter_background`, rendered at build time since gdm runs no JS), `$apex_greeter_fallback` without the file; the footer is apex-desktop's `org.gnome.login-screen logo`, `$apex_greeter_bottom` above the bottom edge; the back button and the bottom row's session and accessibility buttons are 38 px `$apex_greeter_button` circles ringed in `$apex_greeter_button_border`. Stock lacks the board's "Choose a user" heading, the rows' account type and chevron, the avatars' initials (the lock's JS) and the clock on the left; each needs JS gdm does not run |
| `data/theme/apex/_screenshot.scss` | the screenshot UI (board 19), tints only (the panel's glass comes with 0017-derived-glass): a 440 px `$apex_panel` panel, radius 26, inset 14, 48 px above the bottom edge, with the board's heading row kept for the close button (a 30 px `$apex_button` circle); 64 px area buttons in `$apex_button` (`$apex_button_hover` checked), radius 16, a 20 px glyph over a 12.5/600 name; a 38 px pointer toggle, the accent when on; a 64 px capture button, a 4 px `$apex_fg` ring round a `$apex_fg` dot (a 26 px `$apex_screenshot_record` square while recording); the screenshot/screencast switch in `$apex_button`, the checked button `$apex_panel_solid`; the selection shaded `$apex_screenshot_shade` with 14 px white handles; the chosen screen and window ringed 3 px in the accent. Stock lacks the board's heading text, its 8 px gap between the area buttons (12 px, set in JS), the pointer toggle on the left and the switch on the right (swapped, set in JS), the selection's size label, and the window selector's windows in place (stock lays them out); each needs a hook |
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

`FEATURES_IN_ENABLE_ORDER` in `layer.js` lists `spotlight` (S1b), `panel` (S2a), `glass`
(S2b), `dock` (S2a) and `overview` (S3a), by the names DESIGN's `disabled-features` uses.
`spotlight`
registers `toggle-spotlight` from `io.github.apex_linux.Apex.Desktop.Keybindings`
(`['<Super>space']`) with `Main.wm.addKeybinding` at enable, in the normal and overview
action modes and without autorepeat, and removes it at disable. A press opens Spotlight
(board 38, DESIGN's Spotlight rules), a modal popup in the popup action mode; Esc, a click
outside or Super+Space again close it. Upstream allows the Super tap only in the normal and
overview modes, so it does nothing while Spotlight is open (no hook); with Spotlight closed
it opens the overview as before.
apex-desktop's override moves `switch-input-source` to Super+Alt+Space, so nothing else
owns Super+Space; a Super tap (the overview) and Super+A (the launcher) are upstream's.

Spotlight draws its own rows over the stock search providers: upstream's app search
(`AppSearchProvider`), then the remote providers `remoteSearch.js` loads, of which it keeps
gnome-calculator, gnome-control-center and nautilus. The sections and caps are Calculator 1,
Applications 4, Settings 3 and Files 4, in that order. Sections show as their providers
answer, each in its place; each provider has 1 s per query, and one past it is cancelled and
left out of that query. The selection is the first row until Up, Down or the pointer moves it;
after that an arriving section never moves it. A sum puts Calculator first among the
applications, whichever answers first. Up and Down move one selection across the
sections, Enter activates it through its provider, and Enter on the calculator's result
copies it, closes Spotlight and shows the "Copied" toast above the dock for 2 s. An empty
query shows only the field; a query with no results says so. The feature follows the kill
switches and `disabled-features` like any other; a missing Keybindings child schema, or one
without `toggle-spotlight`, turns off only this feature, logged once. It adds no hook.

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

`panel/solid-bar.js` makes the bar solid while `translucent-top-bar` is off (live), or while
a window on the primary monitor's active workspace is maximised, showing and not the
desktop, and the overview is closed. It follows restacking, size changes, minimising,
the workspace and the overview. The panel then carries the style class `apex-solid-bar`,
which `_top-bar.scss` draws as `$apex_bar_solid` over a `0 1px 0 $apex_border` line; the
lock screen and the greeter keep their transparent panel. A schema without the key turns
off the `panel` feature, logged.

`panel/focused-app.js` adds an item after the Activities pill (status-area role `apex-focused-app`):
the name of `Shell.WindowTracker`'s focus app, or "Desktop" while nothing has focus, at
`$apex_font_bar_emphasis_weight` and padded `$apex_bar_app_name_padding`. It takes no
clicks, and `show-focused-app-name` (live) and the lock screen hide it. A schema without
the key turns off the `panel` feature, logged.

`panel/search-button.js` adds a pill just before the status pill (role `apex-search`), named
"Search (Super+Space)", `$apex_bar_search_width` wide with the 16 px search glyph. A click
does what Super+Space does (`toggleSpotlight()` of `spotlight`): it opens or closes
Spotlight. With `spotlight` in `disabled-features` it opens the overview with its search
entry focused, or, while the overview is up, hides it. The lock screen hides it; keyboard focus reaches it, but
Super+Space is its key. Hovered, it shows the tooltip "Search (Super+Space)" below it, a
`dash-label` in the chrome, as the dash's labels are.

`panel/search-hint.js` posts "Press Super+Space to search" once per user (ROADMAP S1b), as
a stock transient notification, at the first enable of the panel outside the lock screen,
and sets `search-hint-shown`. A schema without that key means no hint, logged once; the
rest of the panel runs.

`motion/feature.js` gives the shell DESIGN's one curve, `cubic-bezier(.2,.8,.2,1)`
(ROADMAP S3c). Every ease passes through `environment.js`, where patch 0016's `ease` hook
turns a curved mode (any but linear and stepped, and an actor's default EASE_OUT_CUBIC)
into Clutter's `CUBIC_BEZIER`, and its `eased` hook sets the transitions' control points to
(.2, .8) and (.2, 1). Its `motion-duration` hook, at the call sites, gives each role
DESIGN's duration: `window` (the size change's two eases) .3 s, `overview` (the overview's
state transitions in and out and to and from the app grid) .2 s, `popover` (a BoxPointer
opening and closing) .18 s. The dock's .38 s is the dock's. `adjustAnimationTime` runs
after the hooks, so `enable-animations=false` keeps stock's 0 ms.

`quick-settings/feature.js` follows DESIGN's Quick Settings (ROADMAP S3c) once patch 0011's
`quick-settings` hook says the items are in the grid. It moves the VPN toggle right after
Airplane Mode, the end of DESIGN's order (Wi-Fi, Bluetooth, Power Mode, Night Light, Dark
Style, Do Not Disturb, Airplane Mode, VPN). It lights Power Mode at every profile with the
`apex-lit` class, which `_quick-settings.scss` styles as `:checked`; the toggle's `checked`
stays stock, so a click still switches between Balanced and the last profile, and the
status pill keeps the power-profile indicator out (`panel/status-pill.js`). A toggle with no
subtitle of its own reads "On" or "Off" from `checked`; one that sets its own (Wi-Fi's
network, Bluetooth's device, Power Mode's profile) keeps it, and gets ours back once it
drops it. Disabled, the feature puts VPN back, unlights Power Mode and clears only the
subtitles it wrote.

`glass` is ADR 0014's glass manager, on patch 0003's `ShellBlurEffect`. A surface is any
actor in `glass/registry.js`: the top bar, Quick Settings, the calendar and each banner
(`glass/surfaces.js`), and whatever another feature registers, for example the dock:

```js
import * as Glass from '../glass/registry.js';
Glass.register(actor, {name: 'dock'});
Glass.unregister(actor);
```

`register()` again replaces an actor's opts; `unregister()` is idempotent, and the
registry drops an actor on its `destroy`. The shape is the `shadows` registry's (S3c).

The registry needs no running manager, so a feature registers once and its glass follows
`disabled-features` and the switches below. The actor's sheet says how much glass:
`-apex-glass-blur` (ADR 0014's sigma, a token in CSS px) and `-apex-glass-saturation`, as
`_glass.scss` sets them for the layer's own surfaces; its `border-radius` gives the corners.
An actor without `-apex-glass-blur` gets no blur. The manager then:

- adds a background-mode `Shell.BlurEffect` with `fine` and `follow-opacity`, radius
  2 × sigma × the actor's resource scale (ClutterBlur's sigma is half the radius, in device
  pixels), the saturation and the corner radius. `register()` takes `mode: 'actor'` for the
  scrims of S3a and `paused()` with `pausedChanged` for a pause rule of its own;
- pauses a surface's blur while it is unmapped (a closed popover, a hidden dock, chrome
  under a fullscreen window) and the bar's while the panel carries `apex-solid-bar`;
- holds the offscreen redirects of the surface and its ancestors off while it blurs (the
  panel's, BoxPointer's and the dash's are `ALWAYS`), since a background blur inside one
  blits the offscreen layer, not the stage, and gives each back;
- forwards damage, for latency only: a window actor's `damaged`, its moves and resizes
  (old and new box), restacking and background changes redraw each glass box they touch,
  so the re-blur lands in the same frame. A missed source costs one frame, through 0003's
  redraw-clip rule;
- for `reduce-transparency` or high contrast, removes every blur and adds `apex-solid` to
  `Main.uiGroup`, under which `_glass.scss` swaps the glass tints for `$apex_bar_solid` and
  `$apex_panel_solid` (the high-contrast sheet keeps upstream's colours). With
  `disabled-features=['glass']` the effects go and the tints stay.

A schema without `reduce-transparency` turns off the `glass` feature, logged.

`dock` is the dock (DESIGN.md, "Dock"; board 37). `dock/dock.js`'s ApexDock is upstream's
`Dash` (`js/ui/dash.js`) with the hooks of patch 0014-dash, which the feature provides:

- the apps (favourites, then running ones, with upstream's separator between them turned
  off), then the dock's own separator, a full-colour Show Apps tile (`view-app-grid`,
  falling back to the symbolic icon) and Trash (`dock/trash.js`: a click opens
  `trash:///`, its menu opens or empties it);
- every icon at `dock-icon-size`'s 46, 54 or 62 px, where upstream fits the icons to the
  overview's width; Trash follows `dock-show-trash` and the running dots
  `dock-running-indicators`; every key live;
- each icon lifted 6 px over 180 ms while hovered, its label above it;
- in the chrome, centred `$apex_dock_bottom_gap` above the primary monitor's bottom edge,
  with no strut, hidden under fullscreen windows and on the lock screen;
- in the overview too, whose own dash is hidden at the dock's height plus its gap, so the
  overview lays its views out above the dock; the dock's Show Apps opens the app grid,
  and the overview's Show Apps button and the dock's follow each other;
- Ctrl+Alt+Tab reaches it, as upstream's `Dash` registers itself there.

A schema without one of the keys turns off only this feature, logged.

`overview` is the overview and the launcher (ROADMAP S3a, without Spotlight, the launcher's
own search pill or the glass). Its parts provide the hooks of patch 0013-overview and follow
the kill switches and `disabled-features=['overview']` as a whole:

- `overview/window-titles.js`: every window preview shows its title; hovering fades in only
  the close button.
- `overview/workspaces.js`: no wallpaper card behind a workspace's windows, which sit on the
  scrim, and "No open windows" (`.apex-workspace-empty`) centred on a workspace without
  any, fading in with the overview.
- `overview/thumbnails.js`: workspace thumbnails at scale .081 of the work area, board 35's 70 px
  tall (117 × 70 on a 1440 × 900 screen), shown from two workspaces, where stock shows them from three at .05.
- `overview/launcher.js`: the launcher's grid at 7 columns of 88 px icons, 4 rows a page.

The overview builds its window previews and workspaces each time it opens, so the first
two take effect from the next opening; the thumbnails and the launcher change at once.

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
the top bar's hooks with stub dots, indicators and hot corners, and the dock's keys,
order, Show Apps binding and hooks against a stub `Dash`, against
`tests/layer/main-stub.js` for `main.js`, fixture typelibs for Meta and Shell, and
`tests/layer/stubs/` for `panelMenu.js`, `dash.js`, `iconGrid.js`, `popupMenu.js` and the features' St, Clutter and Shell imports
(gjs outside the shell has no St or Clutter, and the fixture's Shell no WindowTracker).

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

