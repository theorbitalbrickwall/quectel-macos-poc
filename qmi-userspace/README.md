# Userspace QMI connection tool

Brings up a cellular data connection over QMI without any driver. A Python
script talks QMI to the modem through libusb and copies IP packets between the
modem and a `utun` interface (the interface type VPN apps use).

Works on a real modem; see
[Status in the top-level README](../README.md#status).

## Setup

The modem must be in RmNet/QMI mode (`AT+QCFG="usbnet",0`):

```bash
python3 ../serial-driver/tools/quectel_at.py usbnet rmnet
```

Switch back with `usbnet ecm`.

The tool needs [libusb](https://libusb.info) and
[pyusb](https://github.com/pyusb/pyusb). Install them with your package
manager; pyusb is also on PyPI.

## Use

Status only, no root needed:

```bash
python3 quectel_qmi.py info
```

Connect (root is needed for the tunnel interface, address and routes):

```bash
sudo python3 quectel_qmi.py connect --apn internet --default-route --set-dns
```

- Without `--apn` the modem's default profile is used.
- `--ipv6` adds an IPv6 session next to the IPv4 one. The profile must have
  the type `IPV4V6`; list the profiles with `quectel_at.py 'AT+CGDCONT?'` and
  choose one with `--profile N`. If the network refuses IPv6, the tool carries
  on with IPv4.
- `--default-route` sends all traffic through the modem. It adds two
  half-default routes (`0.0.0.0/1`, `128.0.0.0/1`, and `::/1`, `8000::/1` with
  `--ipv6`) instead of replacing your default route; they vanish when the
  tool exits.
- `--set-dns` (macOS) puts the carrier's DNS servers first while connected.
- Ctrl-C disconnects cleanly.
- `-v` prints every QMI frame in hex. Include that output when reporting a
  failure.

The same script works on Linux (it takes the interface away from `qmi_wwan`
while running), which is a quick way to check the QMI part with your modem
before trying macOS.

## Limits

- Without `--ipv6`, IPv6 traffic keeps using your other connection, if it
  has IPv6.
- One instance at a time; a second one cannot claim the USB interface.
- SIM PIN is not handled; disable it or enter it with
  `quectel_at.py 'AT+CPIN="1234"'` first.
- macOS shows a `utun` interface, not a "Cellular" service.
- Python in the packet path: expect tens of Mbit/s, not the modem's maximum.
- Assumes the EC25 only does raw IP framing without aggregation, as the Linux
  `qmi_wwan` driver treats it. The tool refuses to continue if the modem says
  otherwise.

## Tests

```bash
python3 test_qmi.py
```

The tunnel test needs Linux, root and the `ip` command; it is skipped
elsewhere.

## Files

- `qmi.py`: QMI message codec and client (no USB code).
- `quectel_qmi.py`: USB transport, tunnel interfaces, command line.
- `test_qmi.py`: simulated modem and tests.
