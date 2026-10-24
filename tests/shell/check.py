#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: check.py SHOTS_DIR

Asserts each shoot.sh case from its log's APEXLOCK lines and gdm-mock.py's log: what
boards 20 and 12 show, that no case unlocks, that a wrong answer leaves the screen
locked, that a GDM refusing to reauthenticate leaves it locked, that blanking cancels the conversation and waking starts a new one, that
stock and safe mode keep upstream's lock, and that the greeter runs no Apex JS.
Prints one line per assertion and exits 1 when one fails.
"""

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
LOAD_WITNESS = "Apex: APEX_SHELL_TEST_FAULT=load-witness names no phase"

# Per lock case: the layer's lock or upstream's, and the question its prompt shows.
LOCK_CASES = {
    "lock-light": {"apex": True, "question": "Enter Password"},
    "lock-dark": {"apex": True, "question": "Enter Password"},
    "lock-question": {"apex": True, "question": "Verification code:"},
    "lock-disabled": {"apex": False, "question": "Password", "layer": True},
    "lock-safe": {"apex": False, "question": "Password", "layer": False},
}
GREETER_CASES = ["greeter-light", "greeter-dark"]
AUTH_ERROR = "Authentication error"

failed = 0


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


def check_lock(shots, case, want):
    log = read(shots, f"{case}.log")
    gdm = read(shots, f"{case}.gdm.log")
    f = facts(log)
    for step in ("opened", "wrong-answer", "blank", "wake", "end"):
        check(f"{case}: {step} is reported", step in f)
    if failed:
        return
    for step in ("opened", "wrong-answer", "blank", "wake", "end"):
        check(f"{case}: {step}: locked", f[step]["locked"] is True)
    check(f"{case}: GDM never completes a verification", "VerificationComplete" not in gdm)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "end") and "APEXLOCK-ERROR" not in log)
    opened, wrong, blank, wake = f["opened"], f["wrong-answer"], f["blank"], f["wake"]
    check(f"{case}: the date and the time", (opened["date"], opened["time"]) == (DATE, TIME),
          f"{opened['date']} {opened['time']}")
    calls = channels(gdm)
    answered = [c for c, lines in calls.items() if any(x.startswith("AnswerQuery") for x in lines)]
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
        check(f"{case}: date above time, no upstream hint", opened["clock"] == APEX_CLOCK, opened["clock"])
        check(f"{case}: the unlock hint", opened["hint"] == HINT, str(opened["hint"]))
        check(f"{case}: the prompt is up at once", opened["prompt"] is not None)
        check(f"{case}: the initial-letter avatar", (opened["prompt"] or {}).get("avatar") == "initial A",
              json.dumps(opened["prompt"]))
        check(f"{case}: the user's name", (opened["prompt"] or {}).get("name") == "Apex")
        check(f"{case}: blanking takes the prompt down", blank["prompt"] is None, json.dumps(blank["prompt"]))
        if answered:
            check(f"{case}: and cancels its conversation", "Cancel" in calls[answered[0]])
        later = [c for c in calls if answered and c > answered[0] and
                 any(x.startswith("BeginVerificationForUser gdm-password") for x in calls[c])]
        check(f"{case}: waking starts a new conversation", bool(later) and wake["prompt"] is not None,
              f"channels {sorted(calls)}")
        check(f"{case}: the layer loaded", LOAD_WITNESS in log)
    else:
        check(f"{case}: upstream's two stages", "apex-lock" not in opened["classes"].split())
        check(f"{case}: upstream's clock with its hint", opened["clock"] == STOCK_CLOCK, opened["clock"])
        check(f"{case}: no prompt until a key", opened["prompt"] is None)
        check(f"{case}: upstream's avatar icon", (wrong["prompt"] or {}).get("avatar") == "avatar-default-symbolic")
        check(f"{case}: upstream keeps its prompt at blank", blank["prompt"] is not None)
        check(f"{case}: the layer {'loaded' if want['layer'] else 'did not load'}",
              (LOAD_WITNESS in log) == want["layer"])


def check_refused(shots, case):
    log = read(shots, f"{case}.log")
    f = facts(log)
    steps = ("opened", "wrong-answer", "blank", "wake", "end")
    check(f"{case}: every step is reported", all(s in f for s in steps))
    check(f"{case}: GDM refused every channel", "OpenReauthenticationChannel" in read(shots, f"{case}.gdm.log")
          and "channel " not in read(shots, f"{case}.gdm.log"))
    for step in steps:
        check(f"{case}: {step}: locked", f.get(step, {}).get("locked") is True)
    check(f"{case}: the prompt says so", (f.get("opened", {}).get("prompt") or {}).get("message") == AUTH_ERROR,
          json.dumps(f.get("opened", {}).get("prompt")))


def check_greeter(shots, case):
    log = read(shots, f"{case}.log")
    f = facts(log)
    check(f"{case}: the list and the prompt are reported", "list" in f and "prompt" in f)
    check(f"{case}: no JS error", "JS ERROR" not in until(log, "capture.prompt") and "APEXLOCK-ERROR" not in log)
    # load-witness is in the greeter's environment too: layer.js would warn as it loads.
    check(f"{case}: apex/layer.js never loads", LOAD_WITNESS not in log)
    check(f"{case}: no Apex line at all", not re.search(r"\bApex: ", log))
    if "list" not in f or "prompt" not in f:
        return
    check(f"{case}: the user list", f["list"]["users"] == "apex guest", f["list"]["users"])
    prompt = f["prompt"]["prompt"] or {}
    check(f"{case}: upstream's question", prompt.get("question") == "Password", json.dumps(prompt))
    check(f"{case}: upstream's avatar icon", prompt.get("avatar") == "avatar-default-symbolic", json.dumps(prompt))


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    shots = sys.argv[1]
    for case, want in LOCK_CASES.items():
        check_lock(shots, case, want)
    check_refused(shots, "lock-refused")
    for case in GREETER_CASES:
        check_greeter(shots, case)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
