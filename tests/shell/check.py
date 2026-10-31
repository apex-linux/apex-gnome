#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: check.py SHOTS_DIR

Asserts each shoot.sh case from its log's APEXLOCK lines and gdm-mock.py's log: what
boards 20 and 12 show, that no case unlocks, that a wrong answer leaves the screen
locked, that a GDM refusing to reauthenticate leaves it locked, that the fingerprint
conversation stops while the screen is blank, that blanking cancels the conversation and waking starts a new one, that
the key that wakes the screen never answers a prompt, that gnome-session's idle at lock leaves the prompt to blank, that resume brings back the prompt sleep took down, that
stock and safe mode keep upstream's lock, and that the greeter runs no Apex JS and no screencast service; what board 13's
authentication dialog shows, from a stubbed polkit session that is never answered; and board 34's
date menu: flat cards headed "app · time" with the app's icon, Clear on the right, Do Not Disturb;
and what the end-session dialog's update card does with update1-mock.py's Apply.
Prints one line per assertion and exits 1 when one fails.
"""

import itertools
import json
import os
import re
import sys

DATE = "Wednesday October 21"
TIME = "10:24"
HINT = "Press Enter to unlock"
PROBLEM = "Sorry, that didn't work. Please try again."
APEX_CLOCK = "unlock-dialog-clock-date unlock-dialog-clock-time"
STOCK_CLOCK = "unlock-dialog-clock-time unlock-dialog-clock-date unlock-dialog-clock-hint"
APEX_BLUR = "radius=60 brightness=1.00 saturation=1.30"
STOCK_BLUR = "radius=90 brightness=0.65 saturation=1.00"
LOAD_WITNESS = "Apex: APEX_SHELL_TEST_FAULT=load-witness names no phase"

# Per lock case: the layer's lock or upstream's, and the question its prompt shows.
LOCK_CASES = {
    "lock-light": {"apex": True, "question": "Enter Password"},
    "lock-dark": {"apex": True, "question": "Enter Password"},
    "lock-question": {"apex": True, "question": "Verification code:"},
    "lock-high-contrast": {"apex": True, "question": "Enter Password", "overlay_alpha": 0x8c},
    "lock-large-text": {"apex": True, "question": "Enter Password"},
    "lock-disabled": {"apex": False, "question": "Password", "layer": True},
    "lock-safe": {"apex": False, "question": "Password", "layer": False},
}
GREETER_CASES = ["greeter-light", "greeter-dark"]
# dbus-daemon logs each activation: a mode that cannot screencast has no use for the service (patch 0020).
SCREENCAST_STARTED = "Activating service name='org.gnome.Shell.Screencast'"
# Per polkit case: board 13's dialog or upstream's, and the info line PAM sent.
POLKIT_CASES = {
    "polkit-light": {"apex": True, "info": None},
    "polkit-dark": {"apex": True, "info": None},
    "polkit-fingerprint": {"apex": True, "info": "Place your finger on the fingerprint reader"},
    "polkit-disabled": {"apex": False, "info": None},
}
POLKIT_ACTION = "io.github.apex-linux.apex.update.rollback"
POLKIT_MESSAGE = "Booting the previous version of Apex at the next restart needs an administrator password."
POLKIT_TITLE = "Authentication Required"
POLKIT_WIDTH = 440
POLKIT_SHIELD = 56
POLKIT_SHIELD_TINT = 0.16
POLKIT_AVATAR = 32
STOCK_POLKIT_AVATAR = 64  # upstream sheet's .user-icon, not polkitAgent.js's 96
POLKIT_FIELD = 38
POLKIT_BUTTON = 36
AUTH_ERROR = "Authentication error"
WRONG_ANSWER = "not-the-password"

TOKENS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../desktop/shell/data/theme/apex/_apex-tokens.scss")
LOGO = "/usr/share/pixmaps/apex-gdm-logo.svg"
LOGO_HEIGHT = 48

failed = 0


def tokens():
    found = {}
    with open(TOKENS, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"\$(apex_(?:greeter|lock)_\w+):\s*(.+?);", line)
            if m:
                found[m.group(1)] = m.group(2).strip("'\"")
    return found


def px(value):
    return float(value.removesuffix("px"))


def rgba(value):
    m = re.fullmatch(r"#([0-9a-f]{6})", value)
    if m:
        return [int(m.group(1)[i:i + 2], 16) for i in (0, 2, 4)] + [255]
    m = re.fullmatch(r"rgba\((\d+), (\d+), (\d+), ([.\d]+)\)", value)
    return [int(m.group(i)) for i in (1, 2, 3)] + [round(float(m.group(4)) * 255)]


def same_colour(got, want):
    got = [int(got[i:i + 2], 16) for i in (1, 3, 5, 7)]
    return all(abs(a - b) <= 1 for a, b in zip(got, rgba(want)))


def check(name, ok, detail=""):
    global failed
    if ok:
        print(f"ok - {name}")
    else:
        failed += 1
        print(f"not ok - {name}{': ' + detail if detail else ''}")


def facts(log):
    found = {}
    for line in log.splitlines():
        m = re.search(r"APEXLOCK (\{.*\})$", line)
        if m:
            found.update(json.loads(m.group(1)))
    return found


def read(shots, name):
    with open(os.path.join(shots, name), encoding="utf-8") as f:
        return f.read()


def until(log, last_fact):
    """The log up to the probe's last fact: the shell's exit while locked pops a modal upstream."""
    end = log.find(f'APEXLOCK {{"{last_fact}"')
    return log if end < 0 else log[:end]


def channels(gdm_log):
    """Each verifier channel's calls and signals, in order."""
    by_channel = {}
    for line in gdm_log.splitlines():
        m = re.match(r"channel (\d+): (.*)$", line)
        if m:
            by_channel.setdefault(int(m.group(1)), []).append(m.group(2))
    return by_channel


# Top to bottom, as board 20 stacks them.
LAYOUT_ORDER = ("date", "time", "avatar", "field", "message", "hint")
# $apex_lock_overlay, rgba(8, 10, 20, .34); the high-contrast sheet's own is darker.
OVERLAY = "#080a1457"


