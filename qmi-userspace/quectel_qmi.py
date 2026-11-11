#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Userspace QMI connection manager for Quectel modems (proof of concept).

Talks QMI to the modem through libusb and forwards IP packets between the
modem's bulk endpoints and a tunnel interface (utun on macOS, tun on Linux).
No kernel or DriverKit driver is involved.

The modem must be in RmNet/QMI mode:  AT+QCFG="usbnet",0

  quectel_qmi.py info
  sudo quectel_qmi.py connect --apn internet --default-route --set-dns
"""
import argparse
import fcntl
import os
import select
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qmi

VENDOR_ID = 0x2C7C
AUTH_MODES = {"none": 0, "pap": 1, "chap": 2, "both": 3}
DNS_SERVICE_KEY = "State:/Network/Service/quectel-qmi/DNS"


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


# --- packets ----------------------------------------------------------------

def split_ip_packets(data):
    """Split a bulk transfer into IP packets using the IP length fields.

    Normally one transfer is one packet, but nothing guarantees it, so do not
    rely on USB transfer boundaries. Anything unparsable is dropped.
    """
    packets = []
    offset = 0
    while offset < len(data):
        version = data[offset] >> 4
        if version == 4 and offset + 20 <= len(data):
            length = struct.unpack_from(">H", data, offset + 2)[0]
            minimum = 20
        elif version == 6 and offset + 40 <= len(data):
            length = struct.unpack_from(">H", data, offset + 4)[0] + 40
            minimum = 40
        else:
            break
        if length < minimum or offset + length > len(data):
            break
        packets.append(data[offset:offset + length])
        offset += length
    return packets


# --- tunnel interfaces --------------------------------------------------------

class Utun:
    """macOS utun: every packet carries a 4-byte address family header."""
    AF = {4: 2, 6: 30}  # AF_INET, AF_INET6 on Darwin

    def __init__(self):
        self.sock = socket.socket(socket.PF_SYSTEM, socket.SOCK_DGRAM,
                                  socket.SYSPROTO_CONTROL)
        self.sock.connect("com.apple.net.utun_control")  # next free unit
        name = self.sock.getsockopt(socket.SYSPROTO_CONTROL, 2, 32)  # UTUN_OPT_IFNAME
        self.name = name.split(b"\x00", 1)[0].decode()

    def fileno(self):
        return self.sock.fileno()

    def read(self):
        return self.sock.recv(65535)[4:]

    def write(self, packet):
        family = self.AF.get(packet[0] >> 4)
        if family is not None:
            self.sock.send(struct.pack(">I", family) + packet)

    def close(self):
        self.sock.close()  # destroys the interface and its routes

    def configure(self, settings, default_route):
        run(["ifconfig", self.name, "inet", settings["address"], settings["gateway"],
             "netmask", "255.255.255.255", "mtu", str(settings.get("mtu", 1500)), "up"])
        if default_route:
            # Two half-default routes win over the existing default route
            # without replacing it, and disappear together with the interface.
            for network in ("0.0.0.0/1", "128.0.0.0/1"):
                run(["route", "-n", "add", "-net", network, "-interface", self.name])


class LinuxTun:
    def __init__(self):
        self.fd = os.open("/dev/net/tun", os.O_RDWR)
        request = struct.pack("16sH", b"qmi%d", 0x0001 | 0x1000)  # IFF_TUN | IFF_NO_PI
        result = fcntl.ioctl(self.fd, 0x400454CA, request)        # TUNSETIFF
        self.name = result[:16].split(b"\x00", 1)[0].decode()

    def fileno(self):
        return self.fd

    def read(self):
        return os.read(self.fd, 65535)

    def write(self, packet):
        os.write(self.fd, packet)

    def close(self):
        os.close(self.fd)

    def configure(self, settings, default_route):
        run(["ip", "addr", "add", settings["address"], "peer", settings["gateway"],
             "dev", self.name])
        run(["ip", "link", "set", self.name, "mtu", str(settings.get("mtu", 1500)), "up"])
        if default_route:
            for network in ("0.0.0.0/1", "128.0.0.0/1"):
                run(["ip", "route", "add", network, "dev", self.name])


def open_tunnel():
    return Utun() if sys.platform == "darwin" else LinuxTun()


def run(command):
    log("+ " + " ".join(command))
    subprocess.run(command, check=True)


def set_dns(servers):
    """macOS only: publish the carrier's DNS servers through configd."""
    if sys.platform != "darwin" or not servers:
        return False
    script = (f"d.init\nd.add ServerAddresses * {' '.join(servers)}\n"
              f"set {DNS_SERVICE_KEY}\nquit\n")
    log(f"+ scutil: set {DNS_SERVICE_KEY} to {' '.join(servers)}")
    subprocess.run(["scutil"], input=script.encode(), check=True)
    return True


