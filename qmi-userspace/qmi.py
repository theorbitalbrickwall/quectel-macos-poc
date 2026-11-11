# SPDX-License-Identifier: CC0-1.0
"""Minimal QMI protocol implementation: message codec and a blocking client.

Only what is needed to bring up an IPv4 data session and read basic status.
No USB code lives here; the client talks to anything that offers

    send_control(data: bytes) -> None
    recv_control(timeout: float) -> bytes | None     (one QMUX frame, or None)

so it runs unchanged against the fake modem used by the tests.
"""
import ipaddress
import queue
import struct
import threading

# Services
CTL, WDS, DMS, NAS, WDA = 0x00, 0x01, 0x02, 0x03, 0x1A
SERVICE_NAMES = {CTL: "CTL", WDS: "WDS", DMS: "DMS", NAS: "NAS", WDA: "WDA"}

# Messages
CTL_GET_CLIENT_ID = 0x0022
CTL_RELEASE_CLIENT_ID = 0x0023
CTL_SYNC = 0x0027
WDS_START_NETWORK = 0x0020
WDS_STOP_NETWORK = 0x0021
WDS_GET_PACKET_SERVICE_STATUS = 0x0022
WDS_GET_RUNTIME_SETTINGS = 0x002D
DMS_GET_MANUFACTURER = 0x0021
DMS_GET_MODEL = 0x0022
DMS_GET_REVISION = 0x0023
DMS_GET_IDS = 0x0025
NAS_GET_SERVING_SYSTEM = 0x0024
NAS_GET_SIGNAL_INFO = 0x004F
WDA_SET_DATA_FORMAT = 0x0020
WDA_GET_DATA_FORMAT = 0x0021

TLV_RESULT = 0x02
LINK_LAYER_802_3 = 1
LINK_LAYER_RAW_IP = 2

# Runtime settings request mask: APN, DNS, IP address, gateway, MTU
RUNTIME_SETTINGS_MASK = 0x0008 | 0x0010 | 0x0100 | 0x0200 | 0x2000

ERROR_NAMES = {
    0x0001: "MalformedMessage", 0x0002: "NoMemory", 0x0003: "Internal",
    0x0005: "InvalidClientId", 0x0009: "InvalidHandle", 0x000A: "InvalidProfile",
    0x000E: "CallFailed", 0x000F: "NotInCall", 0x0010: "NotProvisioned",
    0x0011: "MissingArgument", 0x0013: "ArgumentTooLong", 0x001A: "NoEffect",
    0x0019: "DeviceNotReady", 0x0030: "InvalidArgument", 0x0034: "OutOfCall",
    0x0047: "InvalidQmiCommand", 0x004A: "DeviceUnsupported",
    0x005E: "NotSupported",
}
CONNECTION_STATUS = {1: "disconnected", 2: "connected", 3: "suspended", 4: "authenticating"}
REGISTRATION_STATE = {0: "not registered", 1: "registered", 2: "searching",
                      3: "denied", 4: "unknown"}
RADIO_INTERFACES = {0: "none", 1: "cdma1x", 2: "evdo", 4: "gsm", 5: "umts",
                    8: "lte", 9: "td-scdma"}


class QmiError(Exception):
    def __init__(self, service, message_id, code, tlvs=None):
        self.service, self.message_id, self.code = service, message_id, code
        self.tlvs = tlvs or {}
        name = ERROR_NAMES.get(code, "unknown")
        super().__init__(f"{SERVICE_NAMES.get(service, hex(service))} message "
                         f"0x{message_id:04x} failed: error 0x{code:04x} ({name})")


class QmiTimeout(Exception):
    pass


# --- codec -----------------------------------------------------------------

def encode_tlvs(tlvs):
    out = b""
    for kind, value in tlvs:
        out += struct.pack("<BH", kind, len(value)) + value
    return out


def decode_tlvs(data):
    tlvs = {}
    offset = 0
    while offset + 3 <= len(data):
        kind, length = struct.unpack_from("<BH", data, offset)
        offset += 3
        if offset + length > len(data):
            raise ValueError("truncated TLV")
        tlvs.setdefault(kind, data[offset:offset + length])
        offset += length
    return tlvs


def encode_message(service, client, transaction, message_id, tlvs=(),
                   flags=0x00, from_service=False):
    """Build one QMUX frame. `flags` is the service-level control flag byte."""
    body = encode_tlvs(tlvs)
    if service == CTL:
        header = struct.pack("<BB", flags, transaction & 0xFF)
    else:
        header = struct.pack("<BH", flags, transaction & 0xFFFF)
    payload = header + struct.pack("<HH", message_id, len(body)) + body
    # QMUX length counts everything after the leading interface type byte.
    qmux = struct.pack("<HBBB", len(payload) + 5, 0x80 if from_service else 0x00,
                       service, client)
    return b"\x01" + qmux + payload