def check_layout(case, layout, overlay_alpha=None):
    screen = layout.get("screen") or {}
    parts = [(name, layout[name]) for name in LAYOUT_ORDER if name in layout]
    off = [name for name, b in parts if b["x"] < screen.get("x", 0) or b["y"] < screen.get("y", 0)
           or b["x"] + b["width"] > screen.get("x", 0) + screen.get("width", 0) + 1
           or b["y"] + b["height"] > screen.get("y", 0) + screen.get("height", 0) + 1]
    check(f"{case}: date, time, avatar, field and hint are all on screen",
          {"date", "time", "avatar", "field", "hint"} <= dict(parts).keys() and not off, json.dumps(layout))
    overlaps = [f"{a}/{b}" for (a, ba), (b, bb) in itertools.pairwise(parts) if ba["y"] + ba["height"] > bb["y"] + 1]
    check(f"{case}: top to bottom, nothing overlaps", not overlaps, ", ".join(overlaps))
    if overlay_alpha is None and {"avatar", "field", "hint"} <= dict(parts).keys():
        check_spacing(case, layout)
    got = layout.get("overlay") or ""
    if overlay_alpha is None:
        check(f"{case}: the overlay darkens as $apex_lock_overlay", got == OVERLAY, got)
    else:
        check(f"{case}: high contrast darkens more, to alpha {overlay_alpha:#x}",
              got[:7] == "#000000" and len(got) == 9 and int(got[7:], 16) >= overlay_alpha, got)


def check_spacing(case, layout):
    """Board 20's prompt, top to bottom, as the Apex sheets space it: a GNOME point release's margins fail here by name."""
    gap = px(tokens()["apex_lock_prompt_gap"])
    avatar, field, hint, line = layout["avatar"], layout["field"], layout["hint"], layout.get("messageLine")
    field_end = field["y"] + field["height"]
    check(f"{case}: the field sits $apex_lock_prompt_gap ({gap:g} px) below the name",
          abs(field["y"] - avatar["y"] - avatar["height"] - gap) <= 1, json.dumps([avatar, field]))
    if line:
        check(f"{case}: upstream's message line starts where the field ends", abs(line["y"] - field_end) <= 1,
              json.dumps([field, line]))
    above = line["y"] + line["height"] if line else field_end
    check(f"{case}: the hint starts where the {'message line' if line else 'field'} ends", abs(hint["y"] - above) <= 1,
          json.dumps([field, line, hint]))


def check_reveal(case, reveal):
    """Board 20: the show-password eye ends where the entry's end padding begins, centred on the field."""
    if not reveal:
        check(f"{case}: the field shows its show-password eye", False, "no mapped secondary icon")
        return
    entry, icon = reveal["entry"], reveal["icon"]
    end = entry["x"] + entry["width"] - reveal["border"] - reveal["padding"]
    centre = entry["y"] + entry["height"] / 2
    check(f"{case}: the show-password eye sits at the field's end, inside its padding",
          abs(icon["x"] + icon["width"] - reveal["iconPadding"] - end) <= 1, json.dumps(reveal))
    check(f"{case}: the show-password eye is centred on the field",
          abs(icon["y"] + icon["height"] / 2 - centre) <= 1, json.dumps(reveal))


def check_lock(shots, case, want):
    log = read(shots, f"{case}.log")
    gdm = read(shots, f"{case}.gdm.log")
    f = facts(log)
    check(f"{case}: the user session starts the screencast service, for the screenshot UI's cast button",
          SCREENCAST_STARTED in log)
    steps = ("opened", "wrong-answer", "blank", "wake", "escape", "key-after-escape", "end")
    for step in steps:
        check(f"{case}: {step} is reported", step in f)
    if not all(step in f for step in steps):
        return
    for step in steps:
        check(f"{case}: {step}: locked", f[step]["locked"] is True)
    check(f"{case}: GDM never completes a verification", "VerificationComplete" not in gdm)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "end") and "APEXLOCK-ERROR" not in log)
    opened, wrong, blank, wake = f["opened"], f["wrong-answer"], f["blank"], f["wake"]
    check(f"{case}: the date and the time", (opened["date"], opened["time"]) == (DATE, TIME),
          f"{opened['date']} {opened['time']}")
    calls = channels(gdm)
    # The probe's wrong answer, by its length; stock may also take the Return after Esc as an empty one.
    answered = [c for c, lines in calls.items() if f"AnswerQuery gdm-password ({len(WRONG_ANSWER)} characters)" in lines]
    check(f"{case}: the wrong answer reached GDM once", len(answered) == 1, str(answered))
    if answered:
        lines = calls[answered[0]]
        check(f"{case}: and GDM failed it", "signal VerificationFailed gdm-password" in lines)
    check(f"{case}: the prompt shows the failure", (wrong["prompt"] or {}).get("message") == PROBLEM,
          json.dumps(wrong["prompt"]))
    check(f"{case}: the question", (wrong["prompt"] or {}).get("question") == want["question"],
          json.dumps(wrong["prompt"]))
    if want["apex"]:
        check(f"{case}: one stage", "apex-lock" in opened["classes"].split())
        check(f"{case}: sigma 30, saturation 1.3, no darkening", opened["blur"] == APEX_BLUR, str(opened["blur"]))
        check(f"{case}: date above time, no upstream hint", opened["clock"] == APEX_CLOCK, opened["clock"])
        check(f"{case}: the unlock hint", opened["hint"] == HINT, str(opened["hint"]))
        check(f"{case}: the prompt is up at once", opened["prompt"] is not None)
        check(f"{case}: the initial-letter avatar", (opened["prompt"] or {}).get("avatar") == "initial A",
              json.dumps(opened["prompt"]))
        check(f"{case}: the user's name", (opened["prompt"] or {}).get("name") == "Apex")
        check_layout(case, opened.get("layout") or {}, want.get("overlay_alpha"))
        if want["question"] == "Enter Password":
            check_reveal(case, (opened.get("layout") or {}).get("reveal"))
        check(f"{case}: blanking takes the prompt down", blank["prompt"] is None, json.dumps(blank["prompt"]))
        if answered:
            check(f"{case}: and cancels its conversation", "Cancel" in calls[answered[0]])
        later = [c for c in calls if answered and c > answered[0] and
                 any(x.startswith("BeginVerificationForUser gdm-password") for x in calls[c])]
        check(f"{case}: waking starts a new conversation", bool(later) and wake["prompt"] is not None,
              f"channels {sorted(calls)}")
        check(f"{case}: the layer loaded", LOAD_WITNESS in log)
        check(f"{case}: the teardown is logged once", log.count("Apex: lock: screen blank, prompt torn down") == 1)
        check(f"{case}: and the rebuild", log.count("Apex: lock: screen on, prompt rebuilt") == 1)
        check(f"{case}: Esc ends the conversation", f["escape"]["prompt"] is None, json.dumps(f["escape"]["prompt"]))
        check(f"{case}: a key starts another", f["key-after-escape"]["prompt"] is not None and
              sum(any(x.startswith("BeginVerificationForUser") for x in lines) for lines in calls.values()) >= 3,
              f"channels {sorted(calls)}")
    else:
        check(f"{case}: upstream's two stages", "apex-lock" not in opened["classes"].split())
        check(f"{case}: upstream's blur", opened["blur"] == STOCK_BLUR, str(opened["blur"]))
        check(f"{case}: upstream's clock with its hint", opened["clock"] == STOCK_CLOCK, opened["clock"])
        check(f"{case}: no prompt until a key", opened["prompt"] is None)
        check(f"{case}: upstream's avatar icon", (wrong["prompt"] or {}).get("avatar") == "avatar-default-symbolic")
        check(f"{case}: upstream keeps its prompt at blank", blank["prompt"] is not None)
        check(f"{case}: the layer {'loaded' if want['layer'] else 'did not load'}",
              (LOAD_WITNESS in log) == want["layer"])


