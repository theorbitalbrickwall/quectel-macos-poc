# quectel-macos-poc

Proofs of concept for using a Quectel EC25 LTE modem (USB `2c7c:0125`) on
macOS. Read `README.md` first: it has the feasibility conclusions and a status
table of what is and is not verified.

## Ground rules

- Almost no code here has run against a real modem; the Status table in
  `README.md` lists the exceptions. Never describe something as working on
  hardware unless the user reported a test result or you ran it yourself.
  Keep the Status table in `README.md` accurate when that changes.
- Development happens on Linux without Xcode. Swift and DriverKit code can only
  be compiled and tested through the GitHub Actions workflow
  (`.github/workflows/build.yml`, macOS runner). Push, then read the run.
- Apple framework signatures are easy to get wrong from memory. When a Swift or
  DriverKit call fails to compile, print the real header in a temporary CI step
  rather than guessing again, and remove the step afterwards.
- The user tests on hardware and reports back. Ask for `quectel_qmi.py -v`
  output (QMI frames in hex) or `log stream` output when something fails.

## Layout

- `qmi-userspace/`: Python. QMI over libusb plus a `utun`/`tun` tunnel.
  `qmi.py` is the protocol (no USB code), `quectel_qmi.py` the USB transport,
  tunnel and CLI.
- `modem-gui/`: Swift package. `ModemKit` (AT parsing, transports, status
  model, port monitor, command list), `QuectelMenu` (AppKit menu bar app) and
  `QuectelDebug` (AppKit debug window). AT commands only. Serial ports are
  opened exclusively; the menu bar app uses port 2, the debug window port 3.
- `serial-driver/`: DriverKit serial driver (`Driver/`), installer app
  (`Installer/`), XcodeGen project (`project.yml`), and
  `tools/quectel_at.py` (AT commands over a serial port or raw USB).

## Tests

```bash
python3 qmi-userspace/test_qmi.py
```

```bash
python3 serial-driver/tools/test_quectel_at.py
```

The QMI tunnel test needs Linux, root, `/dev/net/tun` and the `ip` command
(`apt-get install iproute2`); it is skipped otherwise. Swift tests
(`swift test --package-path modem-gui`) and the driver build
(`serial-driver/scripts/build.sh --unsigned`) only run on macOS.

The driver logic is fuzzed against a fake DriverKit (Linux: needs `clang` and
`libclang-rt-18-dev`; macOS: needs an LLVM `clang` 22, not Xcode's; see
`serial-driver/fuzz/README.md`). Run it after any change to
`serial-driver/Driver/`, and keep `fuzz/shim/QuectelSerial*.h` in sync with
the `.iig` files:

```bash
serial-driver/fuzz/run.sh 60
```

Both Python tools are tested against simulated modems (`FakeModem` in each
test file). Extend the fake when adding protocol features.

## Modem facts the code relies on

- USB network mode: `AT+QCFG="usbnet",N` with 0 RmNet/QMI, 1 ECM, 2 MBIM,
  3 RNDIS; takes effect after a reboot (`AT+CFUN=1,1`).
- Interfaces: 0 DM, 1 NMEA, 2 AT, 3 modem (PPP), 4 network. The serial ones
  are vendor class `ff/00/00`; the QMI interface is `ff/ff/ff` with one
  interrupt and two bulk endpoints.
- The modem needs DTR raised (CDC SET_CONTROL_LINE_STATE) on an interface
  before it talks on it.
- QMI data is raw IP, no aggregation.

These come from the Linux `option` and `qmi_wwan` drivers and the Quectel AT
manuals, not from a capture of the user's device.

## Conventions

- Python: standard library only, plus `pyusb` for USB access.
- Keep the READMEs short and in plain English.
- User-facing docs put each shell command in its own fenced block.