class Message:
    __slots__ = ("service", "client", "flags", "transaction", "message_id", "tlvs")

    def __init__(self, service, client, flags, transaction, message_id, tlvs):
        self.service, self.client, self.flags = service, client, flags
        self.transaction, self.message_id, self.tlvs = transaction, message_id, tlvs

    @property
    def is_indication(self):
        return bool(self.flags & (0x02 if self.service == CTL else 0x04))

    @property
    def is_response(self):
        return bool(self.flags & (0x01 if self.service == CTL else 0x02))

    def result(self):
        """Return the QMI error code of a response (0 on success)."""
        raw = self.tlvs.get(TLV_RESULT)
        if raw is None or len(raw) < 4:
            return 0
        status, code = struct.unpack_from("<HH", raw)
        return code if status else 0


def decode_message(frame):
    if len(frame) < 6 or frame[0] != 0x01:
        raise ValueError("not a QMUX frame")
    length, _, service, client = struct.unpack_from("<HBBB", frame, 1)
    if length + 1 > len(frame):
        raise ValueError("truncated QMUX frame")
    payload = frame[6:length + 1]
    if service == CTL:
        flags, transaction = struct.unpack_from("<BB", payload)
        offset = 2
    else:
        flags, transaction = struct.unpack_from("<BH", payload)
        offset = 3
    message_id, size = struct.unpack_from("<HH", payload, offset)
    offset += 4
    if offset + size > len(payload):
        raise ValueError("truncated QMI message")
    return Message(service, client, flags, transaction, message_id,
                   decode_tlvs(payload[offset:offset + size]))


def ipv4(raw):
    """QMI stores IPv4 addresses as little-endian integers."""
    return str(ipaddress.IPv4Address(struct.unpack("<I", raw[:4])[0]))


def text(raw):
    return raw.decode("utf-8", "replace").rstrip("\x00").strip()


# --- client ----------------------------------------------------------------