def between(gdm_log, start, end):
    """The mock's lines after the probe's step START and before END ("" for the log's start)."""
    lines = gdm_log.splitlines()
    first = lines.index(f"-- {start}") + 1 if start else 0
    last = lines.index(f"-- {end}", first)
    return lines[first:last]


FINGERPRINT_HINT = "Or touch the fingerprint reader"
FINGERPRINT_FAILED = "Fingerprint not recognized. Try again."
FINGERPRINT_GLYPH = "auth-fingerprint-symbolic"


def fingerprint_line(step, text, failed):
    return (step.get("hint") == text and step.get("hintGlyph") == FINGERPRINT_GLYPH and step.get("hintFailed") is failed
            and not (step.get("prompt") or {}).get("messageShown"))


def check_fingerprint(shots, case):
    log, gdm = read(shots, f"{case}.log"), read(shots, f"{case}.gdm.log")
    f = facts(log)
    steps = ("opened", "scan-failed", "blank", "still-blank", "wake", "end")
    check(f"{case}: every step is reported", all(step in f for step in steps))
    if not all(step in f for step in steps):
        return
    for step in steps:
        check(f"{case}: {step}: locked", f[step]["locked"] is True)
    check(f"{case}: GDM never completes a verification", "VerificationComplete" not in gdm)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "end") and "APEXLOCK-ERROR" not in log)
    check(f"{case}: the shell found fprintd's reader", "GetDefaultDevice" in read(shots, f"{case}.fprintd.log"))
    begun = "BeginVerificationForUser gdm-fingerprint apex"
    check(f"{case}: a fingerprint conversation runs beside the password one",
          any(line.endswith(begun) for line in between(gdm, "", "opened")))
    check(f"{case}: board 20's line says so with the print, in place of upstream's message line",
          fingerprint_line(f["opened"], FINGERPRINT_HINT, False), json.dumps(f["opened"]))
    check(f"{case}: upstream's fingerprint indicator stands aside", f["opened"].get("indicator") is False, json.dumps(f["opened"]))
    check(f"{case}: a failed scan swaps the line's text, and the screen stays locked",
          fingerprint_line(f["scan-failed"], FINGERPRINT_FAILED, True), json.dumps(f["scan-failed"]))
    before_blank = between(gdm, "capture.scan-failed", "blank")
    check(f"{case}: blanking cancels the conversation the reader was in", any(line.endswith(": Cancel") for line in before_blank),
          json.dumps(before_blank))
    blank = between(gdm, "blank", "still-blank")
    check(f"{case}: while blank, no conversation starts and the reader is left alone", blank == [], json.dumps(blank))
    check(f"{case}: blank: no prompt", f["blank"]["prompt"] is None and f["still-blank"]["prompt"] is None)
    check(f"{case}: waking starts the reader's conversation again",
          any(line.endswith(begun) for line in between(gdm, "still-blank", "wake")) and f["wake"]["prompt"] is not None)
    check(f"{case}: and the new prompt's line is the reader's again, not the failure",
          fingerprint_line(f["wake"], FINGERPRINT_HINT, False), json.dumps(f["wake"]))


def check_fingerprint_suspend(shots, case):
    log, gdm = read(shots, f"{case}.log"), read(shots, f"{case}.gdm.log")
    f = facts(log)
    steps = ("opened", "scan-failed", "asleep", "still-asleep", "resumed", "resumed-scan-failed", "end")
    check(f"{case}: every step is reported", all(step in f for step in steps))
    if not all(step in f for step in steps):
        return
    for step in steps:
        check(f"{case}: {step}: locked", f[step]["locked"] is True)
    check(f"{case}: GDM never completes a verification", "VerificationComplete" not in gdm)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "end") and "APEXLOCK-ERROR" not in log)
    check(f"{case}: a failed scan before sleep swaps the line", fingerprint_line(f["scan-failed"], FINGERPRINT_FAILED, True),
          json.dumps(f["scan-failed"]))
    before = between(gdm, "scan-failed", "asleep")
    check(f"{case}: sleep cancels the conversations the reader and the password were in",
          any(line.endswith(": Cancel") for line in before), json.dumps(before))
    check(f"{case}: asleep: no prompt", f["asleep"]["prompt"] is None and f["still-asleep"]["prompt"] is None)
    asleep = between(gdm, "asleep", "still-asleep")
    check(f"{case}: while asleep, no conversation starts and the reader is left alone", asleep == [], json.dumps(asleep))
    resumed = between(gdm, "still-asleep", "resumed")
    opened = [m.group(1) for m in map(re.compile(r"channel (\d+): connected$").match, resumed) if m]
    live = [c for c in opened if f"channel {c}: Cancel" not in resumed]
    # Upstream's prompt opens a channel and cancels it before the one it keeps, at wake as at resume.
    check(f"{case}: resume leaves one channel running the password's and the reader's conversations",
          len(live) == 1 and all(f"channel {live[0]}: BeginVerificationForUser {service} apex" in resumed
                                 for service in ("gdm-password", "gdm-fingerprint")), json.dumps(resumed))
    check(f"{case}: and the line is the reader's again, not the failure from before sleep",
          fingerprint_line(f["resumed"], FINGERPRINT_HINT, False), json.dumps(f["resumed"]))
    check(f"{case}: upstream's fingerprint indicator still stands aside", f["resumed"].get("indicator") is False,
          json.dumps(f["resumed"]))
    check(f"{case}: a failed scan after resume swaps the line, and the screen stays locked",
          fingerprint_line(f["resumed-scan-failed"], FINGERPRINT_FAILED, True), json.dumps(f["resumed-scan-failed"]))
    check(f"{case}: logged as qualify.sh reads it", (log.count("Apex: lock: suspend, prompt torn down"),
                                                    log.count("Apex: lock: screen on, prompt rebuilt")) == (1, 1))


