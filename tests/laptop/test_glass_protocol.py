#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""glass_protocol.py's scoring, preflight and guards against canned captures, fake sysfs trees and a
fake gdbus: a passing run passes every row, and each variant fails exactly the row it names.
Nothing here measures a laptop."""

import json
import math
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import glass_protocol as g  # noqa: E402

START_US = 1_000_000_000
SECONDS = 60
END_US = START_US + SECONDS * 1_000_000
VSYNC_US = 1_000_000 / g.HZ
CLIENT_US = 1_000_000 / 60
STEP_US = 33_333
ROWS = ["A p99 frame time", "A dropped frames", "A p50 against Reduce Transparency", "A gpu_busy_percent delta",
        "B p99 frame time", "B dropped frames", "B p50 against Reduce Transparency",
        "C p99 frame time", "C dropped frames", "C p50 against Reduce Transparency",
        "power idle delta", "power A delta"]


def mark(when_us, name, duration_us=0, message=""):
    return g.Mark(int(when_us * 1000), int(duration_us * 1000), 100, "Compositor", name, message)


def synth(directory, scenario, mode, frame_ms=None, slow_share=0.0, coalesce_share=0.0, coalesce_one=False,
          lost_step_share=0.0, occluded=None, gpu=None, error=None, manual=False):
    """One recorded run: a 90 Hz frame clock, a 60 fps client on it, and B's and C's steps."""
    base = Path(directory) / f"{scenario}-{mode}"
    if error:
        base.with_suffix(".json").write_text(json.dumps({"scenario": scenario, "error": error}))
        return
    frame_ms = frame_ms if frame_ms is not None else (4.0 if mode == "glass" else 3.8)
    frames = int(SECONDS * g.HZ)
    vsyncs = [START_US + i * VSYNC_US for i in range(frames)]
    steps = [] if manual or scenario == "A" else [START_US + 5000 + i * STEP_US for i in range(int(SECONDS * 1e6 / STEP_US))]
    lost_every = round(1 / lost_step_share) if lost_step_share else 0
    hidden = set()
    for i, s in enumerate(steps):
        if lost_every and i % lost_every == 0:
            following = steps[i + 1] if i + 1 < len(steps) else END_US
            hidden |= {v for v in vsyncs if s < v + 2000 <= following}
    idle = set()
    if occluded:
        first, last = occluded
        idle = {v for v in vsyncs if steps[first] < v <= steps[last + 1]}
    marks, slow_every = [], round(1 / slow_share) if slow_share else 0
    for i, v in enumerate(vsyncs):
        if v in idle:
            continue
        duration = 12.0 if slow_every and i % slow_every == 0 else frame_ms
        marks.append(mark(v, g.DISPATCH, duration * 1000, "Meta-0, dispatched 16300 µs late"))
        marks.append(mark(v + 100, g.COMMIT, 500))
        if v not in hidden:
            marks.append(mark(v + 2000, g.PRESENTED, 2, "Meta-0, presentation was 50 µs earlier"))
    g.write_capture(base.with_suffix(".syscap"), marks)
    if scenario != "B":
        lines, coalesce_every = [], round(1 / coalesce_share) if coalesce_share else 0
        for k in range(int(SECONDS * 60)):
            when = START_US + k * CLIENT_US
            lines.append(f"c {k} {int(when)}")
            lost = (coalesce_every and k % coalesce_every == 0) or (coalesce_one and k == 600)
            i = math.ceil((when - 1000 - START_US) / VSYNC_US)
            shown_at = START_US + i * VSYNC_US + 2000 if i < frames else 0
            lines.append(f"p {k} {0 if lost else int(shown_at)}")
        base.with_suffix(".client").write_text("\n".join(lines) + "\n")
    if scenario == "A" and gpu is not False:
        level = gpu if gpu is not None else (40 if mode == "glass" else 37)
        base.with_suffix(".gpu").write_text("".join(f"{START_US + i * 100_000} {level}\n" for i in range(SECONDS * 10)))
    base.with_suffix(".json").write_text(json.dumps({"scenario": scenario, "startUs": START_US, "endUs": END_US,
                                                     "steps": [int(s) for s in steps], "manual": manual}))


def synth_power(directory, scenario, glass_w, rt_w, warmup_w=None):
    lines = []
    for run in range(g.POWER_RUNS):
        for mode, watts in (("glass", glass_w), ("rt", rt_w)):
            for since in range(0, 600, g.POWER_SAMPLE_S):
                value = warmup_w if warmup_w is not None and since < g.POWER_WARMUP_S else watts
                lines.append(f"{mode} {run} {since} {value}")
    (Path(directory) / f"power-{scenario}.tsv").write_text("\n".join(lines) + "\n")


def passing(directory, **changes):
    """The passing run, with CHANGES as {"A-glass": synth keywords} or power overrides."""
    for scenario in g.SCENARIOS:
        for mode in g.MODES:
            synth(directory, scenario, mode, **changes.get(f"{scenario}-{mode}", {}))
    synth_power(directory, "idle", *changes.get("idle", (6.1, 6.0)))
    synth_power(directory, "A", *changes.get("power-A", (8.3, 8.0)))


class Scoring(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def statuses(self, **changes):
        passing(self.dir, **changes)
        report = g.score(self.dir)
        return report, {r["row"]: r["status"] for r in report["rows"]}

    def assert_fails_only(self, failing, **changes):
        report, statuses = self.statuses(**changes)
        self.assertEqual(sorted(statuses), sorted(ROWS))
        self.assertEqual([r for r, s in statuses.items() if s != "PASS"], [failing])
        self.assertEqual(statuses[failing], "FAIL")
        self.assertEqual(report["result"], "FAIL")
        self.assertEqual(report["levers"], g.LEVERS)
        self.assertIn("1. ds x 2 on the failing surface", g.table(report))

    def test_passing_run_passes_every_row(self):
        report, statuses = self.statuses()
        self.assertEqual(statuses, dict.fromkeys(ROWS, "PASS"))
        self.assertEqual(report["result"], "PASS")
        self.assertNotIn("levers", report)
        self.assertIn("result: PASS", g.table(report))

    def test_60_on_90_cadence_drops_nothing(self):
        passing(self.dir)
        a = g.score(self.dir)["scenarios"]["A"]["glass"]
        self.assertEqual(a["drops"]["lost"], 0)
        self.assertGreater(a["drops"]["clientChanges"], 3500)
        self.assertEqual(a["lateMedianMs"], 16.3)

    def test_one_coalesced_change_is_one_drop(self):
        passing(self.dir, **{"A-glass": {"coalesce_one": True}})
        report = g.score(self.dir)
        self.assertEqual(report["scenarios"]["A"]["glass"]["drops"]["lost"], 1)
        self.assertEqual(report["scenarios"]["A"]["rt"]["drops"]["lost"], 0)

    def test_each_row_fails_alone(self):
        variants = {
            "A p99 frame time": {"A-glass": {"slow_share": 0.02}},
            "A dropped frames": {"A-glass": {"coalesce_share": 0.02}},
            "A p50 against Reduce Transparency": {"A-glass": {"frame_ms": 4.5}},
            "A gpu_busy_percent delta": {"A-glass": {"gpu": 43}},
            "B p99 frame time": {"B-glass": {"slow_share": 0.02}},
            "B dropped frames": {"B-glass": {"lost_step_share": 0.02}},
            "B p50 against Reduce Transparency": {"B-rt": {"frame_ms": 3.4}},
            "C p99 frame time": {"C-glass": {"slow_share": 0.02}},
            "C dropped frames": {"C-glass": {"coalesce_share": 0.02}},
            "C p50 against Reduce Transparency": {"C-glass": {"frame_ms": 4.4}},
            "power idle delta": {"idle": (6.4, 6.0)},
            "power A delta": {"power-A": (8.6, 8.0)},
        }
        self.assertEqual(sorted(variants), sorted(ROWS))
        for failing, changes in variants.items():
            with self.subTest(failing):
                self.tmp.cleanup()
                self.tmp = tempfile.TemporaryDirectory()
                self.dir = Path(self.tmp.name)
                self.assert_fails_only(failing, **changes)

    def test_a_hidden_window_needs_no_frame_only_without_glass(self):
        report, statuses = self.statuses(**{"B-rt": {"occluded": (100, 139)}})
        self.assertEqual(statuses, dict.fromkeys(ROWS, "PASS"))
        rt = report["scenarios"]["B"]["rt"]["drops"]
        self.assertEqual((rt["lost"], rt["stepsNeedingNoFrame"]), (0, 40))
        self.tmp.cleanup()
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.assert_fails_only("B dropped frames", **{"B-glass": {"occluded": (100, 139)}})

    def test_a_dispatched_step_never_presented_is_lost_without_glass_too(self):
        passing(self.dir, **{"B-rt": {"lost_step_share": 0.02}})
        rt = g.score(self.dir)["scenarios"]["B"]["rt"]["drops"]
        self.assertEqual(rt["stepsNeedingNoFrame"], 0)
        self.assertEqual(rt["lost"], len(range(0, rt["steps"], 50)))

    def test_limits_hold_at_the_edge(self):
        _, statuses = self.statuses(**{"A-glass": {"frame_ms": 4.3}, "idle": (6.3, 6.0), "power-A": (8.5, 8.0)})
        self.assertEqual(statuses, dict.fromkeys(ROWS, "PASS"))

    def test_power_warmup_is_not_scored(self):
        _, statuses = self.statuses(idle=(6.1, 6.0, 20.0))
        self.assertEqual(statuses["power idle delta"], "PASS")

    def test_missing_gpu_samples_leave_the_run_incomplete(self):
        report, statuses = self.statuses(**{"A-glass": {"gpu": False}})
        self.assertEqual(statuses["A gpu_busy_percent delta"], "UNMEASURED")
        self.assertEqual(report["result"], "INCOMPLETE")

    def test_a_scenario_error_fails(self):
        report, statuses = self.statuses(**{"C-rt": {"error": "Error: the load window never mapped"}})
        self.assertEqual(statuses["C: the scenario ran"], "FAIL")
        self.assertEqual(report["result"], "FAIL")

    def test_manual_marks_b_and_c_not_repeatable(self):
        manual = {f"{s}-{m}": {"manual": True} for s in g.SCENARIOS for m in g.MODES}
        report, statuses = self.statuses(**manual)
        self.assertEqual(statuses["B dropped frames"], "UNMEASURED")
        flagged = {r["row"] for r in report["rows"] if r.get("notRepeatable")}
        self.assertEqual(flagged, {r for r in ROWS if r[0] in "BC" and not r.startswith("power")})
        self.assertIn("not repeatable", g.table(report))

    def test_definitions_are_in_the_report(self):
        passing(self.dir)
        definitions = g.score(self.dir)["definitions"]
        self.assertIn("dispatch()", definitions["frameTime"])
        self.assertIn("report only", definitions["dispatchToPresented"])


class Capture(unittest.TestCase):
    def test_reads_sysprofs_own_capture(self):
        marks = g.read_marks(HERE / "fixtures/headless-30hz.syscap")
        names = [m.name for m in marks]
        self.assertEqual(names.count(g.DISPATCH), 61)
        self.assertEqual(names.count(g.PRESENTED), 61)
        dispatches = [m for m in marks if m.name == g.DISPATCH]
        self.assertTrue(all(m.group == "Compositor" and "late" in m.message for m in dispatches))
        stats = g.frame_stats(marks, dispatches[0].time // 1000, dispatches[-1].time // 1000 + 1)
        self.assertEqual(stats["frames"], 61)
        self.assertTrue(0 < stats["p50Ms"] <= stats["p99Ms"] < 11.1)
        self.assertEqual(stats["framesWithSeveralCommits"], 0)

    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "c.syscap"
            written = [mark(10, g.DISPATCH, 4000, "Meta-0, dispatched 12 µs late"), mark(20, g.PRESENTED)]
            g.write_capture(path, written)
            self.assertEqual(g.read_marks(path), written)

    def test_refuses_other_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.syscap"
            path.write_bytes(b"\0" * 300)
            with self.assertRaises(ValueError):
                g.read_marks(path)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


GDBUS = """#!/bin/sh
state=${GLASS_TEST_STATE:?}
case "$*" in
  *GetCurrentState*) cat "$state/display" ;;
  *"unsafe_mode = false"*) echo false >"$state/unsafe"; echo "(true, 'false')" ;;
  *Eval*) if [ "$(cat "$state/unsafe")" = true ]; then echo "(true, 'true')"; else echo "(false, '')"; fi ;;
