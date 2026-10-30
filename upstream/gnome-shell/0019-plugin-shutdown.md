# 0019: plugin, no ShellWM once the global is gone

From `packaging/pkgs/gnome-shell/patches/0019-plugin-shutdown.patch` (+66 −25,
`src/gnome-shell-plugin.c`). `0019-plugin-shutdown.patch` here is the same code with an
upstream commit message. `git apply --check` passes on gnome-shell main 9a753aa
(2026-10-29).

## What upstream has (2026-10-30)

- **Issue #9443**, "gnome-shell segfaults when terminated with a window open:
  get_shell_wm": the same crash on stock Fedora 45 Beta (51.0), reached by SIGTERM with a
  window open. It was closed on 2026-09-25 with mutter changes linked.
- **mutter !5327 and !5336**, merged 2026-09-14 and 15: the plugin manager stops
  *starting* window effects once the compositor prepares its shutdown. !5327 (b676782,
  250a2dd) is in mutter 51.0 and !5336 (eb74a99) in 51.1.
- **gnome-shell draft !4416**, "shell/plugin: Guard against global access on shutdown"
  (Sebastian Keller, opened 2026-09-13): a weak pointer to the global, `get_shell_wm()`
  returning NULL once it is gone, every entry point skipping its call without a `ShellWM`,
  the pointer cleared in dispose and `locate_pointer` guarded. It is still a draft, and
  main has no fix.

So upstream knows the bug and has a fix in review. The mutter side alone does not close
it: Apex hit the crash with mutter 51.1, which carries both mutter changes, through a path
they do not cover.

## What to file

1. **Comment on !4416** (text below) with the path that mutter 51.1 still reaches, asking
   for the draft to land. This is the smallest useful step, and needs no MR of Apex's own.
2. If !4416 is abandoned, **open an MR** with `0019-plugin-shutdown.patch` (text below),
   pointing at #9443.

How 0019 differs from !4416: where there is no `ShellWM`, 0019 completes each effect
straight to mutter (`meta_plugin_*_completed()`), so mutter's effect bookkeeping still
finishes; !4416 skips the call. Both stop the crash. !4416 also guards `locate_pointer`
and clears the weak pointer in dispose, which 0019 does not. Upstream's choice is fine
either way; the comment only offers the difference.

## Evidence

- **Apex VM run 5** (apex-image 40502904742): the G2 motion case exited 139 at logout, a
  segfault. Its log, after "Shutting down GNOME Shell":

  ```
  shell_global_get: assertion 'the_object' failed
  g_object_get: assertion 'G_IS_OBJECT (object)' failed
  ```

- **Reproduced on Fedora's own build**, `gnome-shell-51.0-1.fc45` with
  `mutter-51.1-1.fc45`, with one Wayland client still connected when the session ends:

  ```
  Shell-CRITICAL: shell_global_get: assertion 'the_object' failed
  GLib-GObject-CRITICAL: g_object_get: assertion 'G_IS_OBJECT (object)' failed
  GLib-GObject-CRITICAL: g_object_unref: assertion 'G_IS_OBJECT (object)' failed
  GLib-GObject-CRITICAL: invalid (NULL) pointer instance
  ```

  When the uninitialised `wm` slot holds NULL these are CRITICALs; when it holds garbage,
  the shell segfaults, as in the VM.
- **Backtrace**: from an `LD_PRELOAD` hook on `g_return_if_fail_warning`, resolved with
  debuginfod against those builds:

  ```
  shell_global_get
  get_shell_wm                            src/gnome-shell-plugin.c:78 (inlined)
  gnome_shell_plugin_kill_window_effects  src/gnome-shell-plugin.c:151
  meta_window_actor_thaw                  src/compositor/meta-window-actor.c:411
  meta_compositor_size_change_window      src/compositor/meta-window-actor.c:1191
  meta_window_unmanage                    src/core/window.c:1686
  wl_client_destroy <- wl_display_destroy_clients
  g_object_run_dispose <- meta_context_destroy <- main
  ```

  This is a window actor's size-change thaw killing effects, not a new effect starting,
  so the mutter guard does not stop it.
- **Apex's regression check**: G2's `clean_shutdown` (`tests/shots/assert.sh:222`) fails
  every case on `shell_global_get: assertion` or `G_IS_OBJECT` after "Shutting down GNOME
  Shell". Without 0019 it fails the motion case alone. With 0019, every case passes
  (apex-gnome #169: G2 1765 passed, 0 failed).

## Comment for !4416

> This still reproduces with mutter 51.1, which has !5327 and !5336: the effect isn't
> started at shutdown, it's killed. When `meta_context_destroy()` destroys a Wayland
> client that is still connected, `meta_window_unmanage()` ends the window's size change,
> `meta_window_actor_thaw()` calls `kill_window_effects`, and `get_shell_wm()` gets the
> NULL global:
>
> ```
> gnome_shell_plugin_kill_window_effects  src/gnome-shell-plugin.c:151
> meta_window_actor_thaw                  src/compositor/meta-window-actor.c:411
> meta_compositor_size_change_window      src/compositor/meta-window-actor.c:1191
> meta_window_unmanage                    src/core/window.c:1686
> wl_client_destroy <- wl_display_destroy_clients
> g_object_run_dispose <- meta_context_destroy <- main
> ```
>
> On `gnome-shell-51.0-1.fc45` with `mutter-51.1-1.fc45` that logs `shell_global_get:
> assertion 'the_object' failed` and `g_object_get: assertion 'G_IS_OBJECT (object)'
> failed`, and segfaults when the uninitialised `wm` holds garbage. We carry a fix along
> the lines of this MR downstream, and it stops both. One difference you may want: where
> there is no `ShellWM`, we complete each effect to mutter (`meta_plugin_map_completed()`
> and the like) rather than skip it, so mutter's effect bookkeeping still finishes. Could
> this MR come out of draft?

## Issue text (only if !4416 stalls: reopen #9443 or file this)

**Title:** Shutdown with a client still connected reaches a disposed ShellGlobal in
`get_shell_wm()` (mutter 51.1)

> At exit, `main()` runs `meta_context_destroy()` after the shell has disposed its
> `ShellGlobal`, and `shell_global_dispose()` sets `the_object` to NULL. Destroying the
> Wayland clients that are still connected unmanages their windows. Mutter then calls
> back into the plugin, here `kill_window_effects` from a size-change thaw, and
> `get_shell_wm()` passes the NULL `shell_global_get()` to `g_object_get()`. That fails
> and leaves `wm` uninitialised, which then goes to `g_object_unref()` and to the
> `_shell_wm_*()` call. The result is CRITICALs, or a segfault when the stack slot holds
> garbage.
>
> mutter !5327 and !5336 stop new effects at shutdown, but this path kills an effect,
> and it still reproduces on `gnome-shell-51.0-1.fc45` with `mutter-51.1-1.fc45`. The
> backtrace and the CRITICALs are in the comment above. Draft !4416 fixes it.

## MR text (only if !4416 is abandoned)

**Title:** plugin: Don't reach a disposed ShellGlobal at shutdown

> Keep a weak pointer to the global and return NULL from `get_shell_wm()` once it is
> gone. Without a `ShellWM`, complete each effect straight to mutter so its effect
> bookkeeping still finishes, and skip the calls that have nothing to complete.
>
> Mutter still calls into the plugin during `meta_context_destroy()`, after the
> `ShellGlobal` is disposed: a window actor's size-change thaw kills its effects while
> the remaining Wayland clients are destroyed. This is not covered by mutter !5327 and
> !5336, which stop new effects. Same backtrace as above.
>
> Related: #9443, !4416
