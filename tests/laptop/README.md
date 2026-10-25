# The laptop glass protocol

ADR 0014's glass acceptance (§Glass everywhere, the acceptance table; ROADMAP S2b, "Glass
protocol") as one command the owner runs on the laptop, on an installed Apex. It records,
scores and reports. It never escalates: the levers and §Escalation stay the owner's. CI
tests every scoring rule and guard against canned captures and fake sysfs trees.
Nothing in CI measures the laptop.

```bash
just glass-protocol run          # A, B and C, 60 s each, with the glass and with Reduce Transparency (about 8 minutes)
just glass-protocol power idle   # three alternating 10-minute runs of each, idle (about an hour)
just glass-protocol power A      # the same with scenario A running (about an hour)
just glass-protocol score DIR    # scores a recorded directory again
```

## Before a run

| Condition | Checked from |
|---|---|
| on battery | every `Mains` supply under `/sys/class/power_supply` is offline |
| the balanced profile | `powerprofilesctl get` |
| 90 Hz | the one current mode in Mutter's `DisplayConfig.GetCurrentState` |
| brightness 50 % (`power` only) | `/sys/class/backlight/*` |
| Wi-Fi off (`power` only) | every `wlan` radio under `/sys/class/rfkill` is soft- or hard-blocked |

A failed check stops the kit. `--ignore-preflight` runs anyway, and the report says so.
Unplug other monitors first: the scenarios' geometry is the laptop's panel, 1440×900
logical px at scale 2, and a second monitor fails the 90 Hz check.

`run` and `power A` drive the shell through `org.gnome.Shell.Eval`, which the shell only
answers in unsafe mode. The owner turns it on before starting, in Looking Glass (Alt+F2,
`lg`): `global.context.unsafe_mode = true`.

- The kit never turns unsafe mode on itself, and adds no bus method to the image or the
  layer.
- At start it prints that any process in the session can run code in the shell until the
  kit finishes.
- It turns unsafe mode off on every exit, including a failure or Ctrl+C, then reads it
  back and says if it could not.
- If the kit is killed without running its cleanup, log out to clear unsafe mode. Its
  marker in `$XDG_RUNTIME_DIR`, which logging out also clears, makes the next start refuse
  until the owner confirms, or passes `--yes-stale-unsafe`.
- Unsafe mode stays on for the whole sequence, so the status pill shows the same
  indicator in the glass and the Reduce Transparency runs.

## What a run does

Each scenario runs once with the glass and once with `reduce-transparency`. The kit puts
back the owner's value afterwards, and `scenarios.js` puts back `dock-intellihide`.

1. A `sysprof-cli --gnome-shell` capture, without sysprofd or perf.
2. `scenarios.js` from this checkout, imported into the shell by its absolute path. It runs
   `tests/shots/glass-load.js`'s scenario for 60 s with `load-window.js` in its measuring
   mode, and writes the start, the end and each step's time.
3. In A, amdgpu's `gpu_busy_percent`, sampled at 10 Hz.

| Scenario | What runs |
|---|---|
| A | the repainting load window over the dock, with Quick Settings open over it |
| B | the still load window dragged under the dock, then Quick Settings, then the calendar, a step every 33 ms |
| C | 20 overview and app-grid toggles over the repainting window, then Spotlight over it |

`--manual` is for when Eval is refused. The kit starts the load window and records 60 s
while the owner performs each scenario by hand. B and C are then marked "not repeatable",
and B's drops, which need the shell's steps, are unmeasured.

## The rows

| Row | Pass |
|---|---|
| p99 frame time, per scenario | at most 11.1 ms |
| dropped frames, per scenario | at most 1 % |
| p50 frame time, per scenario | within 0.5 ms of Reduce Transparency's |
| `gpu_busy_percent`, A | a mean delta of at most 5 points |
| power, idle | a mean delta of at most 0.3 W |
| power, A | a mean delta of at most 0.5 W |

- **Frame time** is the duration of mutter's `Clutter::FrameClock::dispatch()` mark, from
  the frame clock's dispatch through the swap: CPU-side.
- **Dropped frames** are updates that never got a presented frame. In A and C, a load
  window change counts as dropped when no frame showing it was presented, read from GTK's
  own frame timings as each frame completes. In B and C, a shell step counts as dropped
  when no `presented()` mark follows it before the next step.
  - A step is a move that changed the window's place. Past the panel's right edge the
    work area's constraints refuse B's moves, which changes nothing on screen.
  - With the glass, every step must reach the screen: every surface on B's path is
    translucent.
  - With Reduce Transparency, a step needs no frame only when two things hold:
    `scenarios.js` found the window's whole buffer inside an open popover's card, inset
    by its corners, and the compositor dispatched nothing. The report counts these as
    `stepsNeedingNoFrame`. A visible step with no dispatch stays lost.
  - The row takes the worse of the two runs.
  - Both count against the content, not the panel: a 60 fps window on a 90 Hz panel
    presents at one and two intervals and drops nothing.
  - A change made in the last 200 ms of the recording is not counted.
- **Power** is upower's energy rate every 10 s, without each run's first 30 s.

Report-only columns:

- dispatch to the next `presented()`: the GPU-side lateness, next to `gpu_busy_percent`;
- the median of dispatch's "dispatched N µs late", which reads 13 to 20 ms on a steady
  headless 30 Hz client, so it decides nothing;
- frames with more than one surface commit since the last dispatch, a compositor-side
  cross-check on the client's count.

The result is `PASS`, `FAIL`, or `INCOMPLETE` when a row could not be measured. On a fail
the kit prints ADR 0014's levers in order. Everything goes to `report.json` in the run
directory, beside the captures, the client logs and the samples.

## Files

| File | What it is |
|---|---|
| `glass_protocol.py` | the kit: preflight, the guards, recording, the capture reader and the scoring; Python 3, standard library only |
| `glass-protocol.sh` | the command `just glass-protocol` runs |
| `scenarios.js` | the shell's side, loaded through Eval |
| `test_glass_protocol.py`, `selftest.sh` | CI's tests: a passing run, a variant per row that fails only that row, a 60-on-90 cadence with no drops, one coalesced change counted once, the preflight on fake sysfs trees, the unsafe-mode guards against a fake `gdbus` |
| `fixtures/headless-30hz.syscap` | 2 s of a real `sysprof-cli 51.0` capture of Fedora's gnome-shell, headless, with a 30 Hz client: its dispatch, presented and commit marks, byte for byte |

Fedora 45 ships no exporter for a capture's marks. `glass_protocol.py marks CAPTURE`
prints them, read straight from Sysprof's capture format (`sysprof-capture-types.h`).

The paths and tools can be overridden for tests: `GLASS_SYSFS`, `GLASS_SYSPROF`,
`GLASS_GDBUS`, `GLASS_UPOWER`, `GLASS_POWERPROFILESCTL`, `GLASS_GSETTINGS`,
`GLASS_SCENARIO_SECONDS` and `GLASS_POWER_RUN_SECONDS`.
