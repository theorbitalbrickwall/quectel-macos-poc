# quectel-macos-poc

Proofs of concept for using a Quectel EC25 LTE modem (USB `2c7c:0125`) on
macOS. Read `README.md` first: it has the feasibility conclusions and a status
table of what is and is not verified.

## Ground rules

- The Status table in `README.md` says what has run against a real modem and
  what has not. Never describe something as working on hardware unless the
  user reported a test result or you ran it yourself. Keep the table accurate
  when that changes.
- Development happens either on Linux without Xcode or on a Mac with the
  modem plugged in. On Linux, Swift and DriverKit code can only be compiled
  and tested through the GitHub Actions workflow
  (`.github/workflows/build.yml`, macOS runner). Push, then read the run.
- On a Mac with the modem, test on the hardware yourself. Root is needed for
  `quectel_qmi.py connect`; if `sudo` is not available to you, give the user
  the command to run. While the serial driver is installed, raw USB access to
  interfaces 1 to 3 is refused. Put the modem back in the USB mode and
  profile settings you found it in, unless the user says otherwise.
- Apple framework signatures are easy to get wrong from memory. When a Swift or
  DriverKit call fails to compile, print the real header in a temporary CI step
  rather than guessing again, and remove the step afterwards.
- Without access to the hardware, the user tests and reports back. Ask for
  `quectel_qmi.py -v` output (QMI frames in hex) or `log stream` output when
  something fails.

## Layout

- `qmi-userspace/`: Python. QMI over libusb plus a `utun`/`tun` tunnel.
  `qmi.py` is the protocol (no USB code), `quectel_qmi.py` the USB transport,
  tunnel and CLI.
- `modem-gui/`: Swift package. `ModemKit` (AT parsing, transports, status
  model, SMS in PDU mode, port monitor, command list), `QuectelMenu` (AppKit menu bar app) and
  `QuectelDebug` (AppKit debug window). AT commands only. Serial ports are
  opened exclusively; the menu bar app uses port 2, the debug window port 3.
  `scripts/bundle.sh` builds the two `.app` bundles (ad hoc signed, also in
  CI), `scripts/install.sh` copies them into `/Applications`.
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
- QMI control: the modem sends one `a1 01` notification on the interrupt
  endpoint per queued response. GET_ENCAPSULATED_RESPONSE with nothing queued
  is not stalled; it blocks until the transfer times out, so never poll.
- The operator name in NAS Get Serving System is packed GSM 7-bit.
- A killed QMI client leaves its client IDs and data session on the modem
  until CTL Sync.

The first four come from the Linux `option` and `qmi_wwan` drivers and the
Quectel AT manuals; the interface layout, raw IP and the last three were
seen on the user's EC25-EUX.

## Conventions

- Python: standard library only, plus `pyusb` for USB access.
- Keep the READMEs short and in plain English. They describe the current
  state, not how it was reached: say what works and what is still untested,
  and leave test history, per-command results and fixed bugs to the commit
  messages. The Status table has one short row per item. Do not add
  "Claude found/assumed" asides to the body text; the Credits section covers
  authorship and is not to be shortened.
- User-facing docs put each shell command in its own fenced block.
- Docs and messages name the package to install (libusb, pyusb, XcodeGen),
  not a package manager command for it.