def clear_dns():
    subprocess.run(["scutil"], input=f"remove {DNS_SERVICE_KEY}\nquit\n".encode(),
                   check=False)


# --- USB ----------------------------------------------------------------------

def is_timeout(error):
    return (getattr(error, "backend_error_code", None) == -7
            or getattr(error, "errno", None) in (60, 110)
            or "timed out" in str(error).lower())


class UsbQmi:
    """The QMI interface of the modem: control channel plus data endpoints."""

    def __init__(self, product=None, verbose=False):
        try:
            import usb.core
            import usb.util
        except ImportError:
            sys.exit("pyusb is missing: brew install libusb && pip3 install pyusb")
        self.usb, self.verbose = usb, verbose
        find = {"idVendor": VENDOR_ID}
        if product is not None:
            find["idProduct"] = product
        self.device = usb.core.find(**find)
        if self.device is None:
            sys.exit("no Quectel modem (vendor 2c7c) found on USB")
        self.interface = None
        for candidate in self.device.get_active_configuration():
            kinds = sorted(usb.util.endpoint_type(endpoint.bmAttributes)
                           for endpoint in candidate)
            if ((candidate.bInterfaceClass, candidate.bInterfaceSubClass,
                 candidate.bInterfaceProtocol) == (0xFF, 0xFF, 0xFF)
                    and kinds == [usb.util.ENDPOINT_TYPE_BULK, usb.util.ENDPOINT_TYPE_BULK,
                                  usb.util.ENDPOINT_TYPE_INTR]):
                self.interface = candidate
                break
        if self.interface is None:
            sys.exit("the modem has no QMI interface; it is probably not in RmNet mode.\n"
                     'Switch it with: AT+QCFG="usbnet",0 and reboot the modem '
                     "(serial-driver/tools/quectel_at.py --usb usbnet rmnet)")
        self.number = self.interface.bInterfaceNumber
        self.ep_in = self.ep_out = self.ep_int = None
        for endpoint in self.interface:
            incoming = (usb.util.endpoint_direction(endpoint.bEndpointAddress)
                        == usb.util.ENDPOINT_IN)
            if usb.util.endpoint_type(endpoint.bmAttributes) == usb.util.ENDPOINT_TYPE_INTR:
                self.ep_int = endpoint
            elif incoming:
                self.ep_in = endpoint
            else:
                self.ep_out = endpoint
        self.detached = False
        try:  # Linux: take the interface away from qmi_wwan
            if self.device.is_kernel_driver_active(self.number):
                self.device.detach_kernel_driver(self.number)
                self.detached = True
        except (NotImplementedError, usb.core.USBError):
            pass
        usb.util.claim_interface(self.device, self.number)
        self._drain = False
        self._line_state(True)

    def _line_state(self, on):
        # Quectel firmware ignores the QMI interface until DTR is raised
        # (the Linux qmi_wwan driver has the same quirk for this vendor).
        try:
            self.device.ctrl_transfer(0x21, 0x22, 1 if on else 0, self.number, None, 1000)
        except self.usb.core.USBError as error:
            log(f"warning: setting DTR failed: {error}")

    def send_control(self, frame):
        if self.verbose:
            log(f"qmi > {frame.hex()}")
        self.device.ctrl_transfer(0x21, 0x00, 0, self.number, frame, 1000)

    def recv_control(self, timeout):
        # Wait for a "response available" notification, but poll anyway when
        # none arrives so a missed notification cannot stall the client.
        if not self._drain:
            try:
                self.ep_int.read(self.ep_int.wMaxPacketSize, max(1, int(timeout * 1000)))
            except self.usb.core.USBError as error:
                if not is_timeout(error):
                    raise
        try:
            frame = bytes(self.device.ctrl_transfer(0xA1, 0x01, 0, self.number, 4096, 1000))
        except self.usb.core.USBError as error:
            if getattr(error, "errno", None) == 19 or "no such device" in str(error).lower():
                raise
            frame = b""  # a stall here just means nothing is queued
        self._drain = bool(frame)
        if frame and self.verbose:
            log(f"qmi < {frame.hex()}")
        return frame or None

    def read_data(self, timeout):
        try:
            return bytes(self.ep_in.read(16384, max(1, int(timeout * 1000))))
        except self.usb.core.USBError as error:
            if is_timeout(error):
                return None
            raise

    def write_data(self, packet):
        self.ep_out.write(packet, 5000)
        if len(packet) % self.ep_out.wMaxPacketSize == 0:
            self.ep_out.write(b"", 1000)  # terminate the transfer

    def close(self):
        self._line_state(False)
        try:
            self.usb.util.release_interface(self.device, self.number)
            if self.detached:
                self.device.attach_kernel_driver(self.number)
        except self.usb.core.USBError:
            pass
        self.usb.util.dispose_resources(self.device)