def check_refused(shots, case):
    log = read(shots, f"{case}.log")
    f = facts(log)
    steps = ("opened", "wrong-answer", "blank", "wake", "escape", "key-after-escape", "end")
    check(f"{case}: every step is reported", all(s in f for s in steps))
    check(f"{case}: GDM refused every channel", "OpenReauthenticationChannel" in read(shots, f"{case}.gdm.log")
          and "channel " not in read(shots, f"{case}.gdm.log"))
    for step in steps:
        check(f"{case}: {step}: locked", f.get(step, {}).get("locked") is True)
    check(f"{case}: the prompt says so", (f.get("opened", {}).get("prompt") or {}).get("message") == AUTH_ERROR,
          json.dumps(f.get("opened", {}).get("prompt")))


# AuthPromptStatus.VERIFYING: a conversation runs and no answer is on its way.
VERIFYING = 1


def check_wake_key(shots, case, torn_down):
    """apex-image's local-lock-esc: a Return arriving after the wake's notify gets one prompt and answers nothing."""
    log = read(shots, f"{case}.log")
    gdm = read(shots, f"{case}.gdm.log")
    f = facts(log)
    steps = ("blank", "woken", "end")
    check(f"{case}: every step is reported", all(s in f for s in steps))
    if not all(s in f for s in steps):
        return
    for step in steps:
        check(f"{case}: {step}: locked", f[step]["locked"] is True)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "end") and "APEXLOCK-ERROR" not in log)
    check(f"{case}: blank: no prompt", f["blank"]["prompt"] is None, json.dumps(f["blank"]["prompt"]))
    woken = f["woken"]
    check(f"{case}: woken: one prompt, its conversation running and asking",
          woken["status"] == VERIFYING and (woken["prompt"] or {}).get("question") == "Enter Password", json.dumps(woken))
    begun = [line for line in between(gdm, "blank", "woken") if re.match(r"channel \d+: BeginVerificationForUser gdm-password", line)]
    check(f"{case}: one conversation after the wake", len(begun) == 1, json.dumps(begun))
    check(f"{case}: the key is no answer", "AnswerQuery" not in gdm)
    torn, rebuilt = (log.count(f"Apex: lock: screen {line}") for line in ("blank, prompt torn down", "on, prompt rebuilt"))
    if torn_down:
        check(f"{case}: locked while blank: the lock's prompt torn down, then rebuilt at wake", (torn, rebuilt) == (1, 1),
              f"torn down {torn}, rebuilt {rebuilt}")
    else:
        check(f"{case}: upstream's clock page: nothing torn down or rebuilt, the key brings upstream's prompt",
              (torn, rebuilt) == (0, 0), f"torn down {torn}, rebuilt {rebuilt}")


def check_idle(shots, case):
    """apex-image's local-lock-blank-wake: gnome-session's IDLE at lock leaves the lock's prompt for blank to tear down."""
    log = read(shots, f"{case}.log")
    gdm = read(shots, f"{case}.gdm.log")
    f = facts(log)
    steps = ("locked", "idle", "blank", "woken", "end")
    check(f"{case}: every step is reported", all(s in f for s in steps))
    if not all(s in f for s in steps):
        return
    for step in steps:
        check(f"{case}: {step}: locked", f[step]["locked"] is True)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "end") and "APEXLOCK-ERROR" not in log)
    check(f"{case}: idle keeps the lock's prompt and its conversation",
          f["idle"]["prompt"] is not None and f["idle"]["status"] == VERIFYING, json.dumps(f["idle"]))
    check(f"{case}: idle cancels nothing", not any(line.endswith(": Cancel") for line in between(gdm, "locked", "idle")),
          json.dumps(between(gdm, "locked", "idle")))
    check(f"{case}: blank tears the prompt down", f["blank"]["prompt"] is None and
          log.count("Apex: lock: screen blank, prompt torn down") == 1, json.dumps(f["blank"]["prompt"]))
    begun = [line for line in between(gdm, "blank", "woken") if re.match(r"channel \d+: BeginVerificationForUser gdm-password", line)]
    check(f"{case}: the wake rebuilds it, with a conversation and no key", len(begun) == 1 and
          log.count("Apex: lock: screen on, prompt rebuilt") == 1 and f["woken"]["status"] == VERIFYING and
          (f["woken"]["prompt"] or {}).get("question") == "Enter Password", json.dumps(begun))


