#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Tests for the QMI client and the packet pump, using a simulated modem.

The tunnel test creates a real tun interface and pings through it; it needs
Linux and root and is skipped elsewhere.
"""
import ipaddress
import os
import queue
import struct
import subprocess
import sys
import threading
import types
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qmi
import quectel_qmi

ADDRESS, GATEWAY = "10.170.23.5", "10.170.23.6"
ADDRESS6, GATEWAY6, DNS6 = "2001:db8:1:2::5", "2001:db8:1:2::1", "2001:db8::53"
HANDLE, HANDLE6 = 0x1234ABCD, 0x66660006


def le_ip(address):
    return struct.pack("<I", int(ipaddress.IPv4Address(address)))


def raw_ip6(address):
    return ipaddress.IPv6Address(address).packed


def checksum(data):
    if len(data) % 2:
        data += b"\x00"
    total = sum(struct.unpack(f">{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


class FakeModem:
    """Answers QMI requests and replies to ICMP echo requests on the data path."""

    def __init__(self, registered=True, raw_ip=True, call_fails=False, ipv6=True):
        self.control = queue.Queue()
        self.data = queue.Queue()
        self.registered, self.raw_ip, self.call_fails = registered, raw_ip, call_fails
        self.ipv6 = ipv6
        self.clients = {}            # service -> list of client ids
        self.families = {}           # WDS client id -> 6, when bound to IPv6
        self.next_client = 1
        self.connected = self.connected6 = False
        self.requests = []
        self.uplink = []

    # control channel ---------------------------------------------------------
    def send_control(self, frame):
        message = qmi.decode_message(frame)
        self.requests.append((message.service, message.message_id))
        tlvs = self.handle(message)
        if tlvs is None:
            return  # simulate a lost response
        if not any(kind == qmi.TLV_RESULT for kind, _ in tlvs):
            tlvs.insert(0, (qmi.TLV_RESULT, struct.pack("<HH", 0, 0)))
        self.control.put(qmi.encode_message(
            message.service, message.client, message.transaction, message.message_id,
            tlvs, flags=0x01 if message.service == qmi.CTL else 0x02, from_service=True))

    def recv_control(self, timeout):
        try:
            return self.control.get(timeout=timeout)
        except queue.Empty:
            return None

    def indicate(self, service, message_id, tlvs):
        self.control.put(qmi.encode_message(service, 0xFF, 0, message_id, tlvs,
                                            flags=0x04, from_service=True))

    @staticmethod
    def failure(code, extra=()):
        return [(qmi.TLV_RESULT, struct.pack("<HH", 1, code)), *extra]

    def handle(self, message):
        key = (message.service, message.message_id)
        tlvs = message.tlvs
        if (message.service != qmi.CTL
                and message.client not in self.clients.get(message.service, [])):
            return self.failure(0x0005)
        six = self.families.get(message.client) == 6
        if key == (qmi.CTL, qmi.CTL_SYNC):
            self.clients.clear()
            self.families.clear()
            self.connected = self.connected6 = False
            return []
        if key == (qmi.CTL, qmi.CTL_GET_CLIENT_ID):
            service = tlvs[0x01][0]
            self.clients.setdefault(service, []).append(self.next_client)
            self.next_client += 1
            return [(0x01, bytes([service, self.next_client - 1]))]
        if key == (qmi.CTL, qmi.CTL_RELEASE_CLIENT_ID):
            service, client = tlvs[0x01]
            self.clients[service].remove(client)
            if not self.clients[service]:
                del self.clients[service]
            return [(0x01, tlvs[0x01])]
        if key == (qmi.WDS, qmi.WDS_SET_IP_FAMILY):
            self.families[message.client] = tlvs[0x01][0]
            return []
        if key == (qmi.WDA, qmi.WDA_SET_DATA_FORMAT):
            wanted = struct.unpack("<I", tlvs[0x11])[0]
            return [(0x11, struct.pack("<I", wanted if self.raw_ip else 1))]
        if key == (qmi.WDA, qmi.WDA_GET_DATA_FORMAT):
            return [(0x11, struct.pack("<I", 2 if self.raw_ip else 1))]
        if key == (qmi.NAS, qmi.NAS_GET_SERVING_SYSTEM):
            state = 1 if self.registered else 2
            name = b"Fake Mobile"
            return [(0x01, bytes([state, 1, state, 1, 1, 8])),
                    (0x10, bytes([1])),
                    (0x12, struct.pack("<HHB", 262, 1, len(name)) + name)]
        if key == (qmi.NAS, qmi.NAS_GET_SIGNAL_INFO):
            return [(0x14, struct.pack("<bbhh", -67, -9, -95, 132))]
        if key == (qmi.WDS, qmi.WDS_START_NETWORK):
            if self.call_fails or tlvs[0x19][0] != (6 if six else 4):
                return self.failure(0x000E, [(0x11, struct.pack("<HH", 6, 33))])
            if six:
                if not self.ipv6:
                    return self.failure(0x000E, [(0x11, struct.pack("<HH", 2, 210))])
                self.connected6 = True
                return [(0x01, struct.pack("<I", HANDLE6))]
            self.connected = True
            self.apn = tlvs.get(0x14, b"").decode()
            return [(0x01, struct.pack("<I", HANDLE))]
        if key == (qmi.WDS, qmi.WDS_STOP_NETWORK):
            if struct.unpack("<I", tlvs[0x01])[0] != (HANDLE6 if six else HANDLE):
                return self.failure(0x0009)
            if six:
                self.connected6 = False
            else:
                self.connected = False
            return []
        if key == (qmi.WDS, qmi.WDS_GET_PACKET_SERVICE_STATUS):
            return [(0x01, bytes([2 if self.connected else 1]))]
        if key == (qmi.WDS, qmi.WDS_GET_RUNTIME_SETTINGS):
            if not (self.connected6 if six else self.connected):
                return self.failure(0x000F)
            if six:
                return [(0x25, raw_ip6(ADDRESS6) + b"\x40"), (0x26, raw_ip6(GATEWAY6) + b"\x40"),
                        (0x27, raw_ip6(DNS6)), (0x28, bytes(16)),
                        (0x29, struct.pack("<I", 1430))]
            return [(0x1E, le_ip(ADDRESS)), (0x20, le_ip(GATEWAY)),
                    (0x21, le_ip("255.255.255.252")), (0x15, le_ip("9.9.9.9")),
                    (0x16, le_ip("0.0.0.0")), (0x29, struct.pack("<I", 1430)),
                    (0x14, self.apn.encode())]
        if key == (qmi.DMS, qmi.DMS_GET_IDS):
            return [(0x11, b"860000000000001")]
        if message.service == qmi.DMS:
            return [(0x01, {qmi.DMS_GET_MANUFACTURER: b"Quectel", qmi.DMS_GET_MODEL: b"EC25",
                            qmi.DMS_GET_REVISION: b"EC25EUXGAR08A05M1G"}[message.message_id])]
        return self.failure(0x0047)

    # data path ---------------------------------------------------------------
    def write_data(self, packet):
        self.uplink.append(packet)
        header = (packet[0] & 0x0F) * 4
        if packet[0] >> 4 != 4 or packet[9] != 1 or packet[header] != 8:
            return
        icmp = bytearray(packet[header:])
        icmp[0] = 0
        icmp[2:4] = b"\x00\x00"
        icmp[2:4] = struct.pack(">H", checksum(bytes(icmp)))
        ip = bytearray(packet[:header])
        ip[12:16], ip[16:20] = packet[16:20], packet[12:16]
        ip[10:12] = b"\x00\x00"
        ip[10:12] = struct.pack(">H", checksum(bytes(ip)))
        self.data.put(bytes(ip) + bytes(icmp))

    def read_data(self, timeout):
        try:
            return self.data.get(timeout=timeout)
        except queue.Empty:
            return None


def make_client(modem):
    client = qmi.QmiClient(modem)
    return client


class CodecTest(unittest.TestCase):
    def test_known_frame_layout(self):
        # CTL "get client id" for WDS, transaction 1: bytes as seen on the wire
        # with libqmi/qmi_wwan.
        frame = qmi.encode_message(qmi.CTL, 0, 1, qmi.CTL_GET_CLIENT_ID, [(0x01, b"\x01")])
        self.assertEqual(frame.hex(), "010f0000000000012200040001010001")

    def test_service_frame_layout(self):
        frame = qmi.encode_message(qmi.WDS, 7, 0x0102, qmi.WDS_START_NETWORK,
                                   [(0x14, b"internet")])
        self.assertEqual(frame[:6].hex(), "011700000107")
        self.assertEqual(frame[6:13].hex(), "00020120000b00")
        self.assertEqual(struct.unpack_from("<H", frame, 1)[0], len(frame) - 1)

    def test_round_trip_and_result(self):
        frame = qmi.encode_message(qmi.NAS, 3, 9, 0x004F,
                                   [(qmi.TLV_RESULT, struct.pack("<HH", 1, 0x000E)),
                                    (0x14, b"abc")], flags=0x02, from_service=True)
        message = qmi.decode_message(frame)
        self.assertEqual((message.service, message.client, message.transaction), (qmi.NAS, 3, 9))
        self.assertTrue(message.is_response)
        self.assertFalse(message.is_indication)
        self.assertEqual(message.result(), 0x000E)
        self.assertEqual(message.tlvs[0x14], b"abc")

    def test_truncated_frames_are_rejected(self):
        frame = qmi.encode_message(qmi.WDS, 1, 1, 0x0020, [(0x14, b"internet")])
        for cut in (3, 8, len(frame) - 1):
            with self.assertRaises((ValueError, struct.error)):
                qmi.decode_message(frame[:cut])

    def test_operator_name_plain_and_gsm7_packed(self):
        self.assertEqual(qmi.operator_name(b"Fake Mobile"), "Fake Mobile")
        # As sent by an EC25-EUX: 8 characters packed into 7 bytes.
        self.assertEqual(qmi.operator_name(bytes.fromhex("d4ba7c3d2eb3d9")), "Turkcell")
        # 7 characters in 7 bytes leave one empty septet at the end.
        self.assertEqual(qmi.operator_name(bytes.fromhex("d4ba7c3d2eb301")), "Turkcel")
        self.assertEqual(qmi.operator_name(b""), "")

    def test_ipv4_is_little_endian(self):
        self.assertEqual(qmi.ipv4(bytes([5, 23, 170, 10])), "10.170.23.5")


class PacketSplitTest(unittest.TestCase):
    @staticmethod
    def v4(size):
        return struct.pack(">BBH", 0x45, 0, size) + bytes(size - 4)

    @staticmethod
    def v6(payload):
        return struct.pack(">IH", 0x60000000, payload) + bytes(34 + payload)

    def test_single_and_merged_packets(self):
        a, b, c = self.v4(84), self.v6(16), self.v4(1024)
        self.assertEqual(quectel_qmi.split_ip_packets(a), [a])
        self.assertEqual(quectel_qmi.split_ip_packets(a + b + c), [a, b, c])

    def test_garbage_and_truncation_are_dropped(self):
        a = self.v4(60)
        self.assertEqual(quectel_qmi.split_ip_packets(b"\x00" * 40), [])
        self.assertEqual(quectel_qmi.split_ip_packets(a + self.v4(100)[:50]), [a])
        self.assertEqual(quectel_qmi.split_ip_packets(struct.pack(">BBH", 0x45, 0, 8) + bytes(40)), [])


class ClientTest(unittest.TestCase):
    def setUp(self):
        self.modem = FakeModem()
        self.client = make_client(self.modem)
        self.addCleanup(self.client.close)

    def test_status_queries(self):
        self.assertEqual(self.client.device_info(),
                         {"manufacturer": "Quectel", "model": "EC25",
                          "revision": "EC25EUXGAR08A05M1G", "imei": "860000000000001"})
        system = self.client.serving_system()
        self.assertEqual(system, {"registration": "registered", "ps_attached": True,
                                  "radio": ["lte"], "plmn": "26201",
                                  "operator": "Fake Mobile", "roaming": False})
        self.assertEqual(self.client.signal(),
                         {"lte": {"rssi": -67, "rsrq": -9, "rsrp": -95, "snr": 13.2}})

    def test_session_lifecycle(self):
        self.assertEqual(self.client.set_raw_ip(), qmi.LINK_LAYER_RAW_IP)
        self.assertEqual(self.client.packet_status(), "disconnected")
        handle = self.client.start_network(apn="internet")
        self.assertEqual(self.client.packet_status(), "connected")
        self.assertEqual(self.client.runtime_settings(),
                         {"dns": ["9.9.9.9"], "address": ADDRESS, "gateway": GATEWAY,
                          "netmask": "255.255.255.252", "mtu": 1430, "apn": "internet"})
        self.client.stop_network(handle)
        self.assertFalse(self.modem.connected)

    def test_ipv6_session_on_a_second_client(self):
        handle = self.client.start_network(apn="internet")
        client6 = self.client.allocate(qmi.WDS, extra=True)
        self.assertNotEqual(client6, self.client.clients[qmi.WDS])
        self.client.set_ip_family(6, client6)
        handle6 = self.client.start_network(apn="internet", family=6, client=client6)
        self.assertEqual(self.client.runtime_settings(client6),
                         {"dns": [DNS6], "address6": ADDRESS6, "prefix6": 64,
                          "gateway6": GATEWAY6, "mtu": 1430})
        self.assertEqual(self.client.runtime_settings()["address"], ADDRESS)
        self.client.stop_network(handle6, client6)
        self.assertTrue(self.modem.connected, "stopping IPv6 must leave IPv4 up")
        self.assertFalse(self.modem.connected6)
        self.client.stop_network(handle)
        self.client.close()
        self.assertEqual(self.modem.clients, {})

    def test_one_client_id_per_service_and_release(self):
        self.client.signal()
        self.client.serving_system()
        allocations = [r for r in self.modem.requests if r == (qmi.CTL, qmi.CTL_GET_CLIENT_ID)]
        self.assertEqual(len(allocations), 1)
        self.client.close()
        self.assertEqual(self.modem.clients, {})

    def test_call_failure_reports_reason(self):
        self.modem.call_fails = True
        with self.assertRaises(qmi.QmiError) as caught:
            self.client.start_network(apn="wrong")
        self.assertEqual(caught.exception.code, 0x000E)
        self.assertIn("CallFailed", str(caught.exception))
        self.assertIn("type 6 code 33", str(caught.exception))

    def test_lost_response_times_out(self):
        self.modem.handle = lambda message: None
        with self.assertRaises(qmi.QmiTimeout):
            self.client.request(qmi.CTL, qmi.CTL_SYNC, timeout=0.3)

    def test_indications_are_queued_not_matched_as_responses(self):
        self.modem.indicate(qmi.WDS, qmi.WDS_GET_PACKET_SERVICE_STATUS, [(0x01, b"\x01\x00")])
        self.assertEqual(self.client.packet_status(), "disconnected")
        indication = self.client.indications.get(timeout=1)
        self.assertEqual(indication.tlvs[0x01][0], 1)


def arguments(**overrides):
    values = dict(apn="internet", user=None, password=None, auth=None, profile=None,
                  ipv6=False, default_route=False, set_dns=False, configure=True,
                  registration_timeout=1, report_interval=3600)
    values.update(overrides)
    return types.SimpleNamespace(**values)


class RecordingTunnel:
    name = "test0"

    def __init__(self):
        self.read_end, self.write_end = os.pipe()
        self.written, self.configured = [], None

    def fileno(self):
        return self.read_end

    def read(self):
        return os.read(self.read_end, 65535)

    def write(self, packet):
        self.written.append(packet)

    def configure(self, settings, default_route):
        self.configured = (settings, default_route)


class ConnectFlowTest(unittest.TestCase):
    def run_connect(self, modem, tunnel, stop, **overrides):
        client = make_client(modem)
        self.addCleanup(client.close)
        quectel_qmi.log = lambda message: None
        return quectel_qmi.connect(client, modem, tunnel, arguments(**overrides), stop)

    def test_refuses_without_raw_ip(self):
        modem = FakeModem(raw_ip=False)
        self.assertEqual(self.run_connect(modem, RecordingTunnel(), threading.Event()), 1)
        self.assertFalse(modem.connected)

    def test_gives_up_when_not_registered(self):
        modem = FakeModem(registered=False)
        self.assertEqual(self.run_connect(modem, RecordingTunnel(), threading.Event()), 1)
        self.assertNotIn((qmi.WDS, qmi.WDS_START_NETWORK), modem.requests)

    def test_connects_configures_and_stops_on_network_disconnect(self):
        modem, tunnel, stop = FakeModem(), RecordingTunnel(), threading.Event()
        threading.Timer(1.5, lambda: modem.indicate(
            qmi.WDS, qmi.WDS_GET_PACKET_SERVICE_STATUS, [(0x01, b"\x01\x00")])).start()
        watchdog = threading.Timer(15, stop.set)
        watchdog.start()
        self.addCleanup(watchdog.cancel)
        self.assertEqual(self.run_connect(modem, tunnel, stop, default_route=True), 0)
        settings, default_route = tunnel.configured
        self.assertEqual((settings["address"], settings["gateway"], settings["mtu"]),
                         (ADDRESS, GATEWAY, 1430))
        self.assertTrue(default_route)
        self.assertFalse(modem.connected, "session must be stopped on exit")
        self.assertTrue(watchdog.is_alive(), "should exit on the indication, not the watchdog")
        self.assertNotIn("address6", settings)

    def run_briefly(self, modem, tunnel, **overrides):
        stop = threading.Event()
        threading.Timer(1.5, stop.set).start()
        self.assertEqual(self.run_connect(modem, tunnel, stop, **overrides), 0)
        return tunnel.configured[0]

    def test_ipv6_adds_a_second_session(self):
        modem, tunnel = FakeModem(), RecordingTunnel()
        settings = self.run_briefly(modem, tunnel, ipv6=True)
        self.assertEqual((settings["address"], settings["address6"], settings["prefix6"]),
                         (ADDRESS, ADDRESS6, 64))
        self.assertEqual(settings["dns"], ["9.9.9.9", DNS6])
        self.assertFalse(modem.connected or modem.connected6, "both sessions must be stopped")

    def test_ipv6_refused_by_the_network_keeps_ipv4(self):
        modem, tunnel = FakeModem(ipv6=False), RecordingTunnel()
        settings = self.run_briefly(modem, tunnel, ipv6=True)
        self.assertEqual(settings["address"], ADDRESS)
        self.assertNotIn("address6", settings)
        self.assertFalse(modem.connected)


@unittest.skipUnless(sys.platform == "linux" and os.geteuid() == 0
                     and os.path.exists("/dev/net/tun"), "needs Linux, root and /dev/net/tun")
class TunnelTest(unittest.TestCase):
    @staticmethod
    def ping(interface, count, size):
        """Send ICMP echo requests out of `interface`; return the reply count."""
        import socket
        replies = 0
        with socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode())
            sock.settimeout(2)
            for sequence in range(count):
                payload = bytes([sequence]) * size
                header = struct.pack(">BBHHH", 8, 0, 0, 0x4242, sequence)
                header = struct.pack(">BBHHH", 8, 0, checksum(header + payload),
                                     0x4242, sequence)
                sock.sendto(header + payload, (GATEWAY, 0))
                try:
                    reply, _ = sock.recvfrom(65535)
                except socket.timeout:
                    continue
                icmp = reply[(reply[0] & 0x0F) * 4:]
                if icmp[0] == 0 and icmp[8:] == payload and checksum(icmp) == 0:
                    replies += 1
        return replies

    def test_ping_through_real_tunnel(self):
        import shutil
        if shutil.which("ip") is None:
            self.skipTest("the ip command is not installed")
        try:
            tunnel = quectel_qmi.LinuxTun()
        except OSError as error:
            self.skipTest(f"cannot create a tun interface here: {error}")
        self.addCleanup(tunnel.close)
        modem, stop = FakeModem(), threading.Event()
        client = make_client(modem)
        self.addCleanup(client.close)
        quectel_qmi.log = lambda message: None
        result = []
        worker = threading.Thread(target=lambda: result.append(
            quectel_qmi.connect(client, modem, tunnel, arguments(), stop)))
        worker.start()
        try:
            for _ in range(50):
                if modem.connected and tunnel.name in subprocess.run(
                        ["ip", "-o", "-4", "addr"], capture_output=True, text=True).stdout:
                    break
                stop.wait(0.1)
            replies = self.ping(tunnel.name, count=3, size=1000)
        finally:
            stop.set()
            worker.join(timeout=10)
        self.assertEqual(replies, 3)
        self.assertEqual(len(modem.uplink), 3)
        self.assertEqual(result, [0])
        self.assertFalse(modem.connected)


if __name__ == "__main__":
    unittest.main()
