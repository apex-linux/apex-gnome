#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: check.py SHOTS_DIR

Asserts each shoot.sh case from its log's APEXLOCK lines and gdm-mock.py's log: what
boards 20 and 12 show, that no case unlocks, that a wrong answer leaves the screen
locked, that a GDM refusing to reauthenticate leaves it locked, that the fingerprint
conversation stops while the screen is blank, that blanking cancels the conversation and waking starts a new one, that
stock and safe mode keep upstream's lock, that the greeter runs no Apex JS, and board 34's
date menu: a flat list of cards with a 32 px icon column, Clear on the right, Do Not Disturb.
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
APEX_BLUR = "radius=60 brightness=1.00 saturation=1.30"
STOCK_BLUR = "radius=90 brightness=0.65 saturation=1.00"
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
WRONG_ANSWER = "not-the-password"

TOKENS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../desktop/shell/data/theme/apex/_apex-tokens.scss")
LOGO = "/usr/share/pixmaps/apex-gdm-logo.svg"
LOGO_HEIGHT = 48

failed = 0


def tokens():
    found = {}
    with open(TOKENS, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"\$(apex_greeter_\w+):\s*(.+?);", line)
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


def check_lock(shots, case, want):
    log = read(shots, f"{case}.log")
    gdm = read(shots, f"{case}.gdm.log")
    f = facts(log)
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


# pam_fprintd's texts reach the prompt through upstream's own; S4 owns the wording.
FINGERPRINT_HINT = "(or place finger on reader)"
FINGERPRINT_PROBLEM = "Failed to match fingerprint"


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
    check(f"{case}: the prompt says so, in upstream's words", (f["opened"]["prompt"] or {}).get("message") == FINGERPRINT_HINT,
          json.dumps(f["opened"]["prompt"]))
    check(f"{case}: a failed scan is shown, and the screen stays locked",
          (f["scan-failed"]["prompt"] or {}).get("message") == FINGERPRINT_PROBLEM, json.dumps(f["scan-failed"]["prompt"]))
    before_blank = between(gdm, "capture.scan-failed", "blank")
    check(f"{case}: blanking cancels the conversation the reader was in", any(line.endswith(": Cancel") for line in before_blank),
          json.dumps(before_blank))
    blank = between(gdm, "blank", "still-blank")
    check(f"{case}: while blank, no conversation starts and the reader is left alone", blank == [], json.dumps(blank))
    check(f"{case}: blank: no prompt", f["blank"]["prompt"] is None and f["still-blank"]["prompt"] is None)
    check(f"{case}: waking starts the reader's conversation again",
          any(line.endswith(begun) for line in between(gdm, "still-blank", "wake")) and f["wake"]["prompt"] is not None)


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


DND_LABEL = "Do Not Disturb"
ICON_SIZE = 32
MESSAGE_GAP = 8  # $apex_message_gap
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
        check(f"{case}: {step}: the Do Not Disturb switch comes first, labelled",
              dnd is not None and "apex-dnd-switch" in (footer["children"][0] or "") and dnd["label"] == DND_LABEL,
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
        check(f"{case}: {step}: each card has a {ICON_SIZE} px icon column left of its text",
              all(c["column"] and c["iconSize"] == ICON_SIZE and c["icon"]["x"] + c["icon"]["width"] <= c["text"]["x"]
                  and c["icon"]["y"] <= c["text"]["y"] + 1 for c in cards), json.dumps(cards))
        boxes = sorted((c["card"] for c in cards), key=lambda b: b["y"])
        gaps = [b["y"] - a["y"] - a["height"] for a, b in zip(boxes, boxes[1:])]
        check(f"{case}: {step}: the cards follow one another, {MESSAGE_GAP} px apart",
              all(abs(g - MESSAGE_GAP) <= 1 for g in gaps), str(gaps))
    else:
        check(f"{case}: {step}: upstream stacks a group of more than one card",
              all(not g["expanded"] for g in menu["groups"] if len(g["cards"]) > 1), json.dumps(menu["groups"]))
        check(f"{case}: {step}: upstream's cards, the icon in the header",
              all(not c["column"] for c in cards), json.dumps(cards))


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


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    shots = sys.argv[1]
    for case, want in LOCK_CASES.items():
        check_lock(shots, case, want)
    check_refused(shots, "lock-refused")
    check_fingerprint(shots, "lock-fingerprint")
    for case in GREETER_CASES:
        check_greeter(shots, case)
    check_date_menu(shots, "date-menu", True)
    check_date_menu(shots, "date-menu-disabled", False)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
