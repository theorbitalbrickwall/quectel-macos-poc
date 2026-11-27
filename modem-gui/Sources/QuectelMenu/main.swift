// SPDX-License-Identifier: CC0-1.0
// Menu bar status and control app for a Quectel modem, using AT commands only.
// The data connection itself (ECM, QMI, ...) is not touched.
//
//   swift run QuectelMenu            menu bar app
//   swift run QuectelMenu --status   print one status poll and exit
//   swift run QuectelMenu --messages             print the stored SMS and exit
//   swift run QuectelMenu --send-sms NUMBER TEXT send one SMS and exit
import AppKit
import ModemKit
import ServiceManagement

let serialPort = "/dev/cu.quectel2"

/// Prefer the serial driver's port when it exists, else go straight to USB.
func openModem() throws -> Modem {
    let transport: ByteTransport = FileManager.default.fileExists(atPath: serialPort)
        ? try SerialTransport(path: serialPort)
        : try USBTransport()
    return Modem(channel: ATChannel(transport: transport))
}

/// Icon for alerts. A program that is not an app bundle gets the generic
/// folder icon otherwise.
func appIcon() -> NSImage? {
    let style = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
    return NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                   accessibilityDescription: "Modem")?.withSymbolConfiguration(style)
}

/// An alert with our icon. `NSApp.applicationIconImage` does not reach alerts.
func makeAlert() -> NSAlert {
    let alert = NSAlert()
    if let icon = appIcon() { alert.icon = icon }
    return alert
}

