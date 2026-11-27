# quectel-macos-poc

Goal: make a Quectel EC25 (USB `2c7c:0125`) usable on macOS as a cellular
modem, not only as a USB Ethernet dongle in ECM mode.

Reusing Apple's own cellular stack is not viable (see
[Feasibility](#feasibility)), so this repository holds three independent
proofs of concept:

| Folder | What it is | Needs |
| --- | --- | --- |
| [`qmi-userspace/`](qmi-userspace/) | Data connection over QMI from a Python script, through libusb and a `utun` interface | `usbnet` 0, libusb + pyusb, root |
| [`modem-gui/`](modem-gui/) | Two apps over AT commands: a menu bar app (signal, operator, APN, USB mode, eSIM profiles, SMS) and a debug window (live AT log, command list). They leave the data connection alone | Xcode command line tools |
| [`serial-driver/`](serial-driver/) | DriverKit driver publishing the AT ports as `/dev/cu.quectel*`, plus an AT command script that also works without the driver | Paid Apple Developer team for the driver; nothing for the script |

Suggested order for testing: `serial-driver/tools/quectel_at.py --usb ATI`
first (proves USB access works at all), then `modem-gui` with `--status`, then
`qmi-userspace`.

Everything here assumes that one modem is plugged in. With two, the tools
cannot tell them apart.

## Feasibility

| Approach | Verdict |
| --- | --- |
| Apple's cellular stack (AppleWWANSupport / CoreWWAN) | No |
| DriverKit MBIM driver that shows up as Ethernet | Possible, not worth it |
| Userspace QMI over libusb and `utun` | Yes: [`qmi-userspace/`](qmi-userspace/) |
| Serial port driver for the AT interfaces | Yes: [`serial-driver/`](serial-driver/) |

**Apple's cellular stack.** The WWAN support is a private Apple kext with a
built-in vendor list. Changing the list, or injecting matches with a codeless
kext as [karnadii/FibocomModem](https://github.com/karnadii/FibocomModem)
does, needs SIP off and reduced boot security, after every macOS update. That
project also reports that the WWAN configuration UI is gone from Ventura on
(one report, no Apple statement). DriverKit has no cellular family.

**DriverKit MBIM driver.**
[jquirke/AQC111Driver](https://github.com/jquirke/AQC111Driver) shows that a
USB network driver on DriverKit works. But macOS would still see an Ethernet
adapter: no signal bars, no APN UI, the same experience as ECM. The driver
would have to fake Ethernet headers, answer ARP and neighbour discovery,
implement MBIM, and Apple would have to approve the entitlements. The only
gains are no double NAT and the carrier IP. Whether macOS has its own MBIM
class driver is unknown; no evidence of one was found.

**Userspace QMI.** The EC25 sends raw IP packets in QMI mode and macOS has a
raw-IP interface type (`utun`), so a normal program can run the whole
connection without a driver or entitlements. macOS shows a VPN-like interface
instead of a "Cellular" service, and packets pass through userspace.

**Serial port driver.** The AT ports are vendor-specific USB interfaces, so
Apple's CDC ACM driver ignores them; SerialDriverKit covers this case. The
ports are enough to switch the modem to ECM without a Linux or Windows
machine. The modem port also accepts PPP dial-up (`ATD*99#`), if your macOS
still ships `pppd`.

## Status

Hardware means one EC25-EUX on an M1 Max with macOS 27.

| Item | Without hardware | On hardware |
| --- | --- | --- |
| `qmi-userspace` | 28 tests against a simulated modem | `info` and `connect` work. Not tested: speed, long sessions |
| `modem-gui`: `ModemKit` | 72 unit tests | |
| `modem-gui`: menu bar app | Compiles | Works through the driver and over direct USB. A new APN is used after the modem re-attaches; the reboot offered for that is only tested over direct USB |
| `modem-gui`: SMS | Unit-tested against a fake modem | Works |
| `modem-gui`: eSIM profiles (needs an eUICC as the SIM) | Unit-tested against a fake modem, parser fuzzed | Listing and switching work from the terminal over direct USB. Not tested: the submenu, the driver's port |
| `modem-gui`: `QuectelDebug` | Monitor and command list are unit-tested | Read-only commands work through the driver and over direct USB. Not tested: commands that change the modem, typed commands, Save Log |
| `modem-gui`: installable apps | Apps and disk image build in CI | Work, signed and notarised, including the start at login. Not tested: a download on another Mac |
| `quectel_at.py`, serial port | 7 tests against a fake modem | Works through the driver's ports |
| `quectel_at.py`, raw USB | | Works without root. Cannot be used while the driver is installed |
| `serial-driver`: driver and installer | Compiles; logic fuzzed against a fake DriverKit | Ports 1 to 3 appear; AT commands work on 2 and 3, NMEA data arrives on 1. Not tested: PPP, unplugging while open |

The protocol details (QMI message layouts, the USB interface layout, raw IP
in QMI mode) come from the Linux drivers and libqmi. The AT commands were
checked against Quectel's manuals. If `qmi-userspace` fails, its `-v` output
is the most useful thing to report.

## Other files

- `.github/workflows/build.yml`: runs all tests, compiles the driver and
  builds the two apps (artifact `quectel-apps`) on a macOS runner, and fuzzes
  the driver for a minute on Linux.

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
  here. The eSIM commands (`AT+QESIM`) and their error codes are from
  Quectel's EC2x&EG2x&EG9x&EM05 Series eSIM LPA Application Note V1.0. The
  debug window is modelled on Quectel's QNavigator tool for Windows.
- The GSMA specification
  [SGP.22](https://www.gsma.com/solutions-and-impact/technologies/esim/gsma_resources/sgp-22-v3-0/)
  (RSP Technical Specification, V3.0): what enabling an eSIM profile does to
  the profile in use, and the meaning of the eSIM error codes.
- The 3GPP specifications
  [TS 23.040](https://www.3gpp.org/dynareport/23040.htm) and
  [TS 23.038](https://www.3gpp.org/dynareport/23038.htm) (as ETSI TS 123 040
  and TS 123 038, V19.0.0): the SMS message layout, long messages, the GSM
  7-bit alphabet and the Turkish character tables used by `modem-gui`. The SMS
  AT commands are those of
  [TS 27.005](https://www.3gpp.org/dynareport/27005.htm).

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