def check_suspend(shots, case):
    """logind's PrepareForSleep: the conversation ends before sleep, none runs asleep, and resume brings the prompt back."""
    log = read(shots, f"{case}.log")
    gdm = read(shots, f"{case}.gdm.log")
    f = facts(log)
    steps = ("locked", "asleep", "still-asleep", "resumed", "end")
    check(f"{case}: every step is reported", all(s in f for s in steps))
    if not all(s in f for s in steps):
        return
    for step in steps:
        check(f"{case}: {step}: locked", f[step]["locked"] is True)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "end") and "APEXLOCK-ERROR" not in log)
    check(f"{case}: sleep ends the conversation", f["asleep"]["prompt"] is None and
          any(line.endswith(": Cancel") for line in between(gdm, "locked", "asleep")), json.dumps(between(gdm, "locked", "asleep")))
    check(f"{case}: none starts while asleep", not any("BeginVerification" in line for line in between(gdm, "asleep", "still-asleep")),
          json.dumps(between(gdm, "asleep", "still-asleep")))
    begun = [line for line in between(gdm, "still-asleep", "resumed")
             if re.match(r"channel \d+: BeginVerificationForUser gdm-password", line)]
    check(f"{case}: resume brings the prompt back, with a conversation and no key", len(begun) == 1 and
          f["resumed"]["status"] == VERIFYING and (f["resumed"]["prompt"] or {}).get("question") == "Enter Password",
          json.dumps(begun))
    torn, rebuilt = "Apex: lock: suspend, prompt torn down", "Apex: lock: screen on, prompt rebuilt"
    check(f"{case}: both logged once, the rebuild as qualify.sh's screen-on line after the teardown",
          (log.count(torn), log.count(rebuilt)) == (1, 1) and log.index(torn) < log.index(rebuilt))


def check_greeter(shots, case):
    log = read(shots, f"{case}.log")
    f = facts(log)
    check(f"{case}: the list and the prompt are reported", "list" in f and "prompt" in f)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "capture.prompt") and "APEXLOCK-ERROR" not in log)
    # load-witness is in the greeter's environment too: layer.js would warn as it loads.
    check(f"{case}: apex/layer.js never loads", LOAD_WITNESS not in log)
    check(f"{case}: no Apex line at all", not re.search(r"\bApex: ", log))
    check(f"{case}: the screencast service never starts: gdm mode cannot screencast", SCREENCAST_STARTED not in log)
    if "list" not in f or "prompt" not in f:
        return
    check(f"{case}: the user list", f["list"]["users"] == "apex guest", f["list"]["users"])
    prompt = f["prompt"]["prompt"] or {}
    check(f"{case}: upstream's question", prompt.get("question") == "Password", json.dumps(prompt))
    check(f"{case}: upstream's avatar icon", prompt.get("avatar") == "avatar-default-symbolic", json.dumps(prompt))
    check_greeter_style(case, f["list"].get("style") or {}, tokens())
    check_back_button(case, (f["prompt"].get("style") or {}).get("back"), tokens())


def round_button(b, t):
    size = px(t["apex_greeter_button_size"])
    return (abs(b["height"] - size) <= 1 and abs(b["width"] - size) <= 1 and b["radius"] * 2 >= size and b["border"] == 1
            and same_colour(b["background"], t["apex_greeter_button"]) and same_colour(b["borderColor"], t["apex_greeter_button_border"]))


def check_back_button(case, back, t):
    check(f"{case}: the prompt's back button is a {t['apex_greeter_button_size']} circle in {t['apex_greeter_button']}, "
          f"ringed in {t['apex_greeter_button_border']}", back is not None and round_button(back, t), json.dumps(back))


def check_greeter_style(case, style, t):
    screen, background = style.get("screen") or {}, style.get("background") or {}
    bottom = screen.get("y", 0) + screen.get("height", 0)
    check(f"{case}: board 12's pre-blurred background, over a fallback of its mean colour",
          background.get("image") == t["apex_greeter_background"] and same_colour(background.get("color", ""), t["apex_greeter_fallback"]),
          json.dumps(background))
    logo = style.get("logo") or {}
    check(f"{case}: the footer is apex-desktop's logo, {LOGO_HEIGHT} px tall, centred "
          f"{t['apex_greeter_bottom']} above the bottom edge",
          logo.get("file") == LOGO and abs(logo.get("height", 0) - LOGO_HEIGHT) <= 1
          and abs(bottom - logo.get("y", 0) - logo.get("height", 0) - px(t["apex_greeter_bottom"])) <= 1
          and abs(logo.get("x", 0) + logo.get("width", 0) / 2 - screen.get("x", 0) - screen.get("width", 0) / 2) <= 1,
          json.dumps({"logo": logo, "screen": screen}))
    buttons = style.get("buttons") or []
    check(f"{case}: the bottom buttons are {t['apex_greeter_button_size']} circles in {t['apex_greeter_button']}, "
          f"ringed in {t['apex_greeter_button_border']}, {t['apex_greeter_bottom']} from the bottom edge",
          len(buttons) > 0 and all(round_button(b, t) and abs(bottom - b["y"] - b["height"] - px(t["apex_greeter_bottom"])) <= 1
                                   for b in buttons),
          json.dumps(buttons))


END_SESSION_CASES = ["end-session-light", "end-session-dark"]
STAGED_DIGEST = "sha256:9e41aa07c3b2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c80c2b"
UPDATE_TITLE = "Start the new version next time"
UPDATE_SUBTITLE = "45.20261010.133 · GNOME 51.1, Linux 7.2.9, Mesa 26.1.2"
POLICY_DENIED = "Plug in the charger to install the update."


def card_is(step, on, sensitive=True, subtitle=UPDATE_SUBTITLE):
    card = step.get("card") or {}
    return (card.get("title") == UPDATE_TITLE and card.get("subtitle") == subtitle and card.get("on") is on
            and card.get("sensitive") is sensitive and card.get("icon") == "system-software-update")


