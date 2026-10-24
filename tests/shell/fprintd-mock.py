#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: fprintd-mock.py LOG

fprintd on the system bus, as much of it as the shell's fingerprint manager reads: one
"press" reader at /net/reactivated/Fprint/Device/0, the default. It never verifies a
finger: gdm-mock.py's gdm-fingerprint conversation stands in for pam_fprintd. Each call is a
line in LOG.
"""

import sys

from gi.repository import Gio, GLib

NAME = "net.reactivated.Fprint"
MANAGER_PATH = "/net/reactivated/Fprint/Manager"
DEVICE_PATH = "/net/reactivated/Fprint/Device/0"
PROPERTIES = {"name": GLib.Variant("s", "Apex test reader"), "num-enroll-stages": GLib.Variant("i", 5),
              "scan-type": GLib.Variant("s", "press")}

XML = """<node>
<interface name="net.reactivated.Fprint.Manager">
  <method name="GetDevices"><arg type="ao" name="devices" direction="out"/></method>
  <method name="GetDefaultDevice"><arg type="o" name="device" direction="out"/></method>
</interface>
<interface name="net.reactivated.Fprint.Device">
  <method name="ListEnrolledFingers">
    <arg type="s" name="username" direction="in"/><arg type="as" name="enrolled_fingers" direction="out"/>
  </method>
  <property name="name" type="s" access="read"/>
  <property name="num-enroll-stages" type="i" access="read"/>
  <property name="scan-type" type="s" access="read"/>
</interface>
</node>"""


class Mock:
    def __init__(self, log):
        self.log = open(log, "a", buffering=1, encoding="utf-8")  # noqa: SIM115 (open for the mock's life)
        self.info = Gio.DBusNodeInfo.new_for_xml(XML)

    def on_call(self, _connection, sender, _path, _interface, method, params, invocation):
        print(f"{method} {' '.join(map(str, params.unpack()))} from {sender}".replace("  ", " "), file=self.log)
        replies = {
            "GetDevices": GLib.Variant("(ao)", ([DEVICE_PATH],)),
            "GetDefaultDevice": GLib.Variant("(o)", (DEVICE_PATH,)),
            "ListEnrolledFingers": GLib.Variant("(as)", (["right-index-finger"],)),
        }
        invocation.return_value(replies[method])

    def on_property(self, _connection, _sender, _path, _interface, name):
        return PROPERTIES[name]

    def on_bus(self, connection, _name):
        manager, device = self.info.interfaces
        connection.register_object(MANAGER_PATH, manager, self.on_call, None, None)
        connection.register_object(DEVICE_PATH, device, self.on_call, self.on_property, None)

    def run(self):
        Gio.bus_own_name(Gio.BusType.SYSTEM, NAME, Gio.BusNameOwnerFlags.NONE, self.on_bus,
                         lambda *_: print(f"owns {NAME}", file=self.log),
                         lambda *_: (print(f"lost {NAME}", file=self.log), sys.exit(1)))
        GLib.MainLoop().run()


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    Mock(sys.argv[1]).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
