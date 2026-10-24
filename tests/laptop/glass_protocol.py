#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: glass_protocol.py run [--manual] [--ignore-preflight] [--yes-stale-unsafe] [--out DIR]
       glass_protocol.py power [idle|A] [--ignore-preflight] [--yes-stale-unsafe] [--out DIR]
       glass_protocol.py score DIR
       glass_protocol.py marks CAPTURE

ADR 0014's glass acceptance on the laptop, run by its owner on an installed Apex: on battery,
balanced profile, 90 Hz. `run` records scenarios A, B and C for 60 s each, with the glass and
with Reduce Transparency, and scores them; `power` samples upower's energy rate over three
alternating 10-minute runs of each (about an hour per scenario); `score` scores a recorded
directory again; `marks` prints a Sysprof capture's marks. tests/laptop/README.md has the rows.
The kit reports only: escalation is the owner's (ADR 0014, Escalation).
"""

import bisect
import collections
import glob
import json
import math
import os
import re
import signal
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SYSFS = Path(os.environ.get("GLASS_SYSFS", "/sys"))
SYSPROF = os.environ.get("GLASS_SYSPROF", "sysprof-cli")
GDBUS = os.environ.get("GLASS_GDBUS", "gdbus")
UPOWER = os.environ.get("GLASS_UPOWER", "upower")
POWERPROFILESCTL = os.environ.get("GLASS_POWERPROFILESCTL", "powerprofilesctl")
GSETTINGS = os.environ.get("GLASS_GSETTINGS", "gsettings")
RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
SECONDS = float(os.environ.get("GLASS_SCENARIO_SECONDS", "60"))
POWER_RUN_SECONDS = float(os.environ.get("GLASS_POWER_RUN_SECONDS", "600"))

HZ = 90
INTERVAL_MS = 1000 / HZ
P99_MAX_MS = 11.1
DROPS_MAX = 0.01
P50_DELTA_MAX_MS = 0.5
GPU_DELTA_MAX = 5
POWER_DELTA_MAX_W = {"idle": 0.3, "A": 0.5}
BRIGHTNESS = 0.5
GPU_SAMPLE_S = 0.1
POWER_SAMPLE_S = 10
POWER_RUNS = 3
POWER_WARMUP_S = 30
SETTLE_S = 3
# A change this close to the end of a recording may be presented after it stops.
END_MARGIN_US = 200_000
SCENARIOS = ("A", "B", "C")
MODES = ("glass", "rt")
APEX_SCHEMA = "io.github.apex_linux.Apex.Desktop"
RT_KEY = "reduce-transparency"
MARKER = "apex-glass-protocol.pid"
LEVERS = [
    "ds x 2 on the failing surface",
    "under the power-saver profile, ds x 2 everywhere, and the scrims re-blur at most at 30 Hz",
    "the one mutter change: exported redraw-clip expansion, which removes the extra frame that item e queues (Escalation)",
    "the owner decides with the numbers, for example cached glass on one surface",
]
UNSAFE_NOTE = ("Unsafe mode is on: any process in this session can run code in the shell until the kit "
               "finishes and turns it off.")

CAPTURE_MAGIC = 0xFDCA975E
CAPTURE_HEADER = 256
FRAME_HEADER = 24
MARK_FRAME = 10
MARK_FIXED = 96
DISPATCH = "Clutter::FrameClock::dispatch()"
PRESENTED = "Clutter::FrameClock::presented()"
COMMIT = "Meta::WaylandSurface::commit()"
LATE = re.compile(r"dispatched (\d+) µs late")

Mark = collections.namedtuple("Mark", "time duration pid group name message")


class Refused(Exception):
    """The kit will not start: a preflight or a safety check said no."""


def cstr(raw):
    return raw.split(b"\0", 1)[0].decode("utf-8", "replace")


def read_marks(path):
    data = Path(path).read_bytes()
    if len(data) < CAPTURE_HEADER or struct.unpack_from("<I", data)[0] != CAPTURE_MAGIC:
        raise ValueError(f"{path}: not a Sysprof capture")
    if not data[5] & 1:
        raise ValueError(f"{path}: a big-endian capture")
    marks, offset = [], CAPTURE_HEADER
    while offset + FRAME_HEADER <= len(data):
        length, _cpu, pid, when, kind = struct.unpack_from("<HhiqI", data, offset)
        if length < FRAME_HEADER or offset + length > len(data):
            break
        if kind & 0xFF == MARK_FRAME and length >= MARK_FIXED:
            (duration,) = struct.unpack_from("<q", data, offset + 24)
            marks.append(Mark(when, duration, pid, cstr(data[offset + 32:offset + 56]),
                              cstr(data[offset + 56:offset + 96]), cstr(data[offset + 96:offset + length])))
        offset += length
    return marks


def write_capture(path, marks):
    """A capture holding only MARKS, as Sysprof writes them: the tests' canned captures."""
    out = bytearray(struct.pack("<IBB2x64sqq168x", CAPTURE_MAGIC, 1, 1, b"", 0, 0))
    for m in marks:
        body = struct.pack("<q24s40s", m.duration, m.group.encode(), m.name.encode()) + m.message.encode() + b"\0"
        length = (FRAME_HEADER + len(body) + 7) // 8 * 8
        out += struct.pack("<HhiqII", length, -1, m.pid, m.time, MARK_FRAME, 0) + body.ljust(length - FRAME_HEADER, b"\0")
    Path(path).write_bytes(bytes(out))


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(p / 100 * len(ordered)) - 1)]


