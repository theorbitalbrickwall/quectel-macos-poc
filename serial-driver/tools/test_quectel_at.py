#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Exercise quectel_at.py over a pseudo-terminal that behaves like the modem."""
import contextlib
import io
import os
import pty
import sys
import threading
import tty
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import quectel_at


class FakeModem(threading.Thread):
    """Echoes commands like a real modem and answers a few of them."""

    def __init__(self, usbnet=3):
        super().__init__(daemon=True)
        # The slave end stays open so the master never sees a hangup between
        # two clients.
        self.master, self.slave = pty.openpty()
        self.path = os.ttyname(self.slave)
        tty.setraw(self.slave)  # no terminal echo of what the modem sends
        self.usbnet = usbnet
        self.seen = []
        os.write(self.master, b"\r\nRDY\r\n")  # stale URC before the first command
        self.start()

    def run(self):
        buffer = b""
        while True:
            try:
                chunk = os.read(self.master, 256)
            except OSError:
                return
            if not chunk:
                return
            buffer += chunk
            while b"\r" in buffer:
                raw, buffer = buffer.split(b"\r", 1)
                text = raw.decode().strip()
                if text:
                    self.seen.append(text)
                    os.write(self.master, self.reply(text))

    def reply(self, text):
        echo = text.encode() + b"\r\r\n"
        if text == 'AT+QCFG="usbnet"' and self.usbnet is not None:
            return echo + f'+QCFG: "usbnet",{self.usbnet}\r\n\r\nOK\r\n'.encode()
        if text.startswith('AT+QCFG="usbnet",'):
            self.usbnet = int(text.rsplit(",", 1)[1])
            return echo + b"OK\r\n"
        if text == 'AT+QCFG="usbnet"' and self.usbnet is None:
            return echo + b'+QCFG: "usbnet",1\xff\r\n\r\nOK\r\n'  # line noise
        if text == "ATI":
            return echo + b"Quectel\r\nEC25\r\nRevision: EC25EUXGAR08A05M1G\r\n\r\nOK\r\n"
        if text == "AT+CFUN=1,1":
            return echo  # goes away without answering
        if text == "AT+SILENT":
            return b""
        return echo + b"+CME ERROR: 100\r\n"


def run(modem, *args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = quectel_at.main(["--port", modem.path, *args])
    return status, out.getvalue(), err.getvalue()


class QuectelAtTest(unittest.TestCase):
    def test_plain_command_strips_echo_and_urc(self):
        status, out, _ = run(FakeModem(), "ATI")
        self.assertEqual(status, 0)
        self.assertEqual(out.split("\n")[:2], ["Quectel", "EC25"])
        self.assertNotIn("RDY", out)
        self.assertNotIn("ATI", out)

    def test_error_reply_sets_exit_status(self):
        status, out, _ = run(FakeModem(), "AT+BOGUS")
        self.assertEqual(status, 1)
        self.assertIn("+CME ERROR: 100", out)

    def test_silence_times_out(self):
        status, _, err = run(FakeModem(), "--timeout", "0.5", "AT+SILENT")
        self.assertEqual(status, 2)
        self.assertIn("no final response", err)

    def test_usbnet_query(self):
        modem = FakeModem(usbnet=3)
        status, out, _ = run(modem, "usbnet")
        self.assertEqual(status, 0)
        self.assertIn("3 (rndis)", out)
        self.assertEqual(modem.seen, ['AT+QCFG="usbnet"'])

    def test_garbled_usbnet_reply_is_reported(self):
        with self.assertRaisesRegex(RuntimeError, "unexpected reply"):
            run(FakeModem(usbnet=None), "usbnet")

    def test_usbnet_switch_sets_mode_and_reboots(self):
        modem = FakeModem(usbnet=3)
        original = quectel_at.command

        def fast(transport, text, timeout=5.0):  # do not wait 10 s for the reboot
            return original(transport, text, 0.5 if "CFUN" in text else timeout)

        quectel_at.command = fast
        try:
            status, _, _ = run(modem, "usbnet", "ecm")
        finally:
            quectel_at.command = original
        self.assertEqual(status, 0)
        self.assertEqual(modem.usbnet, 1)
        self.assertEqual(modem.seen,
                         ['AT+QCFG="usbnet"', 'AT+QCFG="usbnet",1', "AT+CFUN=1,1"])

    def test_usbnet_same_mode_is_a_no_op(self):
        modem = FakeModem(usbnet=1)
        status, out, _ = run(modem, "usbnet", "ecm")
        self.assertEqual(status, 0)
        self.assertIn("nothing to do", out)
        self.assertEqual(modem.seen, ['AT+QCFG="usbnet"'])


if __name__ == "__main__":
    unittest.main()