func describe(_ status: ModemStatus) -> [String] {
    var lines: [String] = []
    if let name = status.operatorName?.best, !name.isEmpty { lines.append("Operator: \(name)") }
    if let network = status.network {
        lines.append("Network: \(network.technology), \(network.band)")
    }
    if let signal = status.signal {
        // Two short lines: received power, then quality (LTE only).
        var power: [String] = []
        if let value = signal.rsrp { power.append("RSRP \(value) dBm") }
        if let value = signal.rssi { power.append("RSSI \(value) dBm") }
        lines.append("Signal: " + (power.isEmpty ? signal.mode : power.joined(separator: ", ")))
        var quality: [String] = []
        if let value = signal.rsrq { quality.append("RSRQ \(value) dB") }
        if let value = signal.sinrDB { quality.append("SINR \(value) dB") }
        if !quality.isEmpty { lines.append("Quality: " + quality.joined(separator: ", ")) }
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

/// Run a command line action on the modem and exit.
func runOnce(_ work: (Modem) throws -> Void) -> Never {
    do {
        let modem = try openModem()
        defer { modem.channel.close() }
        try work(modem)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--messages") {
    runOnce { modem in
        let messages = try modem.messages()
        let dates = messageDates()
        print(messages.isEmpty ? "No messages." : messages.map {
            describe($0, dates: dates) + "\n" + $0.text
        }.joined(separator: "\n\n"))
    }
}

if let flag = CommandLine.arguments.firstIndex(of: "--send-sms") {
    guard CommandLine.arguments.count == flag + 3 else {
        FileHandle.standardError.write(Data("usage: QuectelMenu --send-sms NUMBER TEXT\n".utf8))
        exit(2)
    }
    runOnce { modem in
        try modem.sendMessage(to: CommandLine.arguments[flag + 1], text: CommandLine.arguments[flag + 2])
        print("Sent.")
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
    private let messagesWindow = MessagesWindow()
    private var messages: [SMSMessage] = []
    /// Messages that arrived and were not looked at yet, by first storage index.
    private var unseen: Set<Int> = []
    /// Messages the user has had in front of them.
    private var acknowledged: Set<Int> = []
    /// Stored message count at the last listing. Worker queue only.
    private var listedCount: Int?
    private var refreshPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.title = "Modem…"
        buildMainMenu()
        messagesWindow.onCompose = { [weak self] number in self?.compose(to: number) }
        messagesWindow.onDelete = { [weak self] message in self?.delete(message) }
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

    /// Not shown (the app has no menu bar of its own), but without it Copy
    /// and Paste do not work in the text fields.
    private func buildMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func refresh() {
        // Sending a message can take minutes; do not queue a poll per tick.
        guard !refreshPending else { return }
        refreshPending = true
        perform({ modem in
            let status = try modem.status()
            // List the messages only when something changed: listing is slow
            // with a full storage.
            var listed: [SMSMessage]?
            let notice = modem.takeNewMessageNotice()
            if let count = try modem.storedMessageCount() {
                if notice || count != self.listedCount {
                    do {
                        listed = try modem.messages()
                        self.listedCount = count
                    } catch ModemError.rejected(_) {
                        // SIM not ready yet; try again at the next poll.
                    }
                }
            } else {
                self.listedCount = nil
                listed = []
            }
            DispatchQueue.main.async {
                self.status = status
                self.problem = nil
                if let listed { self.received(listed) }
            }
        }) { _ in
            self.refreshPending = false
        }
    }

    private func received(_ list: [SMSMessage]) {
        let present = Set(list.compactMap { $0.indices.first })
        acknowledged.formIntersection(present)
        unseen.formIntersection(present)
        let before = unseen.count
        for message in list where message.unread {
            if let key = message.indices.first, !acknowledged.contains(key) { unseen.insert(key) }
        }
        if unseen.count > before { NSSound.beep() }
        messages = list
        messagesWindow.update(list, fresh: unseen)
        if messagesWindow.isVisible { acknowledge() }
    }

    private func acknowledge() {
        acknowledged.formUnion(messages.compactMap { $0.indices.first })
        unseen = []
    }

    private func rebuildMenu() {
        item.button?.title = (status?.title ?? "No modem") + (unseen.isEmpty ? "" : " ✉\(unseen.count)")
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
        _ = add(unseen.isEmpty ? "Messages…" : "Messages (\(unseen.count) new)…", #selector(showMessages),
                enabled: status != nil)
        _ = add("New message…", #selector(newMessage), enabled: status != nil)
        menu.addItem(.separator())
        _ = add("Refresh now", #selector(refresh))
        // Only an installed app can be a login item, not `swift run`.
        if Bundle.main.bundleURL.pathExtension == "app" {
            add("Open at login", #selector(toggleOpenAtLogin)).state =
                SMAppService.mainApp.status == .enabled ? .on : .off
        }
        _ = add("Quit", #selector(quit))
        item.menu = menu
    }

    @objc private func noop() {}

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            show("Open at login was not changed", detail: error.localizedDescription)
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func ask(_ message: String, detail: String, value: String) -> String? {
        let alert = makeAlert()
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
        let alert = makeAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func setAPN() {
        guard let context = status?.contexts.first,
              let apn = ask("Set APN", detail: "Applies to context \(context.cid) (\(context.type)). "
                  + "It is used the next time the modem attaches to the network.",
                  value: context.apn), apn != context.apn else { return }
        perform({ try $0.setAPN(apn, context: context) }) { error in
            if let error {
                self.show("The APN was not changed", detail: error.localizedDescription)
                self.refresh()
            } else {
                self.offerReboot()
            }
        }
    }

    /// A stored APN is only used once the modem attaches again; a reboot does that.
    private func offerReboot() {
        let alert = makeAlert()
        alert.messageText = "Reboot the modem now?"
        alert.informativeText = "The new APN is stored. The data connection keeps the old one until "
            + "the modem attaches to the network again. A reboot does that; the current data "
            + "connection drops while the modem restarts."
        alert.addButton(withTitle: "Reboot")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            refresh()
            return
        }
        perform({ modem in
            modem.reboot()
            // The modem is rebooting; drop the connection so the next poll reopens it.
            throw ModemError.io("The modem is rebooting…")
        })
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let mode = USBNetMode(rawValue: sender.tag), mode != status?.usbNetMode else { return }
        let alert = makeAlert()
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

    @objc private func showMessages() {
        messagesWindow.update(messages, fresh: unseen)
        messagesWindow.show()
        acknowledge()
        rebuildMenu()
    }

    @objc private func newMessage() {
        compose(to: "")
    }

    private func compose(to number: String, text: String = "") {
        let alert = makeAlert()
        alert.messageText = "New message"
        alert.informativeText = "A long message, or one with characters such as ş or an emoji, "
            + "is sent in several parts. Your operator may charge for each part."
        let field = NSTextField(frame: NSRect(x: 0, y: 136, width: 340, height: 24))
        field.placeholderString = "Phone number, for example +491701234567"
        field.stringValue = number
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 128))
        editor.isRichText = false
        editor.font = NSFont.systemFont(ofSize: 13)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.string = text
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 128))
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 160))
        box.addSubview(field)
        box.addSubview(scroll)
        alert.accessoryView = box
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = number.isEmpty ? field : editor
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let recipient = field.stringValue
        let message = editor.string
        guard SMSEncoder.normalizedNumber(recipient) != nil, !message.isEmpty else {
            show("The message was not sent", detail: "Enter a phone number (digits, with or without "
                + "a leading +) and a text.")
            compose(to: recipient, text: message)
            return
        }
        let parts = SMSEncoder.partCount(message).parts
        perform({ try $0.sendMessage(to: recipient, text: message) }) { error in
            if let error {
                self.show("The message was not sent", detail: error.localizedDescription)
            } else {
                self.show("Message sent", detail: "To \(recipient)" + (parts > 1 ? ", in \(parts) parts." : "."))
            }
            self.refresh()
        }
    }

    private func delete(_ message: SMSMessage) {
        let alert = makeAlert()
        alert.messageText = "Delete this message?"
        alert.informativeText = "It is removed from the modem and cannot be restored."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform({ try $0.delete(message) }) { error in
            if let error { self.show("The message was not deleted", detail: error.localizedDescription) }
            self.refresh()
        }
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