def frame_stats(marks, start_us, end_us):
    lo, hi = start_us * 1000, end_us * 1000
    dispatches = sorted((m for m in marks if m.name == DISPATCH and lo <= m.time < hi), key=lambda m: m.time)
    presented = sorted(m.time for m in marks if m.name == PRESENTED)
    commits = sorted(m.time for m in marks if m.name == COMMIT and lo <= m.time < hi)
    frame_ms = [m.duration / 1e6 for m in dispatches]
    to_presented, late, coalesced = [], [], 0
    for i, d in enumerate(dispatches):
        following = dispatches[i + 1].time if i + 1 < len(dispatches) else hi
        j = bisect.bisect_left(presented, d.time)
        if j < len(presented) and presented[j] < following:
            to_presented.append((presented[j] - d.time) / 1e6)
        if match := LATE.search(d.message):
            late.append(int(match.group(1)) / 1000)
        if bisect.bisect_left(commits, following) - bisect.bisect_left(commits, d.time) > 1:
            coalesced += 1
    return {
        "frames": len(dispatches),
        "p50Ms": percentile(frame_ms, 50),
        "p99Ms": percentile(frame_ms, 99),
        "dispatchToPresentedMs": {"p50": percentile(to_presented, 50), "p99": percentile(to_presented, 99)},
        "lateMedianMs": percentile(late, 50),
        "framesWithSeveralCommits": coalesced,
    }


def read_client(path):
    changes, shown = {}, set()
    if not Path(path).exists():
        return changes, shown
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        kind, content, when = parts[0], int(parts[1]), int(parts[2])
        if kind == "c":
            changes[content] = when
        elif kind == "p" and when > 0:
            shown.add(content)
    return changes, shown


def drops(client_path, steps, presented_us, start_us, end_us):
    """Updates that never got a presented frame: the client's changes, then the shell's steps."""
    changes, shown = read_client(client_path)
    counted = [c for c, when in changes.items() if start_us <= when <= end_us - END_MARGIN_US]
    lost = [c for c in counted if c not in shown]
    steps = [s for s in steps if start_us <= s <= end_us - END_MARGIN_US]
    lost_steps = 0
    for i, s in enumerate(steps):
        following = steps[i + 1] if i + 1 < len(steps) else end_us
        j = bisect.bisect_right(presented_us, s)
        if not (j < len(presented_us) and presented_us[j] <= following):
            lost_steps += 1
    updates = len(counted) + len(steps)
    return {"updates": updates, "clientChanges": len(counted), "steps": len(steps),
            "lost": len(lost) + lost_steps, "share": (len(lost) + lost_steps) / updates if updates else None}


def mean(values):
    return sum(values) / len(values) if values else None


def read_samples(path, start_us, end_us):
    if not Path(path).exists():
        return []
    values = []
    for line in Path(path).read_text().splitlines():
        when, value = line.split()
        if start_us <= int(when) <= end_us:
            values.append(float(value))
    return values


