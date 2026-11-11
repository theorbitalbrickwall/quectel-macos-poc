# quectel-macos-poc

Goal: make a Quectel EC25 (USB `2c7c:0125`) usable on macOS as a cellular
modem, not only as a USB Ethernet dongle in ECM mode.

Reusing Apple's own cellular stack is not viable (see
[Feasibility](#feasibility)), so this repository holds three independent
proofs of concept to try on real hardware:

| Folder | What it is | Needs |
| --- | --- | --- |
| [`qmi-userspace/`](qmi-userspace/) | Data connection over QMI from a Python script, through libusb and a `utun` interface | `usbnet` 0, libusb + pyusb, root |
| [`modem-gui/`](modem-gui/) | Two apps over AT commands: a menu bar app (signal, operator, APN, USB mode) and a debug window (live AT log, command list). They leave the data connection alone | Xcode command line tools |
| [`serial-driver/`](serial-driver/) | DriverKit driver publishing the AT ports as `/dev/cu.quectel*`, plus an AT command script that also works without the driver | Paid Apple Developer team for the driver; nothing for the script |

A few things have been run on a Mac with a modem attached: the `--status` poll
of `modem-gui`, and read-only AT commands through the serial driver. See
[Status](#status) for exactly what was and was not verified.

Suggested order for testing: `serial-driver/tools/quectel_at.py --usb ATI`
first (proves USB access works at all), then `modem-gui` with `--status`, then
`qmi-userspace`.

## Feasibility

### 1. Reusing Apple's cellular stack (AppleWWANSupport / CoreWWAN): no

- The WWAN support is a private Apple kext with a built-in vendor list, which is
  what blocked the earlier attempt. Changing that list means modifying an Apple
  kext: SIP off, an unsealed system volume, and on Apple silicon a reduced
  security boot policy. It has to be redone after every macOS update.
- A third-party "codeless" kext that only injects matching entries (the approach
  of [karnadii/FibocomModem](https://github.com/karnadii/FibocomModem)) has the
  same kext restrictions. That project also reports that from Ventura on the
  modem is still detected but the WWAN configuration UI is gone, so even a
  successful match gives you a service you cannot configure. Claude Fable 5.2 found only
  this one report and no Apple statement, so treat it as likely rather than proven.
- DriverKit, the supported driver model, has no cellular/WWAN family. A driver
  extension cannot register a device with CoreWWAN.

### 2. A DriverKit MBIM driver that shows up as Ethernet: possible, not worth it

[jquirke/AQC111Driver](https://github.com/jquirke/AQC111Driver) shows that a
USB network driver built on USBDriverKit + NetworkingDriverKit works on current
macOS, so an MBIM driver is technically possible. It was not written because:

- macOS would still see an Ethernet adapter, not a cellular modem. No signal
  bars, no APN UI. This is the same user experience as ECM mode.
- MBIM carries raw IP packets, while `IOUserNetworkEthernet` wants Ethernet
  frames. The driver would have to fake Ethernet headers and answer ARP and
  IPv6 neighbour discovery itself, implement the MBIM control protocol (open,
  PIN, register, attach, connect) and NTB framing, and a helper would have to
  apply the IP configuration.
- Distribution needs the USB transport and networking entitlements approved by
  Apple.

The only gains over ECM are no double NAT and direct access to the carrier IP.

One thing Claude Fable 5.2 could not determine: whether macOS ships its own MBIM
class driver. It found no evidence that it does. You can check in two minutes:
switch the modem to MBIM (`usbnet` 2), replug, and look at whether any driver
attaches to the MBIM interface:

```bash
ioreg -p IOUSB -l -w0 | less
```

### 3. Userspace QMI (or MBIM) over libusb and `utun`: yes

The EC25 sends raw IP packets in QMI mode and macOS has a raw-IP interface
type (`utun`), so a normal program can run the whole connection: no driver, no
Apple entitlements. The price is that macOS shows a VPN-like interface instead
of a "Cellular" service, and packets pass through userspace. See
[`qmi-userspace/`](qmi-userspace/).

### 4. A serial port driver for the AT interfaces: yes

The EC25's AT ports are vendor-specific USB interfaces, so Apple's CDC ACM
driver ignores them. SerialDriverKit supports exactly this case. The driver in
[`serial-driver/`](serial-driver/) publishes them as `/dev/cu.quectel*`, which
is enough to send `AT+QCFG="usbnet",1` and switch to ECM without a Linux or
Windows machine. The same folder has a script that does the switch with no
driver at all, through libusb.

The modem port (`/dev/cu.quectel3`) also accepts PPP dial-up (`ATD*99#`), which
is the closest thing to "a modem as a modem" that macOS still allows, provided
your macOS version still ships `pppd`. Not tested.

## Status

| Item | State |
| --- | --- |
| `qmi-userspace`: QMI protocol, connect flow, packet path | Tested against a simulated modem (17 tests), including pings through a real tunnel interface on Linux |
| `qmi-userspace`: libusb access, macOS `utun`, routes and DNS setup | Written, never run |
| `modem-gui`: AT parsing and modem logic | Unit-tested on a GitHub macOS 15 runner (see the "Build and test" workflow) and on macOS 27 with Xcode 27 (24 tests) |
| `modem-gui`: direct USB access | `--status` ran once on an M1 Max (macOS 27) against an EC25-EUX without a SIM, in ECM mode, as a normal user without `sudo`. It printed plausible values. No other command was tried. With the serial driver installed, `--status` also works through `/dev/cu.quectel2` |
| `modem-gui`: menu bar UI | Compiles; never run |
| `modem-gui`: debug window (`QuectelDebug`) | Monitor and command list are unit-tested. `--run` works on the EC25-EUX through `/dev/cu.quectel2` and `3`, and a second program on the same port is refused. In the window, connect, disconnect, changing the port and sending read-only commands from the list work. Commands that change the modem, typed commands, Save Log and direct USB (no driver) are not tested |
| `serial-driver/tools/quectel_at.py`, serial transport | Tested against a fake modem on a pseudo-terminal (7 tests). `ATI` and `usbnet` (read only) work through the driver's ports on the EC25-EUX. Switching the mode is not tested |
| `quectel_at.py`, raw USB transport | Written, never run against hardware |
| `serial-driver` driver and installer | Compile unsigned on the runner and on macOS 27 with Xcode 27 (DriverKit 27.0 SDK). The development-signed build also succeeds there, with the DriverKit entitlements provisioned by Xcode. Installed on an M1 Max (macOS 27) with an EC25-EUX: the driver loads and `/dev/cu.quectel1`, `2` and `3` appear. The first build crashed on the first write to a port (read-only transmit buffer). After the fix, `ATI` and `AT+QCFG="usbnet"` get correct answers on `/dev/cu.quectel2` and `ATI` on `/dev/cu.quectel3`, with no new crash. The NMEA port, PPP, unplugging while open and long sessions are not tested |
| `serial-driver` driver logic | Fuzzed on Linux against a fake DriverKit ([`serial-driver/fuzz/`](serial-driver/fuzz/)); two stalls found and fixed, no memory errors. It missed the read-only transmit buffer crash that the hardware test found; the fake now models that case. This tests the logic against a fake DriverKit that Claude Fable 5.2 wrote from the public headers, not against real macOS |

The protocol details (QMI message layouts, the EC25's USB interface layout and
its raw-IP-only behaviour) come from what Claude Fable 5.2 knows about the Linux drivers and
libqmi, not from a capture of your modem. Expect to need a round of fixes; the
`-v` output of `quectel_qmi.py` is the most useful thing to send back.

## Other files

- `.github/workflows/build.yml`: runs all tests and compiles the Swift app and
  the driver on a macOS runner, and fuzzes the driver for a minute on Linux.

## Credits

This project was generated by an LLM, Claude Fable 5.2 (Anthropic), working
with the repository owner, who directed the work and tested it on hardware.

An LLM does not invent this kind of code from nothing. It relies on other
people's work: the projects below, and also the public code, documentation and
discussions the model was trained on, which cannot be listed one by one.

Projects the code follows:

- [idy/ch348-macos](https://github.com/idy/ch348-macos) (MIT): the serial
  driver contains code from this driver, mainly the queue set-up and ring
  buffer handling of the port, the installer app and the project files. Its
  licence is in
  [`serial-driver/LICENSE-ch348-macos`](serial-driver/LICENSE-ch348-macos). It
  is one of the few open-source `IOUserSerial` drivers verified on hardware.
- The Linux kernel drivers
  [`option`](https://github.com/torvalds/linux/blob/master/drivers/usb/serial/option.c)
  and
  [`qmi_wwan`](https://github.com/torvalds/linux/blob/master/drivers/net/usb/qmi_wwan.c):
  the EC25's USB interface layout, the rule for which interfaces are serial
  ports, the DTR request, and the raw-IP behaviour in QMI mode. Facts only;
  no code was taken.
- [libqmi](https://gitlab.freedesktop.org/mobile-broadband/libqmi): the QMI
  message layouts and the connect sequence used by `qmi-userspace`. Facts
  only; no code was taken.
- Quectel's AT command manuals for the EC2x series: every AT command used
  here. The debug window is modelled on Quectel's QNavigator tool for Windows.

Projects that answered the feasibility questions:

- [karnadii/FibocomModem](https://github.com/karnadii/FibocomModem): shows
  what happens when a modem is injected into Apple's WWAN support.
- [jquirke/AQC111Driver](https://github.com/jquirke/AQC111Driver): shows that
  a USB network driver built on DriverKit works on current macOS.

Tools and libraries used:

- [libusb](https://libusb.info) and [pyusb](https://github.com/pyusb/pyusb)
  for USB access from Python.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode
  project of the driver.
- [libFuzzer](https://llvm.org/docs/LibFuzzer.html) with AddressSanitizer for
  fuzzing the driver logic.

## License

This work is dedicated to the public domain under
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/). You
may use it for anything, without asking and without giving credit. Where the
law does not allow giving up copyright, CC0 grants the same freedom as a
licence instead. There is no warranty. The full text is in
[`LICENSE`](LICENSE).

Exception: the parts of `serial-driver/` taken from
[idy/ch348-macos](https://github.com/idy/ch348-macos) are not mine to give
away. They stay under the MIT licence in
[`serial-driver/LICENSE-ch348-macos`](serial-driver/LICENSE-ch348-macos), which
asks you to keep that file when you copy them. The files that contain such
code say so in their first lines.
