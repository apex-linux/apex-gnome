#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: fixtures.py LOG_DIR

G2's python-dbusmock fixtures on the system bus (DBUS_SYSTEM_BUS_ADDRESS, or the
default): UPower with a battery at 87 %, NetworkManager on the Wi-Fi network
"Apex-5G" with "Apex-2.4G" and the open "Library Guest" in range, and BlueZ with the
Bluetooth keyboard "Keychron K3" connected, switcheroo-control with an integrated and a
discrete GPU, and with G2_POWER_PROFILES=1 power-profiles-daemon at Balanced. The mocks
keep running after this exits; each logs to LOG_DIR/fixture-NAME.log and leaves
its pid in LOG_DIR/fixture-NAME.pid.
Prints one line, G2-FIXTURES and what the bus then reports, as JSON.
"""

import json
import os
import subprocess
import sys
import time

import dbus

MOCK_IFACE = "org.freedesktop.DBus.Mock"
READY_TIMEOUT_S = 20

BATTERY_PERCENT = 87.0
BATTERY_SECONDS_TO_EMPTY = 4 * 3600 + 21 * 60
BATTERY_ENERGY_FULL_WH = 72.0
UPOWER_TYPE_BATTERY = 2
UPOWER_STATE_DISCHARGING = 2
UPOWER_WARNING_NONE = 1

WIFI_SSID = "Apex-5G"
WIFI_STRENGTH = 90
WIFI_FREQUENCY_MHZ = 5180
WIFI_RATE_KBPS = 866700
NM_80211_MODE_INFRA = 2
NM_80211_AP_SEC_NONE = 0
NM_80211_AP_SEC_KEY_MGMT_PSK = 0x100
# libnm takes WPA2 only with its ciphers: key management alone is an invalid network.
NM_80211_AP_SEC_WPA2_PSK = NM_80211_AP_SEC_KEY_MGMT_PSK | 0x8 | 0x80
WIFI_IN_RANGE = (("apex24g", "Apex-2.4G", "02:A5:E0:00:00:02", 2437, 300000, 72, NM_80211_AP_SEC_WPA2_PSK),
                 ("guest", "Library Guest", "02:A5:E0:00:00:03", 2412, 144400, 48, NM_80211_AP_SEC_NONE))
NM_DEVICE_STATE_ACTIVATED = 100
NM_ACTIVE_CONNECTION_STATE_ACTIVATED = 2

KEYBOARD_NAME = "Keychron K3"
KEYBOARD_ADDRESS = "DC:2C:26:4B:33:01"
BLUETOOTH_CLASS_KEYBOARD = 0x002540

# switcheroo-control lists the default, integrated GPU first; the shell offers the other.
GPUS = (("Intel Graphics", "pci-0000_00_02_0", True), ("NVIDIA GeForce RTX 4060", "pci-0000_01_00_0", False))

UPOWER = "org.freedesktop.UPower"
NM = "org.freedesktop.NetworkManager"
NM_PATH = "/org/freedesktop/NetworkManager"
BLUEZ = "org.bluez"
SWITCHEROO = "net.hadess.SwitcherooControl"
SWITCHEROO_PATH = "/net/hadess/SwitcherooControl"
POWER_PROFILES = "org.freedesktop.UPower.PowerProfiles"
TEMPLATE_PARAMETERS = {"upower": {"DaemonVersion": "1.90", "OnBattery": True}}
# python-dbusmock has no switcheroo-control template: that mock is a bare object.
SERVICES = {
    **{template: (name, ["--template", template, "--parameters", json.dumps(TEMPLATE_PARAMETERS.get(template, {}))])
       for template, name in (("upower", UPOWER), ("networkmanager", NM), ("bluez5", BLUEZ))},
    "switcheroo": (SWITCHEROO, [SWITCHEROO, SWITCHEROO_PATH, SWITCHEROO]),
}
# Opt-in, so the app tests that share these fixtures keep Quick Settings without Power Mode.
OPTIONAL_SERVICES = {"upower_power_profiles_daemon": (POWER_PROFILES, ["--template", "upower_power_profiles_daemon"])}


def services():
    if os.environ.get("G2_POWER_PROFILES") == "1":
        return {**SERVICES, **OPTIONAL_SERVICES}
    return SERVICES


def spawn(log_dir):
    for fixture, (_name, args) in services().items():
        log = open(f"{log_dir}/fixture-{fixture}.log", "w", encoding="utf-8")
        mock = subprocess.Popen(
            [sys.executable, "-m", "dbusmock", "--system", *args],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        log.close()
        with open(f"{log_dir}/fixture-{fixture}.pid", "w", encoding="utf-8") as pid:
            print(mock.pid, file=pid)
    bus = dbus.SystemBus()
    deadline = time.monotonic() + READY_TIMEOUT_S
    names = [name for name, _args in services().values()]
    while not all(bus.name_has_owner(name) for name in names):
        if time.monotonic() > deadline:
            missing = [name for name in names if not bus.name_has_owner(name)]
            sys.exit(f"fixtures.py: no owner for {', '.join(missing)} after {READY_TIMEOUT_S} s")
        time.sleep(0.1)
    return bus


class Service:
    def __init__(self, bus, name):
        self.bus = bus
        self.name = name

    def mock(self, path, interface=MOCK_IFACE):
        return dbus.Interface(self.bus.get_object(self.name, path), interface)

    def props(self, path):
        return dbus.Interface(self.bus.get_object(self.name, path), dbus.PROPERTIES_IFACE)

    # The clients start after this, so a property the template lacks needs no signal.
    def put(self, path, interface, values):
        known = self.props(path).GetAll(interface)
        for key, value in values.items():
            if key in known:
                self.props(path).Set(interface, key, value)
            else:
                self.mock(path).AddProperty(interface, key, value)


def battery(bus):
    upower = Service(bus, UPOWER)
    root = upower.mock("/org/freedesktop/UPower")
    root.AddDischargingBattery("BAT0", "Battery", dbus.Double(BATTERY_PERCENT),
                               dbus.Int64(BATTERY_SECONDS_TO_EMPTY))
    energy = BATTERY_ENERGY_FULL_WH * BATTERY_PERCENT / 100
    root.SetupDisplayDevice(
        dbus.UInt32(UPOWER_TYPE_BATTERY), dbus.UInt32(UPOWER_STATE_DISCHARGING),
        dbus.Double(BATTERY_PERCENT), dbus.Double(energy), dbus.Double(BATTERY_ENERGY_FULL_WH),
        dbus.Double(energy * 3600 / BATTERY_SECONDS_TO_EMPTY), dbus.Int64(BATTERY_SECONDS_TO_EMPTY),
        dbus.Int64(0), dbus.Boolean(True), "battery-good-symbolic", dbus.UInt32(UPOWER_WARNING_NONE))
    display = upower.props("/org/freedesktop/UPower/devices/DisplayDevice")
    device = "org.freedesktop.UPower.Device"
    return {"percentage": float(display.Get(device, "Percentage")),
            "present": bool(display.Get(device, "IsPresent")),
            "onBattery": bool(upower.props("/org/freedesktop/UPower").Get(UPOWER, "OnBattery"))}


def wifi(bus):
    nm = Service(bus, NM)
    root = nm.mock(NM_PATH)
    device = root.AddWiFiDevice("wlan0", "wlp1s0", dbus.Int32(NM_DEVICE_STATE_ACTIVATED))
    access_point = root.AddAccessPoint(
        device, "apex5g", WIFI_SSID, "02:A5:E0:00:00:01", dbus.UInt32(NM_80211_MODE_INFRA),
        dbus.UInt32(WIFI_FREQUENCY_MHZ), dbus.UInt32(WIFI_RATE_KBPS), dbus.Byte(WIFI_STRENGTH),
        dbus.UInt32(NM_80211_AP_SEC_KEY_MGMT_PSK))
    for name, ssid, address, frequency, rate, strength, security in WIFI_IN_RANGE:
        root.AddAccessPoint(device, name, ssid, address, dbus.UInt32(NM_80211_MODE_INFRA), dbus.UInt32(frequency),
                            dbus.UInt32(rate), dbus.Byte(strength), dbus.UInt32(security))
    connection = root.AddWiFiConnection(device, "apex5g", WIFI_SSID, "wpa-psk")
    active = root.AddActiveConnection([device], connection, access_point, "apex5g",
                                      dbus.UInt32(NM_ACTIVE_CONNECTION_STATE_ACTIVATED))
    # The template's connection knows plain PSK only: the ciphers come after it.
    wpa2 = dbus.UInt32(NM_80211_AP_SEC_WPA2_PSK)
    nm.put(access_point, f"{NM}.AccessPoint", {"WpaFlags": wpa2, "RsnFlags": wpa2})
    nm.put(device, f"{NM}.Device.Wireless", {"ActiveAccessPoint": dbus.ObjectPath(access_point)})
    nm.put(NM_PATH, NM, {"PrimaryConnection": dbus.ObjectPath(active),
                         "PrimaryConnectionType": "802-11-wireless"})
    manager = nm.props(NM_PATH)
    primary = manager.Get(NM, "PrimaryConnection")
    ap = nm.props(nm.props(device).Get(f"{NM}.Device.Wireless", "ActiveAccessPoint"))
    return {"primary": str(nm.props(primary).Get(f"{NM}.Connection.Active", "Id")),
            "ssid": bytes(ap.Get(f"{NM}.AccessPoint", "Ssid")).decode(),
            "strength": int(ap.Get(f"{NM}.AccessPoint", "Strength")),
            "inRange": [bytes(nm.props(path).Get(f"{NM}.AccessPoint", "Ssid")).decode()
                        for path in nm.props(device).Get(f"{NM}.Device.Wireless", "AccessPoints")],
            "state": int(manager.Get(NM, "State")),
            "connectivity": int(manager.Get(NM, "Connectivity"))}


def keyboard(bus):
    bluez = Service(bus, BLUEZ)
    root = bluez.mock("/org/bluez", "org.bluez.Mock")
    root.AddAdapter("hci0", "apex")
    device = root.AddDevice("hci0", KEYBOARD_ADDRESS, KEYBOARD_NAME)
    bluez.put(device, "org.bluez.Device1", {
        "Icon": "input-keyboard", "Class": dbus.UInt32(BLUETOOTH_CLASS_KEYBOARD),
        "Paired": True, "Bonded": True, "Trusted": True, "Connected": True,
        "ServicesResolved": True})
    props = bluez.props(device)
    return {"alias": str(props.Get("org.bluez.Device1", "Alias")),
            "connected": bool(props.Get("org.bluez.Device1", "Connected")),
            "icon": str(props.Get("org.bluez.Device1", "Icon"))}


def gpus(bus):
    switcheroo = Service(bus, SWITCHEROO)
    switcheroo.mock(SWITCHEROO_PATH).AddProperties(SWITCHEROO, {
        "HasDualGpu": True,
        "NumGPUs": dbus.UInt32(len(GPUS)),
        "GPUs": dbus.Array([dbus.Dictionary({
            "Name": name, "Environment": dbus.Array(["DRI_PRIME", prime], signature="s"),
            "Default": default}, signature="sv") for name, prime, default in GPUS], signature="a{sv}"),
    })
    props = switcheroo.props(SWITCHEROO_PATH)
    return {"hasDualGpu": bool(props.Get(SWITCHEROO, "HasDualGpu")),
            "names": [str(gpu["Name"]) for gpu in props.Get(SWITCHEROO, "GPUs")]}


def power_profiles(bus):
    if "upower_power_profiles_daemon" not in services():
        return None
    props = Service(bus, POWER_PROFILES).props("/org/freedesktop/UPower/PowerProfiles")
    return {"active": str(props.Get(POWER_PROFILES, "ActiveProfile")),
            "profiles": [str(p["Profile"]) for p in props.Get(POWER_PROFILES, "Profiles")]}


def main():
    if len(sys.argv) != 2 or sys.argv[1].startswith("-"):
        print(__doc__, file=sys.stderr)
        return 2
    bus = spawn(sys.argv[1])
    print("G2-FIXTURES " + json.dumps({"battery": battery(bus), "wifi": wifi(bus), "keyboard": keyboard(bus),
                                         "gpus": gpus(bus), "powerProfiles": power_profiles(bus)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