def score_run(directory, scenario, mode):
    base = Path(directory) / f"{scenario}-{mode}"
    times = json.loads(base.with_suffix(".json").read_text())
    if times.get("error"):
        return {"error": times["error"]}
    start, end = times["startUs"], times["endUs"]
    marks = read_marks(base.with_suffix(".syscap"))
    presented = sorted(m.time // 1000 for m in marks if m.name == PRESENTED)
    result = frame_stats(marks, start, end)
    result["drops"] = drops(base.with_suffix(".client"), times.get("steps", []), presented, start, end)
    result["gpuBusyMean"] = mean(read_samples(base.with_suffix(".gpu"), start, end))
    result["manual"] = bool(times.get("manual"))
    return result


def row(name, value, limit, ok, unit=""):
    status = "UNMEASURED" if value is None else ("PASS" if ok(value) else "FAIL")
    return {"row": name, "value": value, "limit": limit, "unit": unit, "status": status}


def scenario_rows(scenario, glass, rt):
    rows = []
    if "error" in glass or "error" in rt:
        message = glass.get("error") or rt.get("error")
        return [{"row": f"{scenario}: the scenario ran", "value": message, "limit": None, "unit": "", "status": "FAIL"}]
    rows.append(row(f"{scenario} p99 frame time", glass["p99Ms"], P99_MAX_MS, lambda v: v <= P99_MAX_MS, "ms"))
    share = glass["drops"]["share"]
    rows.append(row(f"{scenario} dropped frames", None if share is None else share * 100, DROPS_MAX * 100,
                    lambda v: v <= DROPS_MAX * 100, "%"))
    delta = None if glass["p50Ms"] is None or rt["p50Ms"] is None else glass["p50Ms"] - rt["p50Ms"]
    rows.append(row(f"{scenario} p50 against Reduce Transparency", delta, P50_DELTA_MAX_MS,
                    lambda v: abs(v) <= P50_DELTA_MAX_MS, "ms"))
    if scenario == "A":
        gpu = None if glass["gpuBusyMean"] is None or rt["gpuBusyMean"] is None else glass["gpuBusyMean"] - rt["gpuBusyMean"]
        rows.append(row("A gpu_busy_percent delta", gpu, GPU_DELTA_MAX, lambda v: v <= GPU_DELTA_MAX, "points"))
    if glass["manual"] and scenario != "A":
        for r in rows:
            r["notRepeatable"] = True
    return rows


def power_rows(directory):
    rows = []
    for scenario in POWER_DELTA_MAX_W:
        path = Path(directory) / f"power-{scenario}.tsv"
        if not path.exists():
            continue
        by_mode = collections.defaultdict(list)
        for line in path.read_text().splitlines():
            mode, _run, since, watts = line.split()
            if float(since) >= POWER_WARMUP_S:
                by_mode[mode].append(float(watts))
        glass, rt = mean(by_mode["glass"]), mean(by_mode["rt"])
        limit = POWER_DELTA_MAX_W[scenario]
        rows.append(row(f"power {scenario} delta", None if glass is None or rt is None else glass - rt, limit,
                        lambda v, limit=limit: v <= limit, "W"))
    return rows


def score(directory):
    directory = Path(directory)
    report = {"definitions": {
        "frameTime": "the duration of mutter's Clutter::FrameClock::dispatch() mark: frame clock dispatch through swap",
        "dropped": "a client change or a shell step with no presented frame before the next one",
        "dispatchToPresented": "report only: from dispatch() to the next presented() mark",
        "lateMedianMs": "report only: the median of dispatch()'s 'dispatched N µs late'",
        "framesWithSeveralCommits": "report only: frames with more than one surface commit since the last dispatch",
    }, "scenarios": {}, "rows": []}
    meta = directory / "meta.json"
    if meta.exists():
        report["meta"] = json.loads(meta.read_text())
    for scenario in SCENARIOS:
        if not all((directory / f"{scenario}-{mode}.json").exists() for mode in MODES):
            continue
        runs = {mode: score_run(directory, scenario, mode) for mode in MODES}
        report["scenarios"][scenario] = runs
        report["rows"] += scenario_rows(scenario, runs["glass"], runs["rt"])
    report["rows"] += power_rows(directory)
    statuses = {r["status"] for r in report["rows"]}
    report["result"] = "FAIL" if "FAIL" in statuses else ("INCOMPLETE" if "UNMEASURED" in statuses or not statuses else "PASS")
    if report["result"] == "FAIL":
        report["levers"] = LEVERS
    return report


def fmt(value, unit):
    if value is None:
        return "-"
    if isinstance(value, str):
        return value
    return f"{value:.2f} {unit}".strip()


def table(report):
    lines = [f"{'row':44} {'value':>14} {'limit':>12}  result"]
    for r in report["rows"]:
        limit = "-" if r["limit"] is None else f"{'±' if 'p50' in r['row'] else '≤'} {fmt(r['limit'], r['unit'])}"
        note = " (not repeatable: --manual)" if r.get("notRepeatable") else ""
        lines.append(f"{r['row']:44} {fmt(r['value'], r['unit']):>14} {limit:>12}  {r['status']}{note}")
    if report.get("meta", {}).get("preflightIgnored"):
        lines.append("note: run with --ignore-preflight; the conditions above were not all met")
    lines.append(f"result: {report['result']}")
    if report["result"] == "FAIL":
        lines.append("The levers, in order (ADR 0014, Glass); escalating is the owner's decision (ADR 0014, Escalation):")
        lines += [f"  {i}. {lever}" for i, lever in enumerate(LEVERS, 1)]
    return "\n".join(lines)


def command_output(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def gvariant_string(text):
    return "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"


def shell_eval(code):
    reply = command_output([GDBUS, "call", "--session", "--dest", "org.gnome.Shell", "--object-path", "/org/gnome/Shell",
                            "--method", "org.gnome.Shell.Eval", gvariant_string(code)]).strip()
    match = re.fullmatch(r"\((true|false), '(.*)'\)", reply, re.S)
    if not match:
        return False, reply
    return match.group(1) == "true", match.group(2)


def unsafe_mode():
    ok, value = shell_eval("global.context.unsafe_mode")
    return ok and value == "true"


def on_battery():
    supplies = [Path(p) for p in glob.glob(str(SYSFS / "class/power_supply/*"))]
    mains = [p for p in supplies if (p / "type").read_text().strip() == "Mains"]
    return bool(mains) and all((p / "online").read_text().strip() == "0" for p in mains)


def brightness():
    for device in sorted(glob.glob(str(SYSFS / "class/backlight/*"))):
        now, top = (int((Path(device) / name).read_text()) for name in ("brightness", "max_brightness"))
        return now / top if top else None
    return None


def wifi_off():
    radios = [Path(p) for p in glob.glob(str(SYSFS / "class/rfkill/*")) if (Path(p) / "type").read_text().strip() == "wlan"]
    return all("1" in ((r / "soft").read_text().strip(), (r / "hard").read_text().strip()) for r in radios)


def refresh_hz():
    state = command_output([GDBUS, "call", "--session", "--dest", "org.gnome.Mutter.DisplayConfig", "--object-path",
                            "/org/gnome/Mutter/DisplayConfig", "--method", "org.gnome.Mutter.DisplayConfig.GetCurrentState"])
    rates = [float(m.group(1)) for m in re.finditer(r"\('[^']*', \d+, \d+, ([\d.]+), [^()]*?(?:\[[^\]]*\])?, \{[^{}]*'is-current': <true>", state)]
    return rates[0] if len(rates) == 1 else None


def gpu_busy_path():
    paths = sorted(glob.glob(str(SYSFS / "class/drm/card*/device/gpu_busy_percent")))
    return Path(paths[0]) if paths else None


def preflight(power):
    checks = {
        "on battery": on_battery(),
        "balanced power profile": command_output([POWERPROFILESCTL, "get"]).strip() == "balanced",
        f"{HZ} Hz": (lambda hz: hz is not None and abs(hz - HZ) < 0.5)(refresh_hz()),
    }
    if power:
        level = brightness()
        checks["brightness 50 %"] = level is not None and abs(level - BRIGHTNESS) <= 0.01
        checks["Wi-Fi off"] = wifi_off()
    return checks


def gsettings_get(key):
    return command_output([GSETTINGS, "get", APEX_SCHEMA, key]).strip()


def gsettings_set(key, value):
    subprocess.run([GSETTINGS, "set", APEX_SCHEMA, key, value], check=False)


class Session:
    """Unsafe mode, Reduce Transparency and the stale-run marker, put back however the kit ends."""

    def __init__(self, need_unsafe, yes_stale):
        self.need_unsafe = need_unsafe
        self.marker = RUNTIME_DIR / MARKER
        self.rt = None
        if need_unsafe:
            if not unsafe_mode():
                raise Refused("unsafe mode is off: run `global.context.unsafe_mode = true` in Looking Glass "
                              "(Alt+F2, lg), then start the kit again. The kit never turns it on itself.")
            if self.marker.exists() and not yes_stale and not self.confirm_stale():
                raise Refused("unsafe mode was left on by an earlier run that did not finish: log out to clear it, "
                              "or start again with --yes-stale-unsafe")
            print(UNSAFE_NOTE, flush=True)
            self.marker.write_text(f"{os.getpid()}\n")
        self.rt = gsettings_get(RT_KEY)

    def confirm_stale(self):
        if not sys.stdin.isatty():
            return False
        answer = input("Unsafe mode was left on by an earlier run that did not finish. Run anyway? [y/N] ")
        return answer.strip().lower() == "y"

    def reduce_transparency(self, on):
        gsettings_set(RT_KEY, "true" if on else "false")

    def close(self):
        if self.rt:
            gsettings_set(RT_KEY, self.rt)
        if self.need_unsafe:
            shell_eval("global.context.unsafe_mode = false")
            if unsafe_mode():
                print("The kit could not turn unsafe mode off: log out to clear it.", file=sys.stderr)
            else:
                print("Unsafe mode is off again.", file=sys.stderr)
        if self.need_unsafe:
            self.marker.unlink(missing_ok=True)


class Sampler(threading.Thread):
    def __init__(self, path, out, every):
        super().__init__(daemon=True)
        self.path, self.out, self.every, self.stop = path, out, every, threading.Event()

    def run(self):
        with open(self.out, "w") as out:
            while not self.stop.wait(self.every):
                try:
                    value = self.path.read_text().strip()
                except OSError:
                    continue
                out.write(f"{time.monotonic_ns() // 1000} {value}\n")
                out.flush()


def record(directory, scenario, mode, session, manual):
    base = Path(directory) / f"{scenario}-{mode}"
    for suffix in (".json", ".client", ".syscap", ".gpu"):
        base.with_suffix(suffix).unlink(missing_ok=True)
    session.reduce_transparency(mode == "rt")
    time.sleep(SETTLE_S)
    capture = subprocess.Popen([SYSPROF, "--gnome-shell", "--no-sysprofd", "--no-perf", "--no-battery", "--no-cpu",
                                "--no-disk", "--no-memory", "--no-network", "--no-decode", "-f",
                                str(base.with_suffix(".syscap"))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    gpu = gpu_busy_path()
    sampler = Sampler(gpu, base.with_suffix(".gpu"), GPU_SAMPLE_S) if gpu and scenario == "A" else None
    if sampler:
        sampler.start()
    try:
        if manual:
            manual_scenario(base, scenario)
        else:
            options = {"seconds": SECONDS, "out": str(base.with_suffix(".json")),
                       "measure": str(base.with_suffix(".client")), "display": os.environ.get("WAYLAND_DISPLAY", "wayland-0")}
            module = (HERE / "scenarios.js").as_uri()
            ok, reply = shell_eval(f'import("{module}").then(m => m.start("{scenario}", {json.dumps(options)}))')
            if not ok:
                raise Refused(f"the shell refused Eval ({reply!r}): use --manual")
            deadline = time.monotonic() + SECONDS * 2 + 60
            while not base.with_suffix(".json").exists():
                if time.monotonic() > deadline:
                    raise RuntimeError(f"scenario {scenario} wrote no result")
                time.sleep(0.5)
    finally:
        if sampler:
            sampler.stop.set()
            sampler.join()
        capture.send_signal(signal.SIGINT)
        try:
            capture.wait(timeout=60)
        except subprocess.TimeoutExpired:
            capture.kill()


MANUAL_STEPS = {
    "A": "Put the load window over the dock and open Quick Settings over it.",
    "B": "Drag a window under the dock, then Quick Settings, then the calendar, for the whole minute.",
    "C": "Over the load window: toggle the overview and the app grid 20 times, then open Spotlight.",
}


def manual_scenario(base, scenario):
    client = None
    if scenario != "B":
        client = subprocess.Popen(["gjs", "-m", str(HERE.parent / "shots/load-window.js"),
                                   f"measure={base.with_suffix('.client')}"])
    try:
        input(f"{scenario}: {MANUAL_STEPS[scenario]} Press Enter to start {SECONDS:.0f} s. ")
        start = time.monotonic_ns() // 1000
        time.sleep(SECONDS)
        end = time.monotonic_ns() // 1000
        base.with_suffix(".json").write_text(json.dumps({"scenario": scenario, "startUs": start, "endUs": end,
                                                         "steps": [], "manual": True}))
    finally:
        if client:
            client.terminate()


def power_scenario(directory, scenario, session):
    out = Path(directory) / f"power-{scenario}.tsv"
    battery = next((d for d in command_output([UPOWER, "-e"]).split() if "battery_" in d), None)
    if not battery:
        raise Refused("upower lists no battery")
    with open(out, "w") as tsv:
        for run in range(POWER_RUNS):
            for mode in MODES:
                session.reduce_transparency(mode == "rt")
                busy = None
                if scenario == "A":
                    busy = threading.Thread(target=power_load, args=(directory, mode, run), daemon=True)
                    busy.start()
                begin = time.monotonic()
                while (since := time.monotonic() - begin) < POWER_RUN_SECONDS:
                    rate = re.search(r"energy-rate:\s+([\d.]+) W", command_output([UPOWER, "-i", battery]))
                    if rate:
                        tsv.write(f"{mode} {run} {since:.0f} {rate.group(1)}\n")
                        tsv.flush()
                    time.sleep(POWER_SAMPLE_S)
                if busy:
                    busy.join()


def power_load(directory, mode, run):
    base = Path(directory) / f"power-A-{mode}-{run}"
    module = (HERE / "scenarios.js").as_uri()
    options = {"seconds": POWER_RUN_SECONDS, "out": str(base.with_suffix(".json")),
               "measure": str(base.with_suffix(".client")), "display": os.environ.get("WAYLAND_DISPLAY", "wayland-0")}
    ok, reply = shell_eval(f'import("{module}").then(m => m.start("A", {json.dumps(options)}))')
    deadline = time.monotonic() + POWER_RUN_SECONDS * 2 + 60
    while ok and not base.with_suffix(".json").exists() and time.monotonic() < deadline:
        time.sleep(1)


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def start(args, power):
    out = Path(args.get("--out") or f"glass-protocol-{time.strftime('%Y%m%dT%H%M%S')}")
    checks = preflight(power)
    for name, ok in checks.items():
        print(f"preflight: {name}: {'yes' if ok else 'no'}")
    if not all(checks.values()) and not args.get("--ignore-preflight"):
        raise Refused("the preflight failed; fix it, or pass --ignore-preflight (the report says so)")
    out.mkdir(parents=True, exist_ok=True)
    manual = bool(args.get("--manual"))
    if manual and power and args.get("scenario") != "idle":
        raise Refused("power A drives scenario A through Eval: --manual takes only `power idle`")
    need_unsafe = not manual and (not power or args.get("scenario") != "idle")
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    session = Session(need_unsafe, bool(args.get("--yes-stale-unsafe")))
    meta = {"preflight": checks, "preflightIgnored": not all(checks.values()), "manual": manual,
            "seconds": SECONDS, "started": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    (out / "meta.json").write_text(json.dumps(meta))
    try:
        if power:
            for scenario in ([args["scenario"]] if args.get("scenario") else POWER_DELTA_MAX_W):
                power_scenario(out, scenario, session)
        else:
            for scenario in SCENARIOS:
                for mode in MODES:
                    print(f"{scenario}, {'Reduce Transparency' if mode == 'rt' else 'glass'}: {SECONDS:.0f} s", flush=True)
                    record(out, scenario, mode, session, manual)
    finally:
        session.close()
    return out


def parse(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0 if argv else 2)
    command, rest, args = argv[0], argv[1:], {}
    while rest:
        word = rest.pop(0)
        if word == "--out":
            args["--out"] = rest.pop(0)
        elif word.startswith("--"):
            args[word] = True
        elif command == "power" and word in POWER_DELTA_MAX_W:
            args["scenario"] = word
        else:
            args.setdefault("paths", []).append(word)
    return command, args


def main(argv):
    command, args = parse(argv)
    try:
        if command == "marks":
            for m in read_marks(args["paths"][0]):
                print(m.time, m.duration, m.pid, m.group, m.name, m.message, sep="\t")
            return 0
        if command in ("run", "power"):
            directory = start(args, command == "power")
        elif command == "score":
            directory = Path(args["paths"][0])
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Refused as refusal:
        print(f"glass-protocol: {refusal}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("glass-protocol: stopped", file=sys.stderr)
        return 130
    report = score(directory)
    (Path(directory) / "report.json").write_text(json.dumps(report, indent=1))
    print(table(report))
    print(f"report: {Path(directory) / 'report.json'}")
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
