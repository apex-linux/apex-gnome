# 0020: no screencast service where the session mode cannot screencast

From `packaging/pkgs/gnome-shell/patches/0020-screencast-greeter.patch` (+3 −1,
`js/ui/screenshot.js`). `0020-screencast-greeter.patch` here is the same code with an
upstream commit message. `git apply --check` passes on gnome-shell main 9a753aa
(2026-10-29).

## What upstream has (2026-10-30)

Nothing. Main's `ScreenshotUI._init` still creates `ScreencastProxy` without flags. Issue
and MR searches for the proxy, the service name, `allowScreencast`, `gst-plugin-scanner`
and the greeter find no report of this. The nearest is #5956, a 2022 hang in
`gst_init_check()` at shell start-up, which is a different bug.

## What to file

An issue and an MR, text below. The MR is `0020-screencast-greeter.patch`.

## Evidence

- **The cost, on Apex's G4 VM** (QEMU, llvmpipe, nested in the builder VM): the greeter's
  screencast service took one core for one to two minutes of each greeter boot, and
  starved the boot assessment. Its systemd unit, on two boots:

  ```
  gdm-greeter:         Consumed 1min 36.226s CPU time over 2min 5.148s wall, 378.8M peak
  gnome-initial-setup: Consumed 1min 5.718s CPU time over 3min 59.361s wall, 109.7M peak
  ```

- **Measured on real hardware** (fedora:45, headless `gnome-shell --mode=gdm`, Apex's
  image package list: 234 GStreamer plugins with libav):
  - Cold home, as the greeter always has: 1.16 s CPU and 161 MB.
  - 72% of perf samples are in the `gst-plugin-scanner` child (`ld.so`, the kernel), which
    loads every plugin to write `registry.x86_64.bin`.
  - Warm home: 0.27 s, all gjs start-up.
- **Why every greeter start is cold**: in GDM 51.1.1 (`gdm-dynamic-user-store.c`) the
  greeter's `HOME` is `/run/gdm/home/<user>`, on tmpfs, and `dynamic_user_free()`
  deletes it. GDM persists only `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, and never sets
  `XDG_CACHE_HOME`.
- **Which modes it affects**: `gdm` leaves `allowScreencast` at the `restrictive`
  default, false. gnome-initial-setup's `initial-setup.json` sets neither `parentMode`
  nor `allowScreencast`, so it gets the same default. `user` sets it true.
- **Apex's regression check**: `tests/shell/check.py`'s screencast checks, defined at
  :44-45 and asserted at :346. The greeter cases fail on dbus's `Activating service
  name='org.gnome.Shell.Screencast'`, and every lock case asserts that the user session
  still starts it. Without 0020 only the two greeter assertions fail; with it, all pass
  (apex-gnome #174).

## Issue text

**Title:** ScreenshotUI starts org.gnome.Shell.Screencast in the greeter and in initial
setup, which cannot screencast

> `main.js` builds `Screenshot.ScreenshotUI()` in every session mode, and its `_init`
> creates `ScreencastProxy` with default flags. D-Bus therefore auto-starts
> `org.gnome.Shell.Screencast` to read `ScreencastSupported`, in the greeter and in
> initial setup too. Neither mode can screencast: both leave `allowScreencast` false, and
> the cast button is gated on it.
>
> Starting the service still costs a gjs process that runs `Gst.init` and `Gtk.init`, and
> `Gtk.init` can block on the portal (`Cannot get portal
> org.freedesktop.portal.Settings version: Timeout was reached`). With GDM's dynamic
> greeter users, the greeter's home is a tmpfs directory GDM deletes, so GStreamer
> rebuilds its whole plugin registry on every greeter start: about 1.2 s of CPU and
> 160 MB with the usual plugin set, and one core for one to two minutes on a slow or
> emulated machine.
>
> To reproduce, run gnome-shell in `--mode=gdm` and watch for dbus's `Activating service
> name='org.gnome.Shell.Screencast'`.

## MR text

**Title:** screenshot: Don't start the screencast service where it can't be used

> Where the session mode doesn't allow screencasts (the greeter, initial setup), create
> the `ScreencastProxy` with `DO_NOT_AUTO_START`, so the service isn't started for a
> cast button that can never show. User sessions are unchanged.
>
> With no owner, the proxy's init callback reads `ScreencastSupported` as null, and the
> cast button stays hidden, as `allowScreencast` already keeps it. Stock already uses the
> flag this way in `backgroundApps.js`, `thunderbolt.js` and `dateMenu.js`. An
> alternative is not creating the proxy at all in those modes, which needs its other uses
> guarded.
>
> Closes: (the issue above)