def check_end_session(shots, case):
    """Board 14's update card against update1-mock.py: where it shows, and what Apply sees."""
    f = facts(read(shots, f"{case}.log"))

    def step(name):
        return f.get(name) or {}

    def detail(*names):
        return json.dumps({n: f.get(n) for n in names})

    check(f"{case}: the power-off dialog lists no other user logged in: the greeter's session is of class greeter",
          step("up-to-date").get("otherSessions", 1) == 0 and step("staged").get("otherSessions", 1) == 0,
          detail("up-to-date", "staged"))
    check(f"{case}: Update1 up to date: no card, the power-off dialog's own buttons",
          step("up-to-date").get("card", 1) is None and step("up-to-date").get("buttons") == ["Cancel", "Restart", "Power Off"],
          detail("up-to-date"))
    check(f"{case}: staged, but never in the log-out dialog", "logout" in f and step("logout").get("card", 1) is None, detail("logout"))
    check(f"{case}: staged: the card, its switch on, Restart reads Restart & Update",
          card_is(step("staged"), True) and step("staged").get("buttons") == ["Cancel", "Restart & Update"], detail("staged"))
    check(f"{case}: staged: Restart & Update applies the staged digest, then restarts",
          step("staged-pressed").get("apply") == [STAGED_DIGEST] and step("staged-pressed").get("signals") == ["ConfirmedReboot"]
          and step("staged-pressed").get("open") is False, detail("staged-pressed"))
    check(f"{case}: switched off: Restart reads Restart again",
          card_is(step("switched-off"), False) and step("switched-off").get("buttons") == ["Cancel", "Restart", "Power Off"],
          detail("switched-off"))
    check(f"{case}: switched off: Power Off powers off without Apply, the stage left locked",
          step("switched-off-pressed").get("apply") == [] and step("switched-off-pressed").get("signals") == ["ConfirmedShutdown"],
          detail("switched-off-pressed"))
    check(f"{case}: ready-for-reboot: the card, its switch on and insensitive, Restart & Update",
          card_is(step("ready"), True, sensitive=False) and step("ready").get("buttons") == ["Cancel", "Restart & Update"], detail("ready"))
    check(f"{case}: ready-for-reboot: Restart & Update restarts, nothing left to apply",
          step("ready-pressed").get("apply") == [] and step("ready-pressed").get("signals") == ["ConfirmedReboot"], detail("ready-pressed"))
    check(f"{case}: Apply fails on a press: the dialog stays open with PolicyDenied's message, the switch off, nothing confirmed",
          step("apply-failed").get("open") is True and card_is(step("apply-failed"), False, subtitle=POLICY_DENIED)
          and step("apply-failed").get("apply") == [STAGED_DIGEST] and step("apply-failed").get("signals") == [],
          detail("apply-failed"))
    signals = step("apply-failed-cancelled").get("signals")
    check(f"{case}: then Cancel cancels: the failed press's confirmation never comes",
          isinstance(signals, list) and "Canceled" in signals and not any(s.startswith("Confirmed") for s in signals),
          detail("apply-failed-cancelled"))
    check(f"{case}: Apply fails as the countdown ends: the countdown still restarts",
          step("countdown-failed").get("apply") == [STAGED_DIGEST] and step("countdown-failed").get("signals") == ["ConfirmedReboot"],
          detail("countdown-failed"))


def near(got, want):
    return abs(got - want) <= 1


POLKIT_LOCKED_CASES = {"polkit-lock": (True, False), "polkit-suspend": (True, True), "polkit-lock-safe": (False, False)}


def check_polkit_locked(shots, case, apex, sleeps):
    log, gdm = read(shots, f"{case}.log"), read(shots, f"{case}.gdm.log")
    f = facts(log)
    steps = ("polkit", "locked", "typed", "unlocked") + (("asleep",) if sleeps else ())
    check(f"{case}: every step is reported", all(step in f for step in steps))
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "unlocked") and "APEXLOCK-ERROR" not in log)
    if not all(step in f for step in steps):
        return
    before = f["polkit"]["polkit"]
    check(f"{case}: the dialog opens, focused, {'board 13' if apex else 'upstream'}'s",
          before["opened"] and before["visible"] and before["field"]["focused"]
          and ("apex-polkit" in (before["classes"] or "")) is apex, json.dumps(before))
    for step in ("locked", "typed"):
        d, lock = f[step]["polkit"], f[step]["lock"]
        check(f"{case}: {step}: locked, the dialog hidden under the lock and still its request's",
              f[step]["locked"] and not d["visible"] and not d["mapped"] and d["current"], json.dumps(d))
        check(f"{case}: {step}: the lock is {'the one stage with its prompt' if apex else 'upstream'}'s",
              ("apex-lock" in lock["classes"].split()) is apex and (not apex or lock["prompt"] is not None),
              json.dumps({k: lock[k] for k in ("classes", "prompt")}))
    typed = between(gdm, "locked", "typed")
    check(f"{case}: the keys typed at the lock answer the lock's question, not the dialog's",
          any(re.search(rf": AnswerQuery gdm-password \({len(WRONG_ANSWER)} characters\)$", line) for line in typed)
          and f["typed"]["sessions"] == [{"responses": 0, "cancelled": False}], json.dumps([typed, f["typed"]["sessions"]]))
    after = f["unlocked"]
    check(f"{case}: the lock ends on the same dialog, shown again with its request, nothing answered or cancelled",
          not after["locked"] and after["polkit"]["visible"] and after["polkit"]["opened"] and after["polkit"]["current"]
          and after["sessions"] == [{"responses": 0, "cancelled": False}], json.dumps(after))
    check(f"{case}: still {'board 13' if apex else 'upstream'}'s",
          ("apex-polkit" in (after["polkit"]["classes"] or "")) is apex, after["polkit"]["classes"])