# --- session ------------------------------------------------------------------

def print_status(client):
    system = client.serving_system()
    signal_info = client.signal()
    log(f"registration: {system.get('registration', '?')}, "
        f"operator: {system.get('operator', '?')} ({system.get('plmn', '?')}), "
        f"radio: {'/'.join(system.get('radio', [])) or '?'}"
        f"{', roaming' if system.get('roaming') else ''}")
    for technology, values in signal_info.items():
        log(f"signal {technology}: " + ", ".join(f"{k} {v}" for k, v in values.items()))
    return system


def wait_for_registration(client, timeout, stop):
    deadline = time.monotonic() + timeout
    while not stop.is_set():
        system = print_status(client)
        if system.get("registration") == "registered" and system.get("ps_attached", True):
            return True
        if time.monotonic() >= deadline:
            return False
        stop.wait(3)
    return False


class Pump:
    """Copies packets between the modem's data endpoints and the tunnel."""

    def __init__(self, modem, tunnel, stop):
        self.modem, self.tunnel, self.stop = modem, tunnel, stop
        self.rx_packets = self.tx_packets = self.dropped = 0
        self.threads = [threading.Thread(target=self._guard, args=(loop,), daemon=True)
                        for loop in (self._downlink, self._uplink)]
        for thread in self.threads:
            thread.start()

    def _guard(self, loop):
        try:
            loop()
        except Exception as error:
            if not self.stop.is_set():
                log(f"data path failed: {error}")
                self.stop.set()

    def _downlink(self):
        while not self.stop.is_set():
            data = self.modem.read_data(0.5)
            if not data:
                continue
            packets = split_ip_packets(data)
            if sum(len(packet) for packet in packets) != len(data):
                self.dropped += 1
            for packet in packets:
                self.tunnel.write(packet)
                self.rx_packets += 1

    def _uplink(self):
        while not self.stop.is_set():
            readable, _, _ = select.select([self.tunnel], [], [], 0.5)
            if not readable:
                continue
            packet = self.tunnel.read()
            if packet:
                self.modem.write_data(packet)
                self.tx_packets += 1

    def join(self):
        for thread in self.threads:
            thread.join(timeout=2)


