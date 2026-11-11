# Quectel serial driver for macOS

Publishes the vendor-specific serial interfaces of a Quectel modem as normal
serial ports, so you can send AT commands (for example to switch the USB
network mode) from macOS.

Lightly tested on one EC25-EUX (macOS 27, Apple silicon): the ports appear and
answer AT commands. Read [Status in the top-level README](../README.md#status).

## Fastest path: no driver

`tools/quectel_at.py` can talk to the AT interface directly through libusb.
macOS attaches no driver to these interfaces, so nothing has to be installed
or signed:

```bash
brew install libusb
```

```bash
pip3 install pyusb
```

```bash
python3 tools/quectel_at.py --usb usbnet
```

```bash
python3 tools/quectel_at.py --usb usbnet ecm
```

`usbnet` alone prints the current mode. `usbnet ecm|mbim|rndis|rmnet` sets it
and reboots the modem with `AT+CFUN=1,1`. Any other argument is sent as an AT
command, for example `python3 tools/quectel_at.py --usb ATI`.

If the AT port is not USB interface 2 on your module or mode, pass
`--interface N`. On the EC25 the layout is normally 0 = DM, 1 = NMEA, 2 = AT,
3 = modem (PPP).

## The driver

### What it does

- Matches every Quectel (`idVendor` 0x2c7c) interface with class `ff`,
  subclass `00`, protocol `00`. That is the NMEA, AT and modem port, in every
  USB network mode. The DM port and the network interface are left alone, so
  Apple's ECM driver keeps working next to it.
- Creates `/dev/cu.quectel<N>` and `/dev/tty.quectel<N>`, where `N` is the USB
  interface number. The AT port is normally `/dev/cu.quectel2`.
- Baud rate, parity and flow control settings are accepted and ignored (the
  link is USB). DTR/RTS are forwarded to the modem.

### Requirements

- macOS 14 or later, full Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`).
- A paid Apple Developer team. DriverKit entitlements (`driverkit`,
  `driverkit.family.serial`, `driverkit.transport.usb`) are only issued through
  Apple provisioning profiles. For development on your own registered Mac the
  wildcard USB entitlement in `Driver/Driver.entitlements` is what Xcode
  provisions; distributing to other Macs needs an Apple-approved grant for
  vendor ID 0x2c7c.

Without a paid team the usual workaround is disabling SIP, running
`systemextensionsctl developer on` and ad-hoc signing. This was not tried, and
it is unknown whether it still works on current macOS; use the libusb script
instead.

### Build and install

Compile check only (output cannot be loaded):

```bash
scripts/build.sh --unsigned
```

Signed development build:

```bash
DEVELOPMENT_TEAM=YOURTEAMID scripts/build.sh
```

Then copy the app to `/Applications` (activation is refused from anywhere
else), start it and press **Install / Update**:

```bash
ditto build/Build/Products/Release/QuectelSerial.app /Applications/QuectelSerial.app
```

```bash
open /Applications/QuectelSerial.app
```

Approve the extension in System Settings → General → Login Items & Extensions
→ Driver Extensions, replug the modem, then:

```bash
ls /dev/cu.quectel*
```

```bash
python3 tools/quectel_at.py usbnet
```

With the driver installed the script uses `/dev/cu.quectel2` automatically;
`--port` selects another one. `screen /dev/cu.quectel2` works too.

### If something does not work

Driver log:

```bash
log stream --predicate 'eventMessage CONTAINS "QuectelSerial"'
```

Which driver, if any, is attached to each interface:

```bash
ioreg -p IOUSB -l -w0 | less
```

Most likely problems, since this code has met only one modem:

- No ports appear: the interface descriptors differ from what Claude Fable 5.2
  (the LLM that wrote the driver) assumed (`ff/00/00`). Check `bInterfaceClass/SubClass/Protocol` in the `ioreg` output
  and adjust the `QuectelSerial` personality in `Driver/Info.plist`.
- Ports appear but the modem never answers: check the log for failed
  transfers, and try the modem port (`/dev/cu.quectel3`).

## Layout

- `Driver/QuectelSerialInterface.*`: owns one USB interface and its bulk pipes.
- `Driver/QuectelSerialPort.*`: the `IOUserSerial` service and ring buffers.
- `Installer/`: host app that activates the driver extension.
- `tools/quectel_at.py`: AT command tool (serial port or raw USB).
- `tools/test_quectel_at.py`: tests for the tool, using a fake modem.
- `fuzz/`: fuzz harness that runs the driver sources on Linux against a fake
  DriverKit. See [`fuzz/README.md`](fuzz/README.md).

## Credits

The driver contains code from
[idy/ch348-macos](https://github.com/idy/ch348-macos) (MIT), which is one of
the few open-source `IOUserSerial` drivers verified on hardware: mainly the
queue set-up and ring buffer handling of the port, the installer app and the
project files. Its licence is in [`LICENSE-ch348-macos`](LICENSE-ch348-macos).

The full list for the whole repository is in the
[top-level README](../README.md#credits).
