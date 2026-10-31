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
| `js/ui/apex/lock/` | the lock screen of S3b (board 20), the `lock` feature: `stage.js` (the single stage: date over time over the prompt and its hint, the overlay, the prompt torn down while `org.gnome.Mutter.DisplayConfig`'s `PowerSaveMode` blanks the screen and rebuilt on wake), `background.js` (the blur, σ 30 and saturation 1.3, without upstream's darkening), `question.js` ("Enter Password" for PAM's exact `Password:` only), `fingerprint.js` (board 20's fingerprint states in the hint's line: "Or touch the fingerprint reader" with the print glyph while GDM's `gdm-fingerprint` conversation prompts, "Fingerprint not recognized. Try again." after a failed scan, upstream's message line and "Unlock with fingerprint" indicator standing aside for those states only; driven by the conversation, so it shows nothing until the image turns fingerprint on) and `avatar.js` (the name's initial in place of the generic icon), through patch 0015's hooks. Unlocking stays upstream's: no Apex code is on its path, which `tests/layer/run.sh`'s unlock guard checks. Stock keeps, until S4: the show-password eye and the chevron button; and the password's failure text on a message line above the hint, where the board puts it in the hint's place with a red ring |
| `js/ui/apex/motion/feature.js` | DESIGN's motion (below): one curve and fixed durations through patch 0016's hooks |
| `js/ui/apex/spotlight/` | Spotlight (below): `feature.js` (Super+Space), `search.js` (the sections, caps and budget), `providers.js` (the stock providers), `popup.js`, `toast.js`, and `tiles.js` with `settings-tiles.json`, the Settings tile colours by panel id. That JSON mirrors gnome-control-center's `panels/apex/settings-tiles.json` byte for byte and is the one file here without an SPDX line, since JSON has no comments |
| `js/ui/apex/quick-settings/feature.js`, `submenu.js` | DESIGN's Quick Settings (below): VPN after Airplane Mode, Power Mode lit, On/Off subtitles, and board 17's submenus, through patch 0011's hooks |
| `js/ui/apex/shadows/feature.js`, `registry.js`, `cutout.js` | DESIGN's second shadow layer (below): a shadow-layer actor under each surface whose sheet names `-apex-shadow-layer`, cut out under the surface, and the window previews' two layers |
| `js/ui/apex/notifications/feature.js` | DESIGN's notifications in the calendar (below): one flat card per notification, "app · time" headers, the app's icon as a fallback, Do Not Disturb and Clear in the footer, through patch 0012's hooks |
| `js/ui/apex/end-session/feature.js`, `card.js`, `update.js` | DESIGN's end-session dialog (board 14, below): stock's icon in a circle, Restart in the power-off dialog, the theme's gap and widths for the buttons, and the update card over Update1, through patch 0018's hook |
| `js/ui/apex/polkit/` | board 13's authentication dialog (below), through patch 0017's hook: `header.js` the shield and the user's role, `fingerprint.js` the fingerprint line, `details.js` Details |
| `js/ui/apex/panel/feature.js` | the top bar of S2a (below): its parts in `panel/`, one module each |
| `js/ui/apex/glass/feature.js` | the glass manager of S2b (below), with `glass/surfaces.js`, the layer's own glass, and `glass/registry.js`, where any feature registers an actor |
| `js/ui/apex/dock/feature.js`, `dock.js`, `trash.js`, `intellihide.js` | the dock of S2a (below): ApexDock, a subclass of upstream's `Dash`, its Trash and its intellihide |
| `js/ui/apex/windows.js` | whether a window on the primary monitor is maximised, and the signals that change it: the solid bar and the dock's intellihide |
| `js/ui/apex/indicators/` | the app indicators of S2a (below): `watcher.js` (the StatusNotifierWatcher and host), `item.js`, `icon.js` and `mask.js` (the glyph), `dbusmenu.js` (the menus), `indicator.js` (one button) and `bar.js` (their place and the overflow) |
| `js/ui/apex/fault/feature.js` | the fault-injection feature: loaded only when `APEX_SHELL_TEST_FAULT` names a phase, it fails in that phase (below) |
| `data/theme/apex/_apex-tokens.scss` | the design tokens as SCSS variables, imported after upstream's `_colors` |
| `data/theme/apex/_apex.scss` | the Apex sheet, imported last by the light and dark entry files: its marker, `_apex-base.scss` and the partials |
| `data/theme/apex/_glass.scss` | each glass surface's `-apex-glass-blur` and `-apex-glass-saturation`, from the tokens of ADR 0014's table, and the solid tints under `.apex-solid` |
| `data/theme/apex/_top-bar.scss` | the top bar over upstream's panel, in the user session and the overview. Its text sizes are in pt (`apex-text-size`), so Large Text grows the text and nothing else: the bar, the pills and the glyphs keep SPEC's px sizes, where upstream sizes the bar in em. The unread-notification dot is `$apex_bar_fg` until S1b brings the wallpaper SPEC's accent dot was drawn over; over Fedora's wallpaper the light bar hides an accent dot. G2 asserts both ([tests/shots](../tests/shots/README.md)) |
| `data/theme/apex/diamond-{light,dark}.svg` | the Apex diamond in the Activities pill, stroked in each variant's `$apex_bar_fg` |
| `data/theme/apex/_popup-menus.scss` | stock popup menus (board 16): solid `$apex_panel_solid`, radius 14, 34 px rows, the board's inset ring as a 1 px border and its first shadow (St draws one). The calendar and Quick Settings popovers take it too until their own partials |
| `data/theme/apex/_osd.scss` | the OSD (board 16): a 40 px pill tinted `$apex_panel`, its level 180 × 6 in the accent, 104 px above the screen's bottom edge |
| `data/theme/apex/_notification-banner.scss` | the notification banner (board 16) on stock structure: 460 px, tinted `$apex_panel`, 12 px below the bar. Stock shows the action buttons only once a banner expands; they are the board's 32 px pills. The OSD and the banner are glass: `glass/derived.js` registers the OSD and `glass/surfaces.js` the banner, and the glass manager blurs behind the tint |
| `data/theme/apex/_quick-settings.scss` | Quick Settings and its stock submenus (board 17): a 376 px glass panel (its width in pt, so Large Text widens it instead of cutting titles short), radius 26, 14 px inset; 36 px round buttons and battery pill; 54 px toggles, the accent shaded 25 % with black when checked (white at 4.5:1 or more on all nine accents, the subtitle at .92), the menu arrow 12 % darker still; accent sliders with a white 20 px handle; submenus as `$apex_card` cards with 38 px rows. BoxPointer's one `-arrow-rise` sets both the 6 px gap under the bar and the side clamp, so the panel sits 6 px from the right edge, not the board's 8 Submenu rows hover in board 17's lighter `$apex_quick_menu_row_hover` (popup menus elsewhere keep `$apex_button_hover`),. |
| `data/theme/apex/_switcher.scss` | the window and app switcher (board 15): a glass list, radius 26, 14 px inset, tiles 6 px apart with radius 16, the selected tile in `$apex_button_hover`, names at 13.5/600. `altTab.js` sizes the icons (96 px at most) and labels every tile, so the tiles are larger than the board's 120 × 116 with 84 px icons, the window dots and the one name under the list; those need a hook |
| `data/theme/apex/_dialogs.scss` | modal dialogs (boards 13 and 14): solid `$apex_panel_solid`, radius 26, inset 28 (22 at the bottom), 18 px between parts; a 20/700 title over `$apex_fg_dim` text; 36 px round buttons, the default one in the accent; polkit's password entry a 38 px round field with a 2 px accent ring when focused; 440 px polkit and 460 px end-session widths. The end-session dialog puts 20 px between its parts, tracks its title -.2px, sets its countdown in tabular figures and draws its last button, the one that ends the session, in Adwaita red #c01c28 (#a51d2d hovered); the end-session feature's 56 px icon circle and its power-off row, 10 px apart at 1 : 1.4 : 1.2. Board 13's parts under `.apex-polkit`: a 56 px accent circle at 16 % behind the 28 px shield, a 32 px accent avatar beside the name with "Administrator" at 11.5 px in `$apex_fg_dim`, the fingerprint line at 12.5 px in `$apex_fg_dim` with a 16 px glyph, and Details in a 1 px `$apex_border` box of radius 12 with a 38 px heading and the action id in JetBrains Mono at 11.5 px. Elsewhere `dialog.js` keeps its 12 px gap between buttons, and the lightbox its 0.4 dim |
| `data/theme/apex/_date-menu.scss` | the calendar and notifications popover (board 34) on stock structure: glass like Quick Settings (`glass/surfaces.js` registers it), a 400 px list beside a 318 px column 14 px apart; notification cards radius 18 (opaque `$apex_message_card`, since a group stacks its cards), a 40 px footer with a 32 px Clear pill; the weekday over a 20/800 date; the month, events, World Clocks and Weather as `$apex_glass_card` cards; 36 px round days filling seven columns, today in a checked Quick Settings toggle's shade of the accent, `$apex_calendar_other_month` other months. The notifications feature puts Do Not Disturb on the footer's left and Clear on its right (shown, faded, with nothing to clear), lays a group's cards out flat, puts the month on the left with both pagers on the right and draws accent event dots in place of stock's asset; without it, stock's |
| `data/theme/apex/_overview.scss` | the overview (board 35): the `$apex_scrim` tint over everything (over each monitor's scrim, which `glass/scrims.js` blurs at `$apex_overview_scrim_blur`, or `$apex_launcher_scrim_blur` in the launcher), the search field a 440 × 40 `$apex_pill` 20 px under the bar with a 2 px accent focus ring, workspace thumbnails in an unpadded box (`$apex_thumbnails_padding`, so they keep the full .081), radius 8 and 10 px apart in a `$apex_pill_border` ring with the current one in a 2 px accent ring, window titles 28 px pills at 12.5/700; search sections, which have no board until Spotlight, as glass cards. "No open windows" (`.apex-workspace-empty`) at 18/700 in `$apex_fg_dim`. The workspace background cards and always-visible window titles are the `overview` feature's |
| `data/theme/apex/_app-grid.scss` | the launcher (board 36): unfilled app tiles radius 22, padded 12, names at 13/600 in `$apex_fg` 8 px under the icon, `$apex_button` when hovered and an accent ring when focused; folders filled `$apex_folder` (stock fills the whole tile, the board only the icon); the folder dialog 600 px of `$apex_folder_panel` glass, radius 26, a 16/700 title and a 28 px button; 4 px running dots; and flat page hints, without upstream's gradients. `appDisplay.js` sets the grid's columns and icon sizes and the dialog's 720 px height |
| `data/theme/apex/_derived.scss` | stock surfaces with no board, from their nearest board (DESIGN.md): the workspace switcher and resize popup take the OSD's tint, ring and radius, with `$apex_fg_faint` and `$apex_fg` dots; the input method's candidates the popup menu's; the run dialog's entry the password entry; audio device tiles the switcher's; the monitor number the OSD's radius. Glass surfaces take only the tint here: the glass manager registers them for the blur |
| `data/theme/apex/_tile-preview.scss` | the edge-tiling preview (board 22): `$apex_tile_preview_inset` inside the tile mutter gives it (a clear border, since mutter sets its size), radius `$apex_radius_tile_preview`, the accent at `$apex_tile_preview_fill_opacity` ringed `$apex_tile_preview_ring` in the accent at `$apex_tile_preview_ring_opacity` (an inset shadow). With glass, a glass actor `glass/derived.js` keeps just below the preview on the inner rect draws the board's blur, `$apex_tile_preview_blur` at `$apex_tile_preview_saturation`, the fill and the ring as a border, even round its corners; the preview, classed `apex-tile-preview-glassed`, draws nothing. Reduce Transparency and high contrast drop only the blur. With `glass` in `disabled-features` the preview's own fill and inset-shadow ring come back, the ring a little thicker at the corners: St cuts the shadow's hole at the radius of the clear border |
| `data/theme/apex/_spotlight.scss` | Spotlight and its toast (board 38): a 680 px glass panel tinted `$apex_panel`, radius 24, 96 px below the monitor's top edge; the 60 px field with 20/500 text and a 20 px glyph; 11.5/700 uppercase section headers; 48 px rows with 32 px icons, 14/600 titles over 12.5 px subtitles, the selected one in the accent at 16 % with its verb and an Enter chip; the calculator's result at 18/700 in tabular figures; the "Copied" toast a 40 px glass pill 92 px above the screen's bottom edge. Both are glass: `popup.js` and `toast.js` register the panel (`spotlight`) and the toast's pill (`toast`) with `glass/registry.js`, and `_glass.scss` gives them `$apex_spotlight_blur` and `$apex_spotlight_saturation` (σ 34, 1.8) and `$apex_toast_blur` and `$apex_toast_saturation` (σ 30, 1.8, ADR 0014's toast row), `$apex_panel_solid` under Reduce Transparency |
| `data/theme/apex/_lock.scss` | the lock screen (board 20) and what the greeter (board 12) shares with it, white on the blurred wallpaper in both variants: the date at 22/600 over the time at 118/700, 128 px down; the 92 px avatar circle and its initial; the 250 × 38 glass field with its 38 px round button beside it; "Press Enter to unlock" at 12.5 px, and in its line the fingerprint states with a 16 px print glyph 8 px before the text, the failure in full white; the `$apex_lock_overlay` darkening; the greeter's 380 px glass user list with 48 px avatars |
| `data/theme/apex/_greeter.scss` | the greeter (board 12) beyond `_lock.scss`: the login dialog over apex-desktop's pre-blurred Facets (`$apex_greeter_background`, rendered at build time since gdm runs no JS), `$apex_greeter_fallback` without the file; the footer is apex-desktop's `org.gnome.login-screen logo`, `$apex_greeter_bottom` above the bottom edge; the back button and the bottom row's session and accessibility buttons are 38 px `$apex_greeter_button` circles ringed in `$apex_greeter_button_border`. Stock lacks the board's "Choose a user" heading, the rows' account type and chevron, the avatars' initials (the lock's JS) and the clock on the left; each needs JS gdm does not run |
| `data/theme/apex/_screenshot.scss` | the screenshot UI (board 19): glass, which `glass/derived.js` registers; a 440 px `$apex_panel` panel, radius 26, inset 14, 48 px above the bottom edge, with the board's heading row kept for the close button (a 30 px `$apex_button` circle); 64 px area buttons in `$apex_button` (`$apex_button_hover` checked), radius 16, a 20 px glyph over a 12.5/600 name; a 38 px pointer toggle, the accent when on; a 64 px capture button, a 4 px `$apex_fg` ring round a `$apex_fg` dot (a 26 px `$apex_screenshot_record` square while recording); the screenshot/screencast switch in `$apex_button`, the checked button `$apex_panel_solid`; the selection shaded `$apex_screenshot_shade` with 14 px white handles; the chosen screen and window ringed 3 px in the accent. Stock lacks the board's heading text, its 8 px gap between the area buttons (12 px, set in JS), the pointer toggle on the left and the switch on the right (swapped, set in JS), the selection's size label, and the window selector's windows in place (stock lays them out); each needs a hook |
| `data/theme/apex/_indicators.scss` | the app indicators (board 39): 30 × 24 pills, radius 12, 2 px apart, their 16 px glyphs in `$apex_bar_fg`; the 6 px accent dot 3 px from the top and 5 px from the right; the 1 × 14 divider in `$apex_bar_fg` at .2, 6 px each side; "‹ +N"; an open one in `$apex_button_hover`. Their menus at least 280 px (the overflow's 240), rows padded 12 with radius 9, the title as a 30 px header in `$apex_fg_dim`, separators 5 px from rows and 10 from the sides, shortcuts in `$apex_fg_dim`, 30 × 18 switches with a 14 px knob |
| `data/theme/apex/_apex-structure.scss` | the high-contrast sheet's Apex part: the tokens with upstream's high-contrast palette mapped onto them, then the Apex-only partials (Spotlight and its toast, the dock, the end-session icon), solid; and the lock overlay's darkening there (black at .55), since the lock's blur leaves that to it |
| `data/theme/apex/_apex-base.scss`, `_end-session-icon.scss` | what both sheets share: `apex-text-size()`, the `apex-surface()` and `apex-reset` mixins; the end-session icon's circle |
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

`FEATURES_IN_ENABLE_ORDER` in `layer.js` lists `motion` (S3c), `shadows` (S3c), `spotlight`
(S1b), `panel` (S2a), `glass` (S2b), `dock` (S2a), `overview` (S3a), `lock` (S3b),
`quick-settings` (S3c), `end-session` (S3c) and `indicators` (S2a), by the names DESIGN's
`disabled-features` uses.
A name in `disabled-features` that is no feature is logged once (`Apex: disabled-features
names no feature NAME`); a schema whose key lists `<choices>` refuses it outright.
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

DESIGN's one engine: text typed in the overview, or its search pill taking the key focus,
opens Spotlight with that text through patch 0013's `overview-search` hook, and the overview's
own search resets; activating a result hides the overview. With `spotlight` off the hook gives
stock, and the overview searches as upstream does.

While the app grid shows, the same pill is the launcher's own (board 36, `launcher-search.js`):
400 px wide with "Search apps", it searches apps only, through `Shell.AppSystem.search`, folders
flattened and sorted by name, and filters the grid in place: the grid's own box shows the
matching apps' icons, the first selected, and Enter launches it. Without a match it says "No
Results" and that Super+Space searches everything. The hook keeps typed text from the stock
search there and leaves the focus stock; leaving the app grid gives the stock pill and grid
back. With `spotlight` off the app grid searches as upstream does.

Spotlight draws its own rows over the stock search providers: upstream's app search
(`AppSearchProvider`), then the remote providers `remoteSearch.js` loads, of which it keeps
gnome-calculator, gnome-control-center and nautilus. The sections and caps are Calculator 1,
Applications 4, Settings 3 and Files 4, in that order. Sections show as their providers
answer, each in its place; each provider has 1 s per query, and one past it is cancelled and
left out of that query. The selection is the first row until Up, Down or the pointer moves it;
after that an arriving section never moves it. A sum puts Calculator first among the
applications, whichever answers first. Settings rows draw the provider's symbolic icon on a 32 px tile
in the panel's colour from `settings-tiles.json`, the same table as the Settings sidebar's
tiles: System's search-only pages take System's, Apex Desktop the accent, and a panel
without a colour a neutral tile. Up and Down move one selection across the
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
- `panel/privacy-group.js`, from `status-pill.js`'s hook: board 39's privacy group. The
  remote-access, camera, microphone and location indicators move into one
  `apex-privacy-group` box at the start of the status pill, a `$apex_privacy_height`
  `$apex_privacy` pill (radius `$apex_radius_privacy`, padded `$apex_privacy_padding`) with
  `$apex_privacy_icon_size` glyphs in `$apex_privacy_fg`, `$apex_privacy_gap` apart. It shows
  only while one of them does, and then the status pill starts `$apex_bar_pill_padding_privacy`
  in instead of `$apex_bar_pill_padding` (`apex-privacy-in-use`).
- `panel/screen-pills.js`: stock's screen-recording and screen-sharing buttons become board 39's
  pills, each with a `$apex_screen_stop_size` white square (radius `$apex_radius_screen_stop`) in
  place of its stop glyph. The recording's square leads its timer, set at
  `$apex_font_recording_size`/`$apex_font_recording_weight` in tabular figures on
  `$apex_recording`. Sharing's follows its `$apex_sharing_icon_size` glyph on `$apex_privacy`, and
  its button, named "Stop screen sharing", moves right before the status pill, again after each
  session-mode change, since panel.js then re-adds its items in stock order. Both keep their
  clicks, so the shell keeps a control that stops a share.
- `panel/input-chip.js`: the input source's short names in capitals ("EN", "VI"), however
  keyboard.js sets them. `_top-bar.scss` draws the chip at
  `$apex_font_input_chip_size`/`$apex_font_input_chip_weight`, tracked
  `$apex_font_input_chip_tracking`, at least `$apex_input_chip_min_width` wide; stock shows it
  only with two or more sources.
- `panel/clear-sync.js`: the date menu's Clear follows its placeholder from the start. calendar.js
  binds the two without `SYNC_CREATE` (51.0 and 51.1), so an empty list showed Clear until a first
  notification came and went. The part syncs it once on enable, and on disable gives back stock's
  value unless stock's binding has synced it since. It is the panel's, not the notifications', so
  the fix holds with `notifications` in disabled-features.

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

`panel/search-button.js` adds a pill at the start of the right box (role `apex-search`), after
the app indicators and before the recording, accessibility and input-source buttons (board 39), named
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

`polkit/feature.js` lays out board 13 (ROADMAP S3b) once patch 0017's `polkit-dialog`
hook says the authentication dialog is built. It adds the shield (`dialog-password-symbolic`) above the title, sets the
user beside the avatar, and shows "Administrator" under the name when AccountsService has
the identity as an administrator; upstream labels only root, in the name's place, and root
keeps that. Details, open as on the board, holds the action id and the vendor that polkit's
`enumerate_actions` gives for it; without one the Vendor row stays hidden. The fingerprint
line is upstream's info line, given the print glyph and the hint's style only when its text
is pam_fprintd's prompt, so the line appears only when PAM sends it; its text is PAM's ("Place your finger on the fingerprint reader"),
not the board's "Or touch the fingerprint reader". Nothing in the feature touches the
session, its answers or the dialog's `done`, which the layer tests' polkit guard enforces.

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

`quick-settings/submenu.js` follows board 17 in the submenus, through 0011's
`quick-settings-toggle-menu` and `quick-settings-network-item` hooks, at the end of each
constructor. A submenu header's subtitle moves to the end of the title's row. A Wi-Fi
network's row is `:checked` while its network is active, from the start (stock's
`_isActiveChanged` runs only on a change), and its lock moves from the signal icon's box to
after the name, styled `apex-network-lock` (`$apex_quick_menu_lock_size` in `$apex_fg` at
`$apex_quick_menu_lock_opacity`). Menus and rows built before the feature enabled are found
in Quick Settings' tree. Disabled, every row and header goes back as stock built it.

`end-session/feature.js` follows board 14 once patch 0018's `end-session-buttons` hook says
the dialog has built its buttons, which it does each time it opens. Above the title it puts
stock's own `iconName` for the type (none for Log Out) in a circle. In the power-off dialog
it adds Restart between Cancel and Power Off, through stock's `ConfirmedReboot`; that row
gets the theme's widths, and every row the theme's gap, which `Clutter.BoxLayout` keeps
out of CSS's reach. The countdown stays stock's translated text. Disabled, it takes the
icon and Restart away and gives the row back `dialog.js`'s 12 px and even widths.

In the power-off and restart dialogs (never Log Out) it also offers S2d's update card.
`end-session/update.js` reads apex-updated's Update1 on the system bus with a 900 ms
timeout and never holds the dialog: only a State of `staged` or `ready-for-reboot` with a
staged digest, answered in time, adds `end-session/card.js` under the text. The card shows
the staged version, then the GNOME, Linux and Mesa versions from `GetChanges` once they
arrive, and a switch, on as board 14 draws it; Restart reads "Restart & Update" while it
is on. With `staged` and the switch on, a pressed action first awaits `Apply` with the
staged digest: stock's buttons close the dialog before they confirm, so the feature
overrides that dialog's `close` and `_confirm` while it is open. If `Apply` fails, the
dialog stays open with the error (`PolicyDenied`'s own message, or a generic line), the
countdown stopped and the switch off, and the failed press's confirmation is skipped when
the dialog next closes, so Cancel cancels. The countdown confirms through `_confirm` and
goes ahead whatever `Apply` answers. With the switch off the stage stays locked and boots
nothing; `ready-for-reboot` is already applied, so its switch is on and insensitive. The
overrides go back on close and on disable.

`shadows/feature.js` draws DESIGN's two-layer shadows (ROADMAP S3c) without a hook. St
draws one `box-shadow` per actor, so the sheet gives a surface its first layer and names the
second as `-apex-shadow-layer` (the `apex-shadow-layer` mixin in `_apex-tokens.scss`: popovers,
Quick Settings, the calendar, menus, the banner and dialogs). The feature scans `uiGroup`,
`modalDialogGroup` and the banner bin, and their new children, for such surfaces;
`shadows/registry.js` puts a transparent St widget just above each while it is mapped, with the
layer as its own `box-shadow` and the surface's radius, and keeps it on the surface's box and
opacity through the ancestors' allocation and transform signals. It adds and removes layers
before the next frame, never inside Clutter's or St's walk over the parent's children, and a
closed menu or dialog keeps none, so an idle desktop repaints nothing more. A dialog's layer
goes inside the dialog, just above its box. Painted after the surface, a layer is never in a
glass surface's backdrop, as CSS keeps a `box-shadow` out; St draws it from the whole
silhouette, so `shadows/cutout.js`, a shader effect on each layer, clears it inside the
surface's rounded box, where it would cover the surface. In the overview, each window preview gets the
`apex-window-preview` class and two layers (`$apex_preview_shadow`, `$apex_preview_shadow_2`)
on its window container. `register(actor, {name})` and `unregister(actor)` are the registry's
API for features that draw their own surfaces (the dock, Spotlight): registrations persist
while the feature is off and draw once it is on. Disabled, the feature removes every layer
and the preview class.

`glass` is ADR 0014's glass manager, on patch 0003's `ShellBlurEffect`. A surface is any
actor in `glass/registry.js`: the top bar, Quick Settings, the calendar, each banner and the
scrim (`glass/surfaces.js`, `glass/scrims.js`); DESIGN's derived glass, the OSDs, each Alt+Tab
list and the screenshot panel, which copy the popovers' glass, and board 22's tile preview, a
glass actor below it inside its clear border (`glass/derived.js`, from JS, with no hook); and whatever another feature registers, for example the dock:

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
  `$apex_panel_solid` (the high-contrast sheet keeps upstream's colours, and gives the Apex-only
  actors that palette, solid, through `_apex-structure.scss`). With
  `disabled-features=['glass']` the effects go and the tints stay.

GNOME hides `window_group`, the wallpaper and the windows, while the overview shows, so the
scrim (`glass/scrims.js`) is a non-reactive `Clutter.Clone` of it in an `.apex-glass-scrim`
widget just below `#overviewGroup`, shown with it, blurred in actor mode under the group's
own `$apex_scrim` tint: `$apex_overview_scrim_blur` at `$apex_overview_scrim_saturation`,
and `$apex_launcher_scrim_*` (`.apex-launcher`) while the app grid shows. Actor mode keeps
its result until the clone is damaged, so a still desktop costs one blur per opening. The
bar and the dock over it blur the scrim as drawn. Actor mode does not grow the actor's
paint volume by the blur, so a window's own damage would re-blur only its rectangle and
leave the halo stale: here the damage forwarding above is what keeps the scrim right.

A schema without `reduce-transparency` turns off the `glass` feature, logged.

`notifications/feature.js` follows DESIGN's notification list (ROADMAP S3c; board 34)
through patch 0012's hooks. A notification group lays its cards out one under another (a
vertical `Clutter.BoxLayout` in place of the stacking layout, the cover and header hidden) and
counts as expanded, so a click never asks `MessageView` to expand it. A card's header reads
"app · time" without the 16 px source glyph, and a card without an icon of its own shows the
app's (the source's) in its 32 px column. The footer gets Do Not Disturb on the left, a label
and a switch on `org.gnome.desktop.notifications` `show-banners` (inverted, the setting the
Quick Settings toggle uses), and Clear on the right, shown even with nothing to clear, then
insensitive. Disabled, the feature restores the groups' layout and stack, the headers, the
icons and the footer; a group built while every hook was stock (the layer off) stays stock.

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
  with no strut, hidden under fullscreen windows and on the lock screen; its box reaches
  the edge, so the gap below the dock is its own;
- `dock/intellihide.js`, Hide Behind Maximized Windows (`dock-intellihide`, live): while a
  window on the primary monitor is maximised and the overview is closed, the box slides
  below the screen over 380 ms; a threshold-0 pressure barrier on the bottom edge under
  it reveals it, and it hides again 300 ms after the pointer leaves it, waiting while a
  menu of its own is open;
- in the overview too, whose own dash is hidden at the dock's height plus its gap, so the
  overview lays its views out above the dock; the dock's Show Apps opens the app grid,
  and the overview's Show Apps button and the dock's follow each other;
- Ctrl+Alt+Tab reaches it, as upstream's `Dash` registers itself there;
- each app's menu is stock's `AppMenu`, so "Launch Using Discrete Graphics Card" shows while
  switcheroo-control's `HasDualGpu` is true. With `/apex/pair-mode` off no NVIDIA driver is
  bound, the dGPU has no DRM card and the item is hidden; with the pair, the card's
  `mutter-device-ignore` keeps it from mutter, not from switcheroo-control.

A schema without one of the keys turns off only this feature, logged.

`indicators` is the app indicators (DESIGN.md, "Top bar"; board 39): a StatusNotifierItem
host with DBusMenu menus, and no XEmbed tray. It needs no hook.

- `indicators/watcher.js` owns `org.kde.StatusNotifierWatcher` while nobody else does. It
  takes an item's bus name, or its object path from the sender, as Flatpak apps send it,
  and drops the item when its name leaves the bus. While another process owns the
  watcher, the shell registers `org.kde.StatusNotifierHost-apex-<pid>` with it and follows
  its items; its name request stays queued, so when that watcher leaves, the shell takes
  over and the apps register again.
- `indicators/item.js` reads Title, Status, IconName, IconPixmap, AttentionIconName,
  IconThemePath, ToolTip, ItemIsMenu and Menu, again on each New* signal.
- `indicators/icon.js`: the item's `-symbolic` icon when the theme has one, which St
  recolours; otherwise its icon, from `IconThemePath` too, or its pixmap (ARGB32 to RGBA),
  drawn through `mask.js` as a one-colour mask in the bar's colour.
- `indicators/bar.js` puts them left of the search button after a thin divider, in the
  order the items registered, and hides the lot on the lock screen. `Passive` items are
  hidden and `NeedsAttention` adds the dot. Up to four show; with more, three show and
  "‹ +N" opens a menu with a row (glyph, title, chevron) per hidden item, which opens that
  item's menu under the overflow button.
- `indicators/indicator.js`: primary click calls Activate, or opens the menu when
  ItemIsMenu; secondary click opens the menu (ContextMenu without one); middle click calls
  SecondaryActivate; scrolling calls Scroll (120 a step).
- `indicators/dbusmenu.js` renders the item's menu as a popup menu, titled with the item's
  name: separators, toggles as switches, radio items, shortcuts on the right, submenus,
  hidden and disabled rows. It follows LayoutUpdated and ItemsPropertiesUpdated (label,
  enabled, visible and toggle state in place) and sends AboutToShow and the opened,
  clicked and closed events.

`overview` is the overview and the launcher (ROADMAP S3a, without Spotlight, the launcher's
own search pill or the glass). Its parts provide the hooks of patch 0013-overview and follow
the kill switches and `disabled-features=['overview']` as a whole:

- `overview/window-titles.js`: every window preview shows its title; hovering fades in only
  the close button. The rows leave room for the caption, and the last row's captions end
  `-apex-dock-clearance` (`$apex_dock_bottom_gap`) above the overview's dash, the dock's height.
- `overview/workspaces.js`: no wallpaper card behind a workspace's windows, which sit on the
  scrim, and "No open windows" (`.apex-workspace-empty`) centred on a workspace without
  any, fading in with the overview.
- `overview/thumbnails.js`: workspace thumbnails at scale .081 of the work area, board 35's 70 px
  tall (117 × 70 on a 1440 × 900 screen), shown from two workspaces, where stock shows them from three at .05.
  Each one draws the wallpaper behind its window clones, clipped inside its border at its radius,
  where stock has a flat fill.
- `overview/launcher.js`: the launcher's grid at 7 columns of 88 px icons, 4 rows a page, with
  no workspace strip above it (board 36), so it starts right under the search field.

The overview builds its window previews, workspaces and thumbnails each time it opens, so
titles, workspaces and the thumbnails' wallpaper take effect from the next opening; the
thumbnails' scale and the launcher change at once.

The layer also does what every feature relies on:

- In the user and unlock-dialog modes it gives the session mode the colour scheme
  `'prefer-light'`, so GNOME's `'default'` draws a light shell and Dark Style draws a
  dark one. The gdm mode keeps upstream's `'prefer-dark'`.
- `enable()` creates `$XDG_RUNTIME_DIR/apex-shell-starting` and removes it after 60 s
  or at shutdown, for the crash guard (ADR 0014).
- At logout, as `layout.js` destroys `uiGroup`, it disables every feature while its actors
  are still alive, passing `disable({teardown: true})`. The notifications feature then clears
  the tray's banner timeouts. Otherwise gnome-shell 51's shutdown loop, which runs after
  `uiGroup` has gone, would run them on the destroyed tray.
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
checks that it is Fedora's sheet up to the structure marker, so the Apex part only appends;
a rule that restyles upstream's actors there would need a stock high-contrast copy.

`tests/layer/run.sh` (`just layer-test`, and ci.yml) runs `hooks.js` and `layer.js` in
gjs outside the shell: every kill switch, `apex.safe=1` through a bubblewrap bind over
`/proc/cmdline`, the gdm mode, the three fault phases, the crash guard after an
aborted shell, and Super+Space: its registration and removal through enable, the kill
switches, `layer-enabled` and `disabled-features` cycles and a missing Keybindings schema,
the top bar's hooks with stub dots, indicators and hot corners, and the dock's keys,
order, Show Apps binding and hooks against a stub `Dash`, and the app indicators against
fake items and a fake watcher on each case's own session bus (`dbus-run-session`), against
`tests/layer/main-stub.js` for `main.js`, fixture typelibs for Meta and Shell, and
`tests/layer/stubs/` for `panelMenu.js`, `dash.js`, `iconGrid.js`, `popupMenu.js`, the
indicators' `mask.js` and the features' St, Clutter, Shell and GdkPixbuf imports (gjs
outside the shell has no St or Clutter, and the fixture's Shell no WindowTracker).

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
| C in gnome-control-center, nautilus or ptyxis | `just app-dev PKG build`, then `run`: ninja in an F45 toolbox in the VM, `bootc usroverlay` | 5 s (ptyxis) to 50 s (gnome-control-center), and under 1 s to install |
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

#### C in the apps: `just app-dev`

`just app-dev PKG` (in apex-image, [#123](https://github.com/apex-linux/apex-image/pull/123))
runs the same loop as `just shell-c` for gnome-control-center, nautilus and ptyxis, one
recipe per step:

```bash
just app-dev ptyxis fetch   # the Apex SRPM of the build the VM runs; uses the builder VM
just app-dev ptyxis push    # sends it to /var/lib/apex-app-dev/ptyxis in the VM
just app-dev ptyxis build   # log in to GNOME in the VM window first
just app-dev ptyxis run     # stops a running ptyxis and starts the new one
```

`build` works as the user logged in to GNOME, in an F45 toolbox called `apex-app-dev`:
`rpmbuild -rc` once per SRPM, then each time `ninja`, `meson install --destdir`, and the
install unpacked over `/usr` after `bootc usroverlay`. The tree is
`~/apex-app-dev/PKG/BUILD/` in the VM; edit it there and build again. `build` refuses an
SRPM of another build than the one the VM runs, and `fetch` refuses a lock that ships
Fedora's own package.

| Package | `rpmbuild -rc` once | `ninja` after one Apex `.c` | install |
|---|---|---|---|
| gnome-control-center | 265 s | 50 s (mostly the LTO relink) | 0.5 s |
| nautilus | 147 s | 42 s | 0.7 s |
| ptyxis | 25 s | 5 s | 0.4 s |

Measured in fedora:45 on 4 CPUs. As with `just shell-c`, a VM reboot drops the build. A
change to keep goes back into the package's `desktop/` files or its series, here.

