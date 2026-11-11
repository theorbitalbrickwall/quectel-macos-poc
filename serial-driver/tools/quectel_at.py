#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Send AT commands to a Quectel modem and switch its USB network mode.

Two transports:
  * a serial port (--port, or /dev/cu.quectel2 when the driver is installed);
    standard library only.
  * raw USB through libusb (--usb, or automatically when no port exists);
    needs no driver at all, only `brew install libusb` and `pip install pyusb`.

Examples:
  quectel_at.py ATI
  quectel_at.py 'AT+QCFG="usbnet"'
  quectel_at.py usbnet            # show the current mode
  quectel_at.py usbnet ecm        # set the mode and reboot the modem
"""
import argparse
import glob
import os
import select
import sys
import time

VENDOR_ID = 0x2C7C
DEFAULT_PORT_GLOB = "/dev/cu.quectel2"
USBNET_MODES = {"rmnet": 0, "qmi": 0, "ecm": 1, "mbim": 2, "rndis": 3}
USBNET_NAMES = {0: "rmnet/qmi", 1: "ecm", 2: "mbim", 3: "rndis"}
FINAL_PREFIXES = ("OK", "ERROR", "+CME ERROR", "+CMS ERROR", "NO CARRIER")


class SerialTransport:
    def __init__(self, path):
        import termios
        import tty
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        tty.setraw(self.fd)
        attrs = termios.tcgetattr(self.fd)
        attrs[2] |= termios.CLOCAL | termios.CREAD
        attrs[4] = attrs[5] = termios.B115200
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def write(self, data):
        while data:
            _, writable, _ = select.select([], [self.fd], [], 5)
            if not writable:
                raise TimeoutError("serial port not writable")
            data = data[os.write(self.fd, data):]

    def read(self, timeout):
        readable, _, _ = select.select([self.fd], [], [], timeout)
        if not readable:
            return b""
        try:
            return os.read(self.fd, 4096)
        except BlockingIOError:
            return b""

    def close(self):
        os.close(self.fd)


class UsbTransport:
    def __init__(self, product, interface):
        try:
            import usb.core
            import usb.util
        except ImportError:
            sys.exit("pyusb is missing: brew install libusb && pip3 install pyusb")
        self.usb = usb
        find = {"idVendor": VENDOR_ID}
        if product is not None:
            find["idProduct"] = product
        self.device = usb.core.find(**find)
        if self.device is None:
            sys.exit("no Quectel modem (vendor 2c7c) found on USB")
        config = self.device.get_active_configuration()
        self.interface = None
        for candidate in config:
            if candidate.bInterfaceNumber == interface and candidate.bAlternateSetting == 0:
                self.interface = candidate
        if self.interface is None:
            sys.exit(f"modem has no USB interface {interface}")
        if self.interface.bInterfaceClass != 0xFF:
            sys.exit(f"USB interface {interface} is not a vendor serial interface; "
                     "try another --interface")
        self.number = interface
        self.ep_in = self.ep_out = None
        for endpoint in self.interface:
            if usb.util.endpoint_type(endpoint.bmAttributes) != usb.util.ENDPOINT_TYPE_BULK:
                continue
            if usb.util.endpoint_direction(endpoint.bEndpointAddress) == usb.util.ENDPOINT_IN:
                self.ep_in = self.ep_in or endpoint
            else:
                self.ep_out = self.ep_out or endpoint
        if self.ep_in is None or self.ep_out is None:
            sys.exit(f"USB interface {interface} has no bulk endpoint pair")
        try:  # Linux only: a kernel serial driver may own the interface.
            if self.device.is_kernel_driver_active(interface):
                self.device.detach_kernel_driver(interface)
        except (NotImplementedError, usb.core.USBError):
            pass
        usb.util.claim_interface(self.device, interface)
        self._line_state(True)

    def _line_state(self, on):
        # CDC SET_CONTROL_LINE_STATE (DTR|RTS), as the Linux option driver does.
        try:
            self.device.ctrl_transfer(0x21, 0x22, 3 if on else 0, self.number, None, 1000)
        except self.usb.core.USBError:
            pass

    def write(self, data):
        self.ep_out.write(data, 5000)

    def read(self, timeout):
        try:
            return bytes(self.ep_in.read(4096, max(1, int(timeout * 1000))))
        except self.usb.core.USBError as error:
            if getattr(error, "errno", None) in (60, 110) or "timed out" in str(error).lower():
                return b""
            raise

    def close(self):
        self._line_state(False)
        self.usb.util.release_interface(self.device, self.number)
        self.usb.util.dispose_resources(self.device)


def is_final(line):
    return any(line == prefix or line.startswith(prefix + ":") for prefix in FINAL_PREFIXES)


def command(transport, text, timeout=5.0):
    """Send one AT command; return (lines, ok). Raises TimeoutError on silence."""
    while transport.read(0.05):  # drop stale URCs
        pass
    transport.write(text.encode("ascii") + b"\r")
    deadline = time.monotonic() + timeout
    buffer = b""
    lines = []
    while time.monotonic() < deadline:
        buffer += transport.read(min(0.2, max(0.0, deadline - time.monotonic())))
        while b"\n" in buffer:
            raw, buffer = buffer.split(b"\n", 1)
            line = raw.decode("ascii", "replace").strip()
            if not line or (line == text and not lines):  # blank or command echo
                continue
            lines.append(line)
            if is_final(line):
                return lines, line == "OK"
    raise TimeoutError(f"no final response to {text!r} within {timeout:g}s; got {lines!r}")


def current_usbnet(transport):
    lines, ok = command(transport, 'AT+QCFG="usbnet"')
    for line in lines:
        if line.startswith('+QCFG: "usbnet",'):
            try:
                return int(line.rsplit(",", 1)[1])
            except ValueError:  # garbled line; report it below
                break
    raise RuntimeError(f"unexpected reply to usbnet query: {lines!r} (ok={ok})")


def usbnet(transport, mode):
    current = current_usbnet(transport)
    print(f"current usbnet mode: {current} ({USBNET_NAMES.get(current, 'unknown')})")
    if mode is None:
        return 0
    wanted = USBNET_MODES[mode]
    if wanted == current:
        print("already in the requested mode; nothing to do")
        return 0
    lines, ok = command(transport, f'AT+QCFG="usbnet",{wanted}')
    if not ok:
        print("modem rejected the mode change:", *lines, sep="\n  ", file=sys.stderr)
        return 1
    print(f"mode set to {wanted} ({USBNET_NAMES[wanted]}); rebooting the modem")
    try:
        command(transport, "AT+CFUN=1,1", timeout=10)
    except (TimeoutError, OSError):
        pass  # the modem may drop off the bus before answering
    except Exception as error:  # USB errors while the device disappears
        if "usb" not in type(error).__module__:
            raise
    print("the modem re-enumerates in about 20-30 seconds")
    return 0


def open_transport(args):
    if args.port:
        return SerialTransport(args.port)
    if not args.usb:
        ports = sorted(glob.glob(DEFAULT_PORT_GLOB))
        if ports:
            return SerialTransport(ports[0])
    return UsbTransport(args.product, args.interface)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", help="serial port, e.g. /dev/cu.quectel2")
    parser.add_argument("--usb", action="store_true", help="force raw USB (libusb)")
    parser.add_argument("--product", type=lambda value: int(value, 16),
                        help="USB product ID in hex, e.g. 0125 (default: any Quectel)")
    parser.add_argument("--interface", type=int, default=2,
                        help="USB interface number of the AT port (default: 2)")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("command", nargs="+",
                        help="AT commands, or: usbnet [rmnet|ecm|mbim|rndis]")
    args = parser.parse_args(argv)
    if args.command[0] == "usbnet":
        if len(args.command) > 2 or (len(args.command) == 2
                                     and args.command[1] not in USBNET_MODES):
            parser.error("usage: usbnet [rmnet|ecm|mbim|rndis]")

    transport = open_transport(args)
    try:
        if args.command[0] == "usbnet":
            return usbnet(transport, args.command[1] if len(args.command) == 2 else None)
        status = 0
        for text in args.command:
            try:
                lines, ok = command(transport, text, args.timeout)
            except TimeoutError as error:
                print(error, file=sys.stderr)
                return 2
            print("\n".join(lines))
            status = status or (0 if ok else 1)
        return status
    finally:
        try:
            transport.close()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