def check_polkit(shots, case, want):
    log = read(shots, f"{case}.log")
    f = facts(log)
    check(f"{case}: the dialog and its sessions are reported", "polkit" in f and "polkit-sessions" in f)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "polkit-sessions") and "APEXLOCK-ERROR" not in log)
    if "polkit" not in f or "polkit-sessions" not in f:
        return
    d, sessions = f["polkit"], f["polkit-sessions"]
    check(f"{case}: the dialog opens on the session's request", d["opened"], json.dumps(d))
    check(f"{case}: one session, never answered, so nothing is authorised",
          sessions == [{"responses": 0, "cancelled": False}], json.dumps(sessions))
    check(f"{case}: upstream's title and polkit's message", d["title"] == POLKIT_TITLE and d["description"] == POLKIT_MESSAGE,
          json.dumps([d["title"], d["description"]]))
    check(f"{case}: the field asks for the password, focused", d["field"]["hint"] == "Password" and d["field"]["focused"],
          json.dumps(d["field"]))
    check(f"{case}: Cancel and Authenticate", [b["label"] for b in d["buttons"]] == ["Cancel", "Authenticate"],
          json.dumps(d["buttons"]))
    if not want["apex"]:
        check(f"{case}: upstream's dialog: no shield, no role, no Details",
              "apex-polkit" not in (d["classes"] or "") and d["shield"] is None and d["role"] is None and d["details"] is None,
              json.dumps(d))
        check(f"{case}: upstream's {STOCK_POLKIT_AVATAR} px avatar over the name",
              near(d["avatar"]["height"], STOCK_POLKIT_AVATAR) and d["avatar"]["y"] + d["avatar"]["height"] <= d["name"]["y"] + 1,
              json.dumps([d["avatar"], d["name"]]))
        return
    box, shield = d["box"], d["shield"] or {}
    check(f"{case}: board 13's {POLKIT_WIDTH} px dialog", "apex-polkit" in (d["classes"] or "") and near(box["width"], POLKIT_WIDTH),
          json.dumps(box))
    check(f"{case}: the shield in a {POLKIT_SHIELD} px accent circle, centred",
          shield.get("icon") == "dialog-password-symbolic" and near(shield.get("width", 0), POLKIT_SHIELD)
          and near(shield.get("height", 0), POLKIT_SHIELD)
          and near(shield.get("x", 0) + POLKIT_SHIELD / 2, box["x"] + box["width"] / 2)
          and abs(int(shield.get("background", "#00000000")[-2:], 16) - POLKIT_SHIELD_TINT * 255) <= 1,
          json.dumps(shield))
    avatar, name, role = d["avatar"], d["name"], d["role"] or {}
    check(f"{case}: the user row: a {POLKIT_AVATAR} px avatar with the initial, the name beside it",
          near(avatar["width"], POLKIT_AVATAR) and d["initial"] == "A" and name["text"] == "Apex"
          and name["x"] >= avatar["x"] + avatar["width"], json.dumps([avatar, name]))
    check(f"{case}: \"Administrator\" under the name", role.get("text") == "Administrator" and role.get("y", 0) >= name["y"] + name["height"] - 1,
          json.dumps(role))
    field, details = d["field"], d["details"] or {}
    check(f"{case}: a {POLKIT_FIELD} px field", near(field["height"], POLKIT_FIELD), json.dumps(field))
    check(f"{case}: Details open, with the action and polkit's vendor",
          details.get("open") and details.get("rows") == [["Action", POLKIT_ACTION], ["Vendor", "Apex"]], json.dumps(details))
    check(f"{case}: polkitd answered the vendor lookup", "Apex: polkit: no vendor" not in log)
    buttons = d["buttons"]
    check(f"{case}: top to bottom: shield, user, field, Details, buttons",
          shield.get("y", 0) < avatar["y"] < field["y"] < details.get("y", 0) < buttons[0]["y"], json.dumps(d))
    check(f"{case}: {POLKIT_BUTTON} px buttons", all(near(b["height"], POLKIT_BUTTON) for b in buttons), json.dumps(buttons))
    info = d["info"]
    if want["info"]:
        check(f"{case}: pam_fprintd's prompt is board 13's fingerprint line",
              info["text"] == want["info"] and "apex-polkit-fingerprint" in info["line"] and info["glyph"] == "auth-fingerprint-symbolic",
              json.dumps(info))
    else:
        check(f"{case}: no fingerprint line when PAM sends none", info["text"] is None and info["glyph"] is None, json.dumps(info))


DND_LABEL = "Do Not Disturb"
ICON_SIZE = 32
MESSAGE_GAP = 8  # $apex_message_gap
ROW_GAP = 12  # $apex_banner_gap
FOOTER_INSET = 8
DATE_MENU_STEPS = ("none", "one", "many", "cleared")
DATE_MENU_APPS = ["Settings", "Calendar", "Terminal", "Files"]


def check_footer(case, step, menu, apex):
    clear, footer, dnd = menu["clear"], menu["footer"], menu["dnd"]
    empty = not menu["groups"]
    check(f"{case}: {step}: the placeholder {'shows' if empty else 'hides'}", menu["empty"] is empty)
    if apex:
        check(f"{case}: {step}: Clear is shown, and works only with cards",
              clear["visible"] is True and clear["reactive"] is (not empty), json.dumps(clear))
        check(f"{case}: {step}: Clear sits at the footer's right",
              0 <= footer["x"] + footer["width"] - clear["x"] - clear["width"] <= FOOTER_INSET,
              json.dumps({"clear": clear, "footer": footer}))
        check(f"{case}: {step}: Do Not Disturb comes first, labelled",
              dnd is not None and "apex-dnd-button" in (footer["children"][0] or "") and dnd["label"] == DND_LABEL,
              json.dumps(dnd))
        check(f"{case}: {step}: and shows show-banners inverted", dnd is not None and dnd["checked"] is (not menu["banners"]))
    else:
        check(f"{case}: {step}: upstream's Clear, shown only with cards", clear["visible"] is (not empty), json.dumps(clear))
        check(f"{case}: {step}: no Do Not Disturb switch", dnd is None)
        if not empty:
            check(f"{case}: {step}: Clear sits at the footer's left", 0 <= clear["x"] - footer["x"] <= FOOTER_INSET,
                  json.dumps({"clear": clear, "footer": footer}))


