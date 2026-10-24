#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""usage: gdm-mock.py LOG QUESTION [--fingerprint]

GDM for the lock screen and the greeter, on the system bus: Manager's
OpenReauthenticationChannel and OpenSession open a peer-to-peer UserVerifier that asks
QUESTION for gdm-password and finds no other service. It never completes a verification: every
answer is a failure, so nothing it does can unlock the screen. An empty QUESTION
refuses every channel instead, as a GDM that cannot reauthenticate does. With --fingerprint,
gdm-fingerprint runs too, as pam_fprintd does, until it is cancelled; the test method
FailScan() fails a scan in every such conversation, and Mark(STEP) writes "-- STEP". Each call, and each signal it sends, is
a line in LOG.
"""

import os
import sys
import tempfile

from gi.repository import Gio, GLib

NAME = "org.gnome.DisplayManager"
MANAGER_PATH = "/org/gnome/DisplayManager/Manager"
SESSION_PATH = "/org/gnome/DisplayManager/Session"
PASSWORD_SERVICE = "gdm-password"
FINGERPRINT_SERVICE = "gdm-fingerprint"
# pam_fprintd's own texts.
FINGERPRINT_INFO = "Place your finger on the fingerprint reader"
FINGERPRINT_PROBLEM = "Failed to match fingerprint"
PROBLEM = "Sorry, that didn't work. Please try again."

MANAGER_XML = """<node><interface name="org.gnome.DisplayManager.Manager">
  <method name="OpenReauthenticationChannel">
    <arg name="username" direction="in" type="s"/><arg name="address" direction="out" type="s"/>
  </method>
  <method name="OpenSession"><arg name="address" direction="out" type="s"/></method>
  <property name="Version" type="s" access="read"/>
</interface>
<interface name="io.github.apex_linux.GdmMock">
  <method name="FailScan"><arg name="conversations" direction="out" type="u"/></method>
  <method name="Mark"><arg name="step" direction="in" type="s"/></method>
</interface></node>"""

VERIFIER_XML = """<node>
<interface name="org.gnome.DisplayManager.UserVerifier">
  <method name="EnableExtensions"><arg name="extensions" direction="in" type="as"/></method>
  <method name="BeginVerification"><arg name="service_name" direction="in" type="s"/></method>
  <method name="BeginVerificationForUser">
    <arg name="service_name" direction="in" type="s"/><arg name="username" direction="in" type="s"/>
  </method>
  <method name="AnswerQuery">
    <arg name="service_name" direction="in" type="s"/><arg name="answer" direction="in" type="s"/>
  </method>
  <method name="Cancel"/>
  <signal name="ConversationStarted"><arg name="service_name" type="s"/></signal>
  <signal name="ConversationStopped"><arg name="service_name" type="s"/></signal>
  <signal name="Info"><arg name="service_name" type="s"/><arg name="info" type="s"/></signal>
  <signal name="Problem"><arg name="service_name" type="s"/><arg name="problem" type="s"/></signal>
  <signal name="InfoQuery"><arg name="service_name" type="s"/><arg name="query" type="s"/></signal>
  <signal name="SecretInfoQuery"><arg name="service_name" type="s"/><arg name="query" type="s"/></signal>
  <signal name="Reset"/>
  <signal name="ServiceUnavailable"><arg name="service_name" type="s"/><arg name="message" type="s"/></signal>
  <signal name="VerificationFailed"><arg name="service_name" type="s"/></signal>
  <signal name="VerificationComplete"><arg name="service_name" type="s"/></signal>
</interface>
<interface name="org.gnome.DisplayManager.UserVerifier.ChoiceList">
  <method name="SelectChoice">
    <arg name="service_name" direction="in" type="s"/><arg name="choice" direction="in" type="s"/>
  </method>
</interface>
<interface name="org.gnome.DisplayManager.UserVerifier.CustomJSON">
  <method name="Reply">
    <arg name="service_name" direction="in" type="s"/><arg name="reply" direction="in" type="s"/>
  </method>
  <method name="ReportError">
    <arg name="service_name" direction="in" type="s"/><arg name="error" direction="in" type="s"/>
  </method>