class QmiClient:
    """Blocking request/response client with a background reader thread."""

    def __init__(self, transport, log=None):
        self.transport = transport
        self.log = log or (lambda message: None)
        self.clients = {}            # service -> client id
        self.transaction = 0
        self.pending = {}            # (service, transaction) -> Queue
        self.lock = threading.Lock()
        self.indications = queue.Queue()
        self.running = True
        self.reader_error = None
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def _read_loop(self):
        while self.running:
            try:
                frame = self.transport.recv_control(0.5)
            except Exception as error:  # device unplugged, etc.
                if self.running:
                    self.reader_error = error
                    self.log(f"control channel failed: {error}")
                return
            if not frame:
                continue
            try:
                message = decode_message(frame)
            except (ValueError, struct.error) as error:
                self.log(f"ignoring undecodable frame ({error}): {frame.hex()}")
                continue
            if message.is_indication:
                self.indications.put(message)
                continue
            with self.lock:
                waiter = self.pending.pop((message.service, message.transaction), None)
            if waiter is not None:
                waiter.put(message)

    def request(self, service, message_id, tlvs=(), timeout=5.0):
        """Send a request and return the response TLVs; raise on QMI errors."""
        if service != CTL and service not in self.clients:
            self.allocate(service)
        with self.lock:
            self.transaction = self.transaction % 0xFF + 1 if service == CTL \
                else self.transaction % 0xFFFF + 1
            transaction = self.transaction
            waiter = queue.Queue(1)
            self.pending[(service, transaction)] = waiter
        frame = encode_message(service, self.clients.get(service, 0), transaction,
                               message_id, tlvs)
        self.transport.send_control(frame)
        try:
            message = waiter.get(timeout=timeout)
        except queue.Empty:
            with self.lock:
                self.pending.pop((service, transaction), None)
            if self.reader_error is not None:
                raise self.reader_error
            raise QmiTimeout(f"no response to {SERVICE_NAMES.get(service, service)} "
                             f"message 0x{message_id:04x} within {timeout:g}s")
        code = message.result()
        if code:
            raise QmiError(service, message_id, code, message.tlvs)
        return message.tlvs

    def allocate(self, service):
        tlvs = self.request(CTL, CTL_GET_CLIENT_ID, [(0x01, bytes([service]))])
        self.clients[service] = tlvs[0x01][1]
        return self.clients[service]

    def sync(self):
        """Ask the modem to drop client IDs left behind by a previous run."""
        try:
            self.request(CTL, CTL_SYNC, timeout=2.0)
        except (QmiError, QmiTimeout):
            pass

    def close(self):
        for service, client in list(self.clients.items()):
            try:
                self.request(CTL, CTL_RELEASE_CLIENT_ID,
                             [(0x01, bytes([service, client]))], timeout=2.0)
            except Exception:
                pass
            self.clients.pop(service, None)
        self.running = False
        self.reader.join(timeout=2)

    # -- device information --------------------------------------------------

    def device_info(self):
        info = {}
        for key, message_id, tlv in (("manufacturer", DMS_GET_MANUFACTURER, 0x01),
                                     ("model", DMS_GET_MODEL, 0x01),
                                     ("revision", DMS_GET_REVISION, 0x01),
                                     ("imei", DMS_GET_IDS, 0x11)):
            try:
                info[key] = text(self.request(DMS, message_id).get(tlv, b""))
            except QmiError as error:
                info[key] = f"? ({ERROR_NAMES.get(error.code, hex(error.code))})"
        return info

    def serving_system(self):
        tlvs = self.request(NAS, NAS_GET_SERVING_SYSTEM)
        system = {}
        raw = tlvs.get(0x01)
        if raw and len(raw) >= 5:
            system["registration"] = REGISTRATION_STATE.get(raw[0], str(raw[0]))
            system["ps_attached"] = raw[2] == 1
            system["radio"] = [RADIO_INTERFACES.get(value, str(value))
                               for value in raw[5:5 + raw[4]]]
        raw = tlvs.get(0x12)
        if raw and len(raw) >= 5:
            mcc, mnc, length = struct.unpack_from("<HHB", raw)
            system["plmn"] = f"{mcc:03d}{mnc:02d}"
            system["operator"] = text(raw[5:5 + length])
        raw = tlvs.get(0x10)
        if raw:
            system["roaming"] = raw[0] == 0
        return system

    def signal(self):
        tlvs = self.request(NAS, NAS_GET_SIGNAL_INFO)
        signal = {}
        raw = tlvs.get(0x14)
        if raw and len(raw) >= 6:
            rssi, rsrq, rsrp, snr = struct.unpack_from("<bbhh", raw)
            signal["lte"] = {"rssi": rssi, "rsrq": rsrq, "rsrp": rsrp, "snr": snr / 10}
        raw = tlvs.get(0x13)
        if raw and len(raw) >= 3:
            rssi, ecio = struct.unpack_from("<bh", raw)
            signal["wcdma"] = {"rssi": rssi, "ecio_raw": ecio}
        raw = tlvs.get(0x12)
        if raw:
            signal["gsm"] = {"rssi": struct.unpack_from("<b", raw)[0]}
        return signal

    # -- data session --------------------------------------------------------

    def set_raw_ip(self):
        """Select raw IP framing without aggregation; return the link layer."""
        tlvs = self.request(WDA, WDA_SET_DATA_FORMAT, [
            (0x11, struct.pack("<I", LINK_LAYER_RAW_IP)),
            (0x12, struct.pack("<I", 0)),   # uplink aggregation off
            (0x13, struct.pack("<I", 0)),   # downlink aggregation off
        ])
        raw = tlvs.get(0x11)
        return struct.unpack("<I", raw)[0] if raw else None

    def link_layer(self):
        raw = self.request(WDA, WDA_GET_DATA_FORMAT).get(0x11)
        return struct.unpack("<I", raw)[0] if raw else None

    def packet_status(self):
        raw = self.request(WDS, WDS_GET_PACKET_SERVICE_STATUS).get(0x01, b"\x00")
        return CONNECTION_STATUS.get(raw[0], str(raw[0]))

    def start_network(self, apn=None, username=None, password=None, auth=None,
                      profile=None, timeout=60.0):
        """Start the IPv4 data session and return the packet data handle."""
        tlvs = [(0x19, bytes([4]))]
        if apn:
            tlvs.append((0x14, apn.encode()))
        if username:
            tlvs.append((0x17, username.encode()))
        if password:
            tlvs.append((0x18, password.encode()))
        if auth is not None:
            tlvs.append((0x16, bytes([auth])))
        if profile is not None:
            tlvs.append((0x31, bytes([profile])))
        try:
            response = self.request(WDS, WDS_START_NETWORK, tlvs, timeout=timeout)
        except QmiError as error:
            reason = error.tlvs.get(0x11)
            if reason and len(reason) >= 4:
                kind, code = struct.unpack_from("<HH", reason)
                error.args = (f"{error.args[0]}; call end reason type {kind} code {code}",)
            raise
        return struct.unpack("<I", response[0x01])[0]

    def stop_network(self, handle):
        self.request(WDS, WDS_STOP_NETWORK, [(0x01, struct.pack("<I", handle))],
                     timeout=30.0)

    def runtime_settings(self):
        tlvs = self.request(WDS, WDS_GET_RUNTIME_SETTINGS,
                            [(0x10, struct.pack("<I", RUNTIME_SETTINGS_MASK))])
        settings = {"dns": []}
        for key, tlv in (("address", 0x1E), ("gateway", 0x20), ("netmask", 0x21)):
            if tlv in tlvs:
                settings[key] = ipv4(tlvs[tlv])
        for tlv in (0x15, 0x16):
            if tlv in tlvs and ipv4(tlvs[tlv]) != "0.0.0.0":
                settings["dns"].append(ipv4(tlvs[tlv]))
        if 0x29 in tlvs:
            settings["mtu"] = struct.unpack("<I", tlvs[0x29][:4])[0]
        if 0x14 in tlvs:
            settings["apn"] = text(tlvs[0x14])
        return settings