def check_cards(case, step, menu, apex):
    cards = [c for g in menu["groups"] for c in g["cards"]]
    if apex:
        check(f"{case}: {step}: groups are flat: expanded, no header",
              all(g["expanded"] and not g["header"] for g in menu["groups"]), json.dumps(menu["groups"]))
        check(f"{case}: {step}: each card's header reads app · time, without the source glyph",
              all(not c["glyph"] and " · " in c["line"] for c in cards), json.dumps(cards))
        check(f"{case}: {step}: each card shows its app's plain {ICON_SIZE} px icon, no tile, left of its text",
              all(c["icon"] and abs(c["icon"]["size"] - ICON_SIZE) <= 1 and abs(c["icon"]["width"] - ICON_SIZE) <= 1
                  and c["icon"]["x"] + c["icon"]["width"] <= c["text"]["x"]
                  for c in cards), json.dumps(cards))
        check(f"{case}: {step}: the icon's column, {ROW_GAP} px from the header over the title",
              all(c["icon"] and abs(c["header"]["x"] - c["icon"]["x"] - c["icon"]["width"] - ROW_GAP) <= 1
                  and abs(c["text"]["x"] - c["header"]["x"]) <= 1 and c["text"]["y"] >= c["header"]["y"] + c["header"]["height"] - 1
                  for c in cards), json.dumps(cards))
        boxes = sorted((c["card"] for c in cards), key=lambda b: b["y"])
        gaps = [b["y"] - a["y"] - a["height"] for a, b in zip(boxes, boxes[1:])]
        check(f"{case}: {step}: the cards follow one another, {MESSAGE_GAP} px apart",
              all(abs(g - MESSAGE_GAP) <= 1 for g in gaps), str(gaps))
    else:
        check(f"{case}: {step}: upstream stacks a group of more than one card",
              all(not g["expanded"] for g in menu["groups"] if len(g["cards"]) > 1), json.dumps(menu["groups"]))
        check(f"{case}: {step}: upstream's headers, with the source glyph", all(c["glyph"] for c in cards), json.dumps(cards))


def check_date_menu(shots, case, apex):
    log = read(shots, f"{case}.log")
    f = facts(log)
    steps = DATE_MENU_STEPS + (("dnd-clicked", "dnd-clicked-again") if apex else ())
    for step in steps:
        check(f"{case}: {step} is reported", step in f)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "cleared") and "APEXLOCK-ERROR" not in log)
    check(f"{case}: the layer loaded", LOAD_WITNESS in log)
    if not all(step in f for step in steps):
        return
    for step in DATE_MENU_STEPS:
        check_footer(case, step, f[step], apex)
        check_cards(case, step, f[step], apex)
    apps = [g["app"] for g in f["many"]["groups"]]
    check(f"{case}: one: one card", [len(g["cards"]) for g in f["one"]["groups"]] == [1], json.dumps(f["one"]["groups"]))
    check(f"{case}: many: five cards from four apps", sorted(apps) == sorted(DATE_MENU_APPS)
          and sum(len(g["cards"]) for g in f["many"]["groups"]) == 5, str(apps))
    check(f"{case}: Clear removes every card", f["cleared"]["groups"] == [], json.dumps(f["cleared"]["groups"]))
    if apex:
        # shoot.sh's capture settings turn banners off: Do Not Disturb starts on.
        before, once, twice = f["many"], f["dnd-clicked"], f["dnd-clicked-again"]
        check(f"{case}: a click turns Do Not Disturb {'off' if before['dnd']['checked'] else 'on'}, and banners with it",
              once["dnd"]["checked"] is (not before["dnd"]["checked"]) and once["banners"] is (not before["banners"]),
              json.dumps(once["dnd"]))
        check(f"{case}: another turns it back", twice["dnd"]["checked"] is before["dnd"]["checked"]
              and twice["banners"] is before["banners"], json.dumps(twice["dnd"]))
        check_footer(case, "dnd-clicked", once, apex)


def check_bar_cycle(shots, case, apex):
    log = read(shots, f"{case}.log")
    f = facts(log)
    steps = ("before", "logind-locked", "after-logind", "dialog-locked", "after-dialog")
    for step in steps:
        check(f"{case}: {step} is reported", step in f)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "after-dialog") and "APEXLOCK-ERROR" not in log)
    check(f"{case}: the layer {'loaded' if apex else 'did not load'}", (LOAD_WITNESS in log) == apex)
    if not all(step in f for step in steps):
        return
    before = f["before"]
    chip, search = (["EN", "FR"], True) if apex else (["en", "fr"], False)
    check(f"{case}: before: the user session's bar, its chip {'/'.join(chip)}, {'with' if apex else 'without'} the search button",
          before["mode"] == "user" and before["chip"] == chip and ("apex-search" in before["right"]) == search, json.dumps(before))
    check(f"{case}: logind's Lock locks", f["logind-locked"]["locked"] is True)
    check(f"{case}: the lock's own stage locks with its prompt up",
          f["dialog-locked"]["locked"] is True and f["dialog-locked"]["prompt"] is True, json.dumps(f["dialog-locked"]))
    def capture(step):
        with open(os.path.join(shots, os.path.basename(f[f"capture.{step}"])), "rb") as png:
            return png.read()
    bar = capture("before")
    for step in ("after-logind", "after-dialog"):
        after = f[step]
        for side in ("left", "center", "right"):
            check(f"{case}: {step}: the {side} box's items as before", after[side] == before[side],
                  f"{after[side]} != {before[side]}")
            check(f"{case}: {step}: as many actors in the {side} box as before ({before['actors'][side]})",
                  after["actors"][side] == before["actors"][side], str(after["actors"][side]))
        check(f"{case}: {step}: the chip and Clear as before",
              (after["chip"], after["clear"], after["mode"]) == (before["chip"], before["clear"], before["mode"]),
              json.dumps(after))
        check(f"{case}: {step}: the bar's capture is the same as before's", capture(step) == bar, f[f"capture.{step}"])


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    shots = sys.argv[1]
    for case, want in LOCK_CASES.items():
        check_lock(shots, case, want)
    check_refused(shots, "lock-refused")
    check_wake_key(shots, "lock-wake-key", torn_down=False)
    check_wake_key(shots, "lock-wake-key-blank", torn_down=True)
    check_idle(shots, "lock-idle")
    check_suspend(shots, "lock-suspend")
    check_fingerprint(shots, "lock-fingerprint")
    check_fingerprint_suspend(shots, "lock-fingerprint-suspend")
    for case in GREETER_CASES:
        check_greeter(shots, case)
    for case, want in POLKIT_CASES.items():
        check_polkit(shots, case, want)
    for case, (apex, sleeps) in POLKIT_LOCKED_CASES.items():
        check_polkit_locked(shots, case, apex, sleeps)
    check_date_menu(shots, "date-menu", True)
    check_date_menu(shots, "date-menu-disabled", False)
    check_bar_cycle(shots, "bar-lock-cycle", True)
    check_bar_cycle(shots, "bar-lock-cycle-safe", False)
    for case in END_SESSION_CASES:
        check_end_session(shots, case)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
