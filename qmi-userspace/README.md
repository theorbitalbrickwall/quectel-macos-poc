# Userspace QMI connection tool

Brings up a cellular data connection over QMI without any driver. A Python
script talks QMI to the modem through libusb and copies IP packets between the
modem and a `utun` interface (the interface type VPN apps use).

Never run against a real modem. The QMI logic and the packet path are tested
against a simulated modem, including pings through a real tunnel interface on
Linux; the macOS `utun` code and the libusb code are untested.

## Setup

The modem must be in RmNet/QMI mode (`AT+QCFG="usbnet",0`):

```bash
python3 ../serial-driver/tools/quectel_at.py --usb usbnet rmnet
```

```bash
brew install libusb
```

```bash
pip3 install pyusb
```

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
- `--default-route` sends all IPv4 traffic through the modem. It adds two
  half-default routes (`0.0.0.0/1`, `128.0.0.0/1`) instead of replacing your
  default route; they vanish when the tool exits.
- `--set-dns` (macOS) publishes the carrier's DNS servers while connected.
  This is the part Claude Fable 5.2 (the LLM that wrote this tool) is least sure
  about; if names do not resolve, set the DNS
  servers printed in the log manually.
- Ctrl-C disconnects cleanly.
- `-v` prints every QMI frame in hex. Please include that output when
  something fails; it is what is needed to fix it.

The same script works on Linux (it takes the interface away from `qmi_wwan`
while running), which is a quick way to check the QMI part with your modem
before trying macOS.

## Limits

- IPv4 only.
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
