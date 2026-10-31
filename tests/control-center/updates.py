# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks the Software Updates page against update1.py's scenario, and each button's call, through AT-SPI."""

import json
import os
import sys

from ccatspi import Atspi, activate, failures, find_app, finish, wait_for, walk

STAGED_DIGEST = "sha256:9e41aa07c3b2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c80c2b"

EXPECT = {
    "ready": [
        "Restart to Finish Updating",
        "Settings 51.1 is held back",
        "Apex’s Settings changes do not apply to 51.1 yet, so this update keeps the last good build. Not a "
        "security update. Held for up to 14 days, then Apex ships the stock 51.1.",
        "libadwaita runs Fedora’s own build",
        "Apex's window radius waits for libadwaita 1.10.1.",
        "45.20261010.133 is downloaded and its signature checked. Your current version stays in place until you "
        "restart.",
        "GNOME 51.0 → 51.1, Linux 7.2.7 → 7.2.9, Mesa 26.1.0 → 26.1.2",
        "45.20261008.131 · sha256:3f9c…a71e",
        "45.20261010.133 · sha256:9e41…0c2b",
        "Checked",
        "45.20261001.124 · sha256:b02d…19c4",
        "Kept by Apex: the last version that started cleanly",
        "45.20260924.118 · sha256:7c1d…5e21",
        "Kept by Apex: the version before the failed boots",
        "today at 09:00",
    ],
    "up-to-date": [
        "Apex Is Up to Date",
        "45.20261008.131 is the newest build on the stable (running image) channel. Checked today at 09:00.",
        "Files 51.1 is held back",
        "It holds back a security update. Held for up to 3 days, then Apex ships the stock 51.1.",
    ],
    "available": ["Update Available",
                  "45.20261010.133 · 412 MB. It downloads in the background and nothing changes until you restart."],
    "waiting": ["Update Waiting",
                "The battery is below 50%. Connect the charger to download the update. 45.20261010.133 waits until then."],
    "downloading": ["Downloading Update", "264 of 412 MB"],
    "health-failure": ["Update Failed Its Startup Check", "failed-units"],
    "fallback": ["Apex Went Back to the Previous Version", "sha256:9e41…0c2b", "unchanged"],
    "unavailable": ["Software Updates Are Unavailable"],
}

# (button label, the call update1.py must log, or the text the page shows after it when it calls nothing)
PRESSES = {
    "ready": [("Check Now", ["Check"]), ("Use at Next Restart…", ["Rollback", False]),
              ("Keep Current Version", "Update Downloaded"), ("Restart Now", ["Apply", STAGED_DIGEST])],
    "available": [("Download", ["Download", False])],
    "waiting": [("Download Anyway", ["Download", True])],
    "health-failure": [("Keep This Version", ["AcknowledgeHealthFailure"]), ("Go Back…", ["Rollback", True])],
    "fallback": [("Show Changes", ["GetChangesFor", "sha256:9e41aa07c3b2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c80c2b"]),
                 ("OK", ["AcknowledgeHealthFailure"])],
}

# Texts that must show once the presses are done: Show Changes' list of the set-aside build.
AFTER = {"fallback": ["Changes in the Set-Aside Version", "gnome-shell", "51.0-1 → 51.1-1"]}

# Board 26: the alert the page raises by itself, by its heading.
ALERTS = {
    "health-failure": "Update Failed Its Startup Check",
    "fallback": "Apex Went Back to the Previous Version",
}

# (scenario, whether the switch stays where the press put it): update1.py refuses in "ready".
AUTOMATIC = {"ready": False, "up-to-date": True}


def texts(app):
    return (node.get_name() or "" for node in walk(app))


def calls(log):
    try:
        with open(log, encoding="utf-8") as f:
            return [json.loads(line) for line in f]
    except FileNotFoundError:
        return []


def button(app, label):
    for node in walk(app):
        if node.get_role() == Atspi.Role.PUSH_BUTTON and node.get_name() == label:
            return node
    return None


def alert(app, heading):
    roles = (Atspi.Role.ALERT, Atspi.Role.DIALOG, Atspi.Role.NOTIFICATION)
    return any(node.get_role() in roles and heading in (node.get_name() or "") for node in walk(app))


def switch(app, title):
    for node in walk(app):
        if node.get_role() == Atspi.Role.SWITCH and node.get_name() == title:
            return node
    return None


def check_automatic(app, scenario, log, stays):
    row = switch(app, "Automatic Downloads")
    if row is None:
        failures.append(f"{scenario}: no Automatic Downloads switch")
        print(f"FAIL {scenario}: no Automatic Downloads switch", flush=True)
        return
    on = row.get_state_set().contains(Atspi.StateType.CHECKED)
    activate(row)
    if not wait_for(f"{scenario}: the switch calls SetAutomaticDownloads({not on})",
                    lambda: ["SetAutomaticDownloads", not on] in calls(log)):
        return
    want = (not on) if stays else on
    if wait_for(f"{scenario}: the switch ends {'on' if want else 'off'}",
                lambda: row.get_state_set().contains(Atspi.StateType.CHECKED) == want):
        print(f"ok {scenario}: Automatic Downloads calls SetAutomaticDownloads and "
              f"{'keeps' if stays else 'reverts after a refusal'}", flush=True)


def main():
    scenario = sys.argv[1]
    log = os.environ.get("APEX_UPDATE1_LOG", "")
    app = find_app()
    for want in EXPECT[scenario]:
        wait_for(f"{scenario}: shows “{want}”", lambda: any(want in t for t in texts(app)))
    if scenario in ALERTS:
        if wait_for(f"{scenario}: the alert “{ALERTS[scenario]}” shows", lambda: alert(app, ALERTS[scenario])):
            print(f"ok {scenario}: board 26's alert shows", flush=True)
    if scenario in AUTOMATIC:
        check_automatic(app, scenario, log, AUTOMATIC[scenario])
    for label, call in PRESSES.get(scenario, []):
        node = button(app, label)
        if node is None:
            failures.append(f"{scenario}: no button “{label}”")
            print(f"FAIL {scenario}: no button “{label}”", flush=True)
            continue
        wait_for(f"{scenario}: “{label}” is sensitive",
                 lambda: node.get_state_set().contains(Atspi.StateType.SENSITIVE))
        activate(node)
        if isinstance(call, str):
            if wait_for(f"{scenario}: “{label}” shows “{call}”", lambda: any(call in t for t in texts(app))):
                print(f"ok {scenario}: “{label}” shows “{call}” and calls nothing", flush=True)
        elif wait_for(f"{scenario}: “{label}” calls {call}", lambda: call in calls(log)):
            print(f"ok {scenario}: “{label}” calls {call[0]}", flush=True)
    for want in AFTER.get(scenario, []):
        if wait_for(f"{scenario}: then shows “{want}”", lambda: any(want in t for t in texts(app))):
            print(f"ok {scenario}: then shows “{want}”", flush=True)
    finish()


main()
