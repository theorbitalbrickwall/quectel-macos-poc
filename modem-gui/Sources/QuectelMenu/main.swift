// SPDX-License-Identifier: CC0-1.0
// Menu bar status and control app for a Quectel modem, using AT commands only.
// The data connection itself (ECM, QMI, ...) is not touched.
//
//   swift run QuectelMenu            menu bar app
//   swift run QuectelMenu --status   print one status poll and exit
import AppKit
import ModemKit

let serialPort = "/dev/cu.quectel2"

/// Prefer the serial driver's port when it exists, else go straight to USB.
func openModem() throws -> Modem {
    let transport: ByteTransport = FileManager.default.fileExists(atPath: serialPort)
        ? try SerialTransport(path: serialPort)
        : try USBTransport()
    return Modem(channel: ATChannel(transport: transport))
}

func describe(_ status: ModemStatus) -> [String] {
    var lines: [String] = []
    if let name = status.operatorName?.best, !name.isEmpty { lines.append("Operator: \(name)") }
    if let network = status.network {
        lines.append("Network: \(network.technology), \(network.band)")
    }
    if let signal = status.signal {
        var parts: [String] = []
        if let value = signal.rsrp { parts.append("RSRP \(value) dBm") }
        if let value = signal.rsrq { parts.append("RSRQ \(value) dB") }
        if let value = signal.sinr { parts.append("SINR \(value)") }
        if let value = signal.rssi { parts.append("RSSI \(value) dBm") }
        lines.append("Signal: " + (parts.isEmpty ? signal.mode : parts.joined(separator: ", ")))
    }
    if let registration = status.registration { lines.append("Registration: \(registration.label)") }
    if let sim = status.sim { lines.append("SIM: \(sim)") }
    if let apn = status.apn { lines.append("APN: \(apn.isEmpty ? "(network default)" : apn)") }
    if let address = status.address { lines.append("IP: \(address)") }
    if let mode = status.usbNetMode { lines.append("USB mode: \(mode.label)") }
    return lines
}

if CommandLine.arguments.contains("--status") {
    do {
        let modem = try openModem()
        let status = try modem.status()
        modem.channel.close()
        print(([status.title] + describe(status)).joined(separator: "\n"))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// All modem I/O happens here, one command at a time.
    private let worker = DispatchQueue(label: "modem")
    private var modem: Modem?
    private var status: ModemStatus?
    private var problem: String?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.title = "Modem…"
        rebuildMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    /// Run `work` on the worker queue with an open modem, then update the menu.
    private func perform(_ work: @escaping (Modem) throws -> Void, then: ((Error?) -> Void)? = nil) {
        worker.async {
            var failure: Error?
            do {
                if self.modem == nil { self.modem = try openModem() }
                try work(self.modem!)
            } catch {
                failure = error
                // Reopen next time: the modem may have been replugged or rebooted.
                self.modem?.channel.close()
                self.modem = nil
            }
            DispatchQueue.main.async {
                if let failure {
                    self.status = nil
                    self.problem = failure.localizedDescription
                }
                self.rebuildMenu()
                then?(failure)
            }
        }
    }

    @objc private func refresh() {
        perform({ modem in
            let status = try modem.status()
            DispatchQueue.main.async {
                self.status = status
                self.problem = nil
            }
        })
    }

    private func rebuildMenu() {
        item.button?.title = status?.title ?? "No modem"
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = enabled && action != nil
            menu.addItem(entry)
            return entry
        }
        if let status {
            for line in describe(status) { _ = add(line) }
        } else {
            _ = add(problem ?? "Looking for the modem…")
        }
        menu.addItem(.separator())
        _ = add("Set APN…", #selector(setAPN), enabled: status?.contexts.first != nil)
        let modes = add("USB network mode", #selector(noop), enabled: status?.usbNetMode != nil)
        let submenu = NSMenu()
        for mode in USBNetMode.allCases {
            let entry = NSMenuItem(title: mode.label, action: #selector(setMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = mode.rawValue
            entry.state = status?.usbNetMode == mode ? .on : .off
            submenu.addItem(entry)
        }
        modes.submenu = submenu
        _ = add("Send AT command…", #selector(sendCommand), enabled: status != nil)
        menu.addItem(.separator())
        _ = add("Refresh now", #selector(refresh))
        _ = add("Quit", #selector(quit))
        item.menu = menu
    }

    @objc private func noop() {}

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func ask(_ message: String, detail: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func show(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func setAPN() {
        guard let context = status?.contexts.first,
              let apn = ask("Set APN", detail: "Applies to context \(context.cid) (\(context.type)). "
                  + "It is used the next time the modem attaches to the network.",
                  value: context.apn) else { return }
        perform({ try $0.setAPN(apn, context: context) }) { error in
            if let error { self.show("The APN was not changed", detail: error.localizedDescription) }
            self.refresh()
        }
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let mode = USBNetMode(rawValue: sender.tag), mode != status?.usbNetMode else { return }
        let alert = NSAlert()
        alert.messageText = "Switch the modem to \(mode.label)?"
        alert.informativeText = "The modem reboots and the current data connection drops. "
            + "macOS only has a built-in network driver for ECM."
        alert.addButton(withTitle: "Switch and Reboot")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform({ modem in
            try modem.setUSBNetMode(mode)
            // The modem is rebooting; drop the connection so the next poll reopens it.
            throw ModemError.io("The modem is rebooting into \(mode.label)…")
        })
    }

    @objc private func sendCommand() {
        guard let command = ask("Send AT command", detail: "The reply is shown when it arrives.",
                                value: "ATI"), !command.isEmpty else { return }
        var reply = ""
        perform({ reply = try $0.channel.command(command).lines.joined(separator: "\n") }) { error in
            self.show(command, detail: error?.localizedDescription ?? reply)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