def connect(client, modem, tunnel, args, stop):
    """Bring the session up, pump packets until `stop` is set, tear it down."""
    client.sync()
    link_layer = client.set_raw_ip()
    if link_layer != qmi.LINK_LAYER_RAW_IP:
        log(f"modem did not accept raw IP framing (link layer {link_layer}); giving up")
        return 1
    if not wait_for_registration(client, args.registration_timeout, stop):
        log("not registered on a network; check SIM, PIN (AT+CPIN?) and antenna")
        return 1
    log(f"starting data session{f' (APN {args.apn})' if args.apn else ' (default profile)'}")
    handle = client.start_network(apn=args.apn, username=args.user, password=args.password,
                                  auth=AUTH_MODES[args.auth] if args.auth else None,
                                  profile=args.profile)
    dns_set = False
    pump = None
    try:
        settings = client.runtime_settings()
        if "address" not in settings:
            log(f"modem reported no IPv4 address: {settings}")
            return 1
        settings.setdefault("gateway", settings["address"])
        log(f"address {settings['address']}, gateway {settings['gateway']}, "
            f"dns {' '.join(settings['dns']) or '-'}, mtu {settings.get('mtu', '?')}, "
            f"apn {settings.get('apn', '?')}")
        if args.configure:
            tunnel.configure(settings, args.default_route)
            if args.set_dns:
                dns_set = set_dns(settings["dns"])
        pump = Pump(modem, tunnel, stop)
        log(f"connected on {tunnel.name}; press Ctrl-C to disconnect")
        next_report = time.monotonic() + args.report_interval
        while not stop.wait(1):
            while not client.indications.empty():
                indication = client.indications.get()
                if (indication.service == qmi.WDS
                        and indication.message_id == qmi.WDS_GET_PACKET_SERVICE_STATUS
                        and indication.tlvs.get(0x01, b"\x02")[0] == 1):
                    log("the network ended the data session")
                    stop.set()
            if client.reader_error is not None:
                stop.set()
            if not stop.is_set() and time.monotonic() >= next_report:
                next_report = time.monotonic() + args.report_interval
                print_status(client)
                log(f"packets: {pump.rx_packets} down, {pump.tx_packets} up, "
                    f"{pump.dropped} malformed transfers")
        return 0
    finally:
        stop.set()
        if pump:
            pump.join()
        if dns_set:
            clear_dns()
        try:
            client.stop_network(handle)
            log("data session stopped")
        except Exception as error:
            log(f"stopping the data session failed: {error}")


def info(client):
    for key, value in client.device_info().items():
        log(f"{key}: {value}")
    print_status(client)
    log(f"data session: {client.packet_status()}")
    try:
        layer = client.link_layer()
        log("link layer: " + {1: "802.3", 2: "raw IP"}.get(layer, str(layer)))
    except (qmi.QmiError, qmi.QmiTimeout) as error:
        log(f"link layer: unknown ({error})")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--product", type=lambda value: int(value, 16),
                        help="USB product ID in hex, e.g. 0125 (default: any Quectel)")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="print every QMI frame in hex")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("info", help="show modem, network and signal information")
    up = commands.add_parser("connect", help="start a data session (needs root)")
    up.add_argument("--apn")
    up.add_argument("--user")
    up.add_argument("--password")
    up.add_argument("--auth", choices=sorted(AUTH_MODES))
    up.add_argument("--profile", type=int, help="3GPP profile index (as in AT+CGDCONT)")
    up.add_argument("--default-route", action="store_true",
                    help="send all IPv4 traffic through the modem")
    up.add_argument("--set-dns", action="store_true",
                    help="macOS: use the carrier's DNS servers while connected")
    up.add_argument("--no-configure", dest="configure", action="store_false",
                    help="create the tunnel but do not assign addresses or routes")
    up.add_argument("--registration-timeout", type=float, default=60)
    up.add_argument("--report-interval", type=float, default=30)
    args = parser.parse_args(argv)

    if args.command == "connect" and os.geteuid() != 0:
        sys.exit("connect needs root (tunnel interface, addresses and routes): use sudo")

    tunnel = open_tunnel() if args.command == "connect" else None
    modem = UsbQmi(args.product, args.verbose)
    client = qmi.QmiClient(modem, log)
    stop = threading.Event()
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, lambda *_: stop.set())
    try:
        if args.command == "info":
            return info(client)
        return connect(client, modem, tunnel, args, stop)
    except (qmi.QmiError, qmi.QmiTimeout, subprocess.CalledProcessError, OSError) as error:
        log(f"error: {error}")
        return 1
    finally:
        client.close()
        modem.close()
        if tunnel:
            tunnel.close()


if __name__ == "__main__":
    sys.exit(main())