esac
"""
GSETTINGS = """#!/bin/sh
state=${GLASS_TEST_STATE:?}
case "$1" in
  get) cat "$state/rt" ;;
  set) echo "$4" >"$state/rt" ;;
esac
"""
DISPLAY = ("(uint32 1, [(('eDP-1', 'BOE', '0x0a1c', '0x0'), [('2880x1800@60.000', 2880, 1800, 60.0, 2.0, [1.0, 2.0], "
           "{'is-preferred': <true>}), ('2880x1800@90.000', 2880, 1800, 90.0, 2.0, [1.0, 2.0], {'is-current': <true>})], "
           "{'is-builtin': <true>})], [], {})\n")


class Machine(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.sys, self.state, self.run = root / "sys", root / "state", root / "run"
        for d in (self.state, self.run):
            d.mkdir()
        write(self.sys / "class/power_supply/AC/type", "Mains\n")
        write(self.sys / "class/power_supply/AC/online", "0\n")
        write(self.sys / "class/power_supply/BAT0/type", "Battery\n")
        write(self.sys / "class/backlight/amdgpu_bl1/brightness", "128\n")
        write(self.sys / "class/backlight/amdgpu_bl1/max_brightness", "255\n")
        for name, value in (("type", "wlan"), ("soft", "1"), ("hard", "0")):
            write(self.sys / f"class/rfkill/rfkill0/{name}", f"{value}\n")
        write(self.sys / "class/drm/card1/device/gpu_busy_percent", "12\n")
        write(self.state / "display", DISPLAY)
        write(self.state / "unsafe", "true\n")
        write(self.state / "rt", "false\n")
        bins = root / "bin"
        for name, body in (("gdbus", GDBUS), ("gsettings", GSETTINGS), ("powerprofilesctl", "#!/bin/sh\necho balanced\n")):
            write(bins / name, body)
            (bins / name).chmod(stat.S_IRWXU)
        os.environ["GLASS_TEST_STATE"] = str(self.state)
        self.saved = {k: getattr(g, k) for k in ("SYSFS", "GDBUS", "GSETTINGS", "POWERPROFILESCTL", "RUNTIME_DIR")}
        g.SYSFS, g.RUNTIME_DIR = self.sys, self.run
        g.GDBUS, g.GSETTINGS, g.POWERPROFILESCTL = str(bins / "gdbus"), str(bins / "gsettings"), str(bins / "powerprofilesctl")

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(g, k, v)
        self.tmp.cleanup()

    def test_preflight_passes_on_the_laptop_as_specified(self):
        self.assertEqual(g.preflight(power=True), dict.fromkeys(
            ["on battery", "balanced power profile", "90 Hz", "brightness 50 %", "Wi-Fi off"], True))
        self.assertEqual(g.gpu_busy_path().read_text(), "12\n")

    def test_preflight_names_each_failure(self):
        cases = {
            "on battery": (self.sys / "class/power_supply/AC/online", "1\n"),
            "90 Hz": (self.state / "display", DISPLAY.replace("'is-current'", "'x'")),
            "brightness 50 %": (self.sys / "class/backlight/amdgpu_bl1/brightness", "200\n"),
            "Wi-Fi off": (self.sys / "class/rfkill/rfkill0/soft", "0\n"),
        }
        for failing, (path, broken) in cases.items():
            with self.subTest(failing):
                good = path.read_text()
                write(path, broken)
                checks = g.preflight(power=True)
                write(path, good)
                self.assertEqual([k for k, ok in checks.items() if not ok], [failing])

    def test_eval_reply_and_quoting(self):
        self.assertEqual(g.shell_eval("1"), (True, "true"))
        self.assertEqual(g.gvariant_string("it's \\"), "'it\\'s \\\\'")
        write(self.state / "unsafe", "false\n")
        self.assertEqual(g.shell_eval("1"), (False, ""))

    def test_session_refuses_without_unsafe_mode(self):
        write(self.state / "unsafe", "false\n")
        with self.assertRaisesRegex(g.Refused, "never turns it on"):
            g.Session(need_unsafe=True, yes_stale=False)
        self.assertFalse((self.run / g.MARKER).exists())

    def test_session_turns_unsafe_mode_off_and_restores_rt(self):
        session = g.Session(need_unsafe=True, yes_stale=False)
        self.assertTrue((self.run / g.MARKER).exists())
        session.reduce_transparency(True)
        self.assertEqual((self.state / "rt").read_text().strip(), "true")
        session.close()
        self.assertEqual((self.state / "unsafe").read_text().strip(), "false")
        self.assertEqual((self.state / "rt").read_text().strip(), "false")
        self.assertFalse((self.run / g.MARKER).exists())

    def test_session_refuses_a_stale_unsafe_run(self):
        (self.run / g.MARKER).write_text("1\n")
        with self.assertRaisesRegex(g.Refused, "earlier run"):
            g.Session(need_unsafe=True, yes_stale=False)
        g.Session(need_unsafe=True, yes_stale=True).close()


if __name__ == "__main__":
    unittest.main(verbosity=1)
