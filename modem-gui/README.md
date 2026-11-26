# Quectel apps: menu bar and debug window

Two separate apps that talk to the modem with AT commands only. They do not
touch the data connection, so they work next to ECM (or the QMI tool).

- `QuectelMenu`: a menu bar item with the modem's state and a few controls.
- `QuectelDebug`: a window for debugging, in the spirit of Quectel's QNavigator
  for Windows. See [Debug window](#debug-window).

## Menu bar app

Shows: technology and signal bars in the menu bar; operator, band, RSRP / RSRQ
/ SINR / RSSI, registration, SIM state, APN, IP address and USB network mode in
the menu.

Controls: set the APN, switch the USB network mode (with a reboot), send a raw
AT command, read, delete and send SMS.

Works on a real modem, through the serial driver and over direct USB, except
that setting the APN has not been tried. See
[Status in the top-level README](../README.md#status).

### SMS

**Messages…** opens a window with the messages stored on the modem, with
**New Message…**, **Reply…** and **Delete…**. When a message arrives, the app
beeps and the menu bar shows an envelope with the number of new messages
until the window is opened.

- Any character can be sent and received, including Turkish letters and
  emoji. Long messages are split when sent and joined when received.
- The app uses the storage the modem is set to (`AT+CPMS`) and switches the
  port to PDU mode (`AT+CMGF=0`, the modem's default).
- Sent messages are not kept.
- Reading the list marks the messages as read on the modem, so after a
  restart of the app they no longer count as new.

### Run

Needs the Xcode command line tools, nothing else:

```bash
swift run -c release QuectelMenu
```

One status poll in the terminal, without the menu bar (good first test):

```bash
swift run -c release QuectelMenu --status
```

The stored SMS in the terminal:

```bash
swift run -c release QuectelMenu --messages
```

Send one SMS from the terminal:

```bash
swift run -c release QuectelMenu --send-sms +491701234567 "Merhaba dünya"
```

## Debug window

```bash
swift run -c release QuectelDebug
```

- Left: a list of ready-made AT commands, in groups (module, SIM, network,
  data, USB, GNSS, SMS, power). Double-click one to send it. Commands with an
  orange warning triangle change the modem's state and ask first. Commands
  with a blue pencil have values to fill in, so they are put in the input
  field instead of being sent. The same legend is shown under the list.
- Right: a log with a timestamp on every line. `>` is what was sent, `<` is
  what the modem sent, including messages it sends on its own (URCs).
- Bottom: type any AT command and press Return. Up and Down recall earlier
  commands. **Save Log…** writes the log to a text file.

Pick the port at the top and press **Connect**. The modem port
(`/dev/cu.quectel3`) is the default, so the debug window and the menu bar app
(which uses `/dev/cu.quectel2`) can run at the same time. By default the modem
sends URCs to the AT port only; to see them, quit the menu bar app and connect
to `/dev/cu.quectel2`.

A port can be open in one program at a time. A second program gets "Resource
busy". This is on purpose: two programs on one port would take each other's
replies. It also applies to `quectel_at.py` while one of the apps has the port.

One command without the window, for scripts and quick tests:

```bash
swift run -c release QuectelDebug --run ATI
```

```bash
swift run -c release QuectelDebug --port /dev/cu.quectel2 --run ATI
```

Not included (QNavigator has them): SMS and call screens, TCP/IP tests,
firmware download.

Not tested on hardware: the triangle and pencil commands, typed commands and
history, and Save Log.

## How the apps reach the modem

1. If the serial driver from `../serial-driver` is installed, they use its
   ports (`/dev/cu.quectel2` for the menu bar app).
2. Otherwise they open the modem's USB interface directly through Apple's
   IOUSBHost framework (interface 2 for the menu bar app).

On macOS 27 this works without `sudo`. If `--status` fails with "Cannot open
the modem's USB interface", try it once with `sudo`.

## Notes

- SINR comes from `AT+QCSQ`, which reports 0 to 250, and is converted to dB
  as value / 5 - 20. The manual does not state this formula; on the EC25-EUX
  the result agrees with `AT+QENG="servingcell"` to within about 2 dB.
- The APN change applies to the first PDP context and takes effect the next
  time the modem attaches.

## Tests

```bash
swift test
```

## Files

- `Sources/ModemKit`: AT parsing, AT channel, status model, SMS (`SMS.swift`),
  serial and USB transports, the port monitor and the command list of the debug window.
- `Sources/QuectelMenu`: the menu bar app; `Messages.swift` is the SMS window.
- `Sources/QuectelDebug/main.swift`: the debug window.
- `Tests/ModemKitTests`: tests with a fake modem.