</interface>
</node>"""


class Mock:
    def __init__(self, log, question, fingerprint):
        self.log = open(log, "a", buffering=1, encoding="utf-8")  # noqa: SIM115 (open for the mock's life)
        self.question = question
        self.fingerprint = fingerprint
        self.scanning = {}
        self.channels = 0
        self.connections = []
        self.verifier = Gio.DBusNodeInfo.new_for_xml(VERIFIER_XML)
        self.manager = Gio.DBusNodeInfo.new_for_xml(MANAGER_XML)
        self.socket_dir = tempfile.mkdtemp(prefix="apex-gdm-mock.")
        os.chmod(self.socket_dir, 0o755)
        # The shell runs as another user, and connecting to a socket needs write access to it.
        os.umask(0)
        observer = Gio.DBusAuthObserver.new()
        observer.connect("authorize-authenticated-peer", lambda *_: True)
        self.server = Gio.DBusServer.new_sync(f"unix:dir={self.socket_dir}", Gio.DBusServerFlags.NONE,
                                              Gio.dbus_generate_guid(), observer, None)
        self.server.connect("new-connection", self.on_connection)
        self.server.start()

    def note(self, line):
        print(line, file=self.log)

    def on_connection(self, _server, connection):
        self.channels += 1
        channel = self.channels
        # GDBusServer drops a connection nothing references.
        self.connections.append(connection)
        self.note(f"channel {channel}: connected")
        for interface in self.verifier.interfaces:
            connection.register_object(SESSION_PATH, interface,
                                       lambda *args, c=channel: self.on_verifier_call(c, *args), None, None)
        connection.connect("closed", lambda *_: (self.scanning.pop(channel, None), self.note(f"channel {channel}: closed")))
        return True

    def emit(self, connection, channel, signal, *args):
        self.note(f"channel {channel}: signal {signal} {' '.join(args)}".rstrip())
        signature = "(" + "s" * len(args) + ")"
        connection.emit_signal(None, SESSION_PATH, "org.gnome.DisplayManager.UserVerifier", signal,
                               GLib.Variant(signature, args) if args else None)

    def on_verifier_call(self, channel, connection, _sender, _path, _interface, method, params, invocation):
        args = params.unpack()
        if method == "AnswerQuery":
            self.note(f"channel {channel}: AnswerQuery {args[0]} ({len(args[1])} characters)")
        else:
            self.note(f"channel {channel}: {method} {' '.join(map(str, args))}".rstrip())
        invocation.return_value(None)
        if method == "Cancel":
            self.scanning.pop(channel, None)
        if method in ("BeginVerification", "BeginVerificationForUser"):
            service = args[0]
            if service == FINGERPRINT_SERVICE and self.fingerprint:
                self.scanning[channel] = connection
                self.emit(connection, channel, "ConversationStarted", service)
                self.emit(connection, channel, "Info", service, FINGERPRINT_INFO)
                return
            if service != PASSWORD_SERVICE:
                self.emit(connection, channel, "ServiceUnavailable", service, "")
                return
            self.emit(connection, channel, "ConversationStarted", service)
            self.emit(connection, channel, "SecretInfoQuery", service, self.question)
        elif method == "AnswerQuery":
            self.emit(connection, channel, "Problem", args[0], PROBLEM)
            self.emit(connection, channel, "VerificationFailed", args[0])

    def on_manager_call(self, _connection, sender, _path, _interface, method, params, invocation):
        if method == "Mark":
            self.note(f"-- {params.unpack()[0]}")
            invocation.return_value(None)
            return
        if method == "FailScan":
            self.note(f"FailScan: {len(self.scanning)} conversations")
            for channel, connection in self.scanning.items():
                self.emit(connection, channel, "Problem", FINGERPRINT_SERVICE, FINGERPRINT_PROBLEM)
            invocation.return_value(GLib.Variant("(u)", (len(self.scanning),)))
            return
        address = self.server.get_client_address()
        self.note(f"{method} {' '.join(params.unpack())} from {sender}".replace("  ", " "))
        if not self.question:
            self.note(f"{method}: refused")
            invocation.return_dbus_error("org.gnome.DisplayManager.Manager.Error.Refused", "refused by gdm-mock.py")
            return
        invocation.return_value(GLib.Variant("(s)", (address,)))

    def on_manager_property(self, *_args):
        return GLib.Variant("s", "51.0")

    def on_bus(self, connection, _name):
        for interface in self.manager.interfaces:
            connection.register_object(MANAGER_PATH, interface, self.on_manager_call, self.on_manager_property, None)

    def run(self):
        Gio.bus_own_name(Gio.BusType.SYSTEM, NAME, Gio.BusNameOwnerFlags.NONE, self.on_bus,
                         lambda *_: self.note(f"owns {NAME}"),
                         lambda *_: (self.note(f"lost {NAME}"), sys.exit(1)))
        GLib.MainLoop().run()


def main():
    if len(sys.argv) not in (3, 4) or sys.argv[3:] not in ([], ["--fingerprint"]):
        print(__doc__, file=sys.stderr)
        return 2
    Mock(sys.argv[1], sys.argv[2], sys.argv[3:] == ["--fingerprint"]).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
