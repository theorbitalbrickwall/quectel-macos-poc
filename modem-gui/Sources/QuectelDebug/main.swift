// SPDX-License-Identifier: CC0-1.0
// Debug window for a Quectel modem: a live log of everything on one AT port,
// a command line with history, and a list of ready-made commands.
//
//   swift run QuectelDebug                        the window
//   swift run QuectelDebug --run ATI              send one command, print the log, exit
//   swift run QuectelDebug --port /dev/cu.quectel2 --run ATI
import AppKit
import ModemKit

/// One way to reach the modem.
struct PortChoice {
    var title: String
    var open: () throws -> ByteTransport
}

/// USB interface numbers on the EC25 that take AT commands or are useful to watch.
let interfaceRoles = [1: "NMEA", 2: "AT", 3: "modem"]

/// Serial ports from the driver when it is installed, else direct USB.
/// The modem port comes first: the menu bar app uses the AT port, and two
/// programs on one port would steal each other's replies.
func availablePorts() -> [PortChoice] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
        .filter { $0.hasPrefix("cu.quectel") }
    var numbered: [(Int, PortChoice)] = []
    for name in names {
        guard let number = Int(name.dropFirst("cu.quectel".count)) else { continue }
        let path = "/dev/" + name
        let role = interfaceRoles[number].map { " (\($0) port)" } ?? ""
        numbered.append((number, PortChoice(title: path + role) { try SerialTransport(path: path) }))
    }
    if numbered.isEmpty {
        for number in [3, 2] {
            numbered.append((number, PortChoice(title: "USB interface \(number) (\(interfaceRoles[number]!) port, no driver)") {
                try USBTransport(interfaceNumber: number)
            }))
        }
    }
    // 3, then 2, then the rest.
    let order = [3: 0, 2: 1]
    return numbered.sorted { (order[$0.0] ?? 2 + $0.0) < (order[$1.0] ?? 2 + $1.0) }.map { $0.1 }
}

let timeFormat: DateFormatter = {
    let format = DateFormatter()
    format.dateFormat = "HH:mm:ss.SSS"
    return format
}()

func logLine(_ event: ATMonitor.Event) -> String {
    let time = timeFormat.string(from: Date())
    switch event {
    case .sent(let text): return "\(time) > \(text)"
    case .received(let text): return "\(time) < \(text)"
    case .closed(let reason): return "\(time) * closed" + (reason.map { ": \($0)" } ?? "")
    }
}

// ---------------------------------------------------------------- command line

if let index = CommandLine.arguments.firstIndex(of: "--run"), index + 1 < CommandLine.arguments.count {
    let command = CommandLine.arguments[index + 1]
    var path: String?
    if let port = CommandLine.arguments.firstIndex(of: "--port"), port + 1 < CommandLine.arguments.count {
        path = CommandLine.arguments[port + 1]
    }
    do {
        let transport: ByteTransport
        if let path {
            transport = try SerialTransport(path: path)
        } else if let first = availablePorts().first {
            transport = try first.open()
        } else {
            throw ModemError.notFound("No modem port found")
        }
        let done = DispatchSemaphore(value: 0)
        var monitor: ATMonitor?
        monitor = ATMonitor(transport: transport) { event in
            print(logLine(event))
            switch event {
            case .received(let line) where ATParser.isFinal(line): monitor?.stop()
            case .closed: done.signal()
            default: break
            }
        }
        monitor?.start()
        monitor?.send(command)
        if done.wait(timeout: .now() + 10) == .timedOut {
            FileHandle.standardError.write(Data("error: no final reply within 10 seconds\n".utf8))
            exit(1)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// ---------------------------------------------------------------- window

/// The mark shown next to commands that are not sent straight away, as text
/// that can be put in a label. Nil for plain queries.
func mark(for kind: ATCatalogEntry.Kind, size: CGFloat = 15) -> NSAttributedString? {
    let name: String, colors: [NSColor]
    switch kind {
    case .query: return nil
    // First colour is the exclamation mark, second the triangle.
    case .action: (name, colors) = ("exclamationmark.triangle.fill", [.black, .systemOrange])
    case .template: (name, colors) = ("pencil", [.systemBlue])
    }
    let style = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: colors))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(style) else { return nil }
    let attachment = NSTextAttachment()
    attachment.image = image
    return NSAttributedString(attachment: attachment)
}

/// Icon for alerts and the Dock. A program that is not an app bundle gets the generic
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

/// A row of the command list: a group title or one command.
final class CatalogNode: NSObject {
    let title: String
    let entry: ATCatalogEntry?
    let children: [CatalogNode]

    init(group: ATCatalogGroup) {
        title = group.title
        entry = nil
        children = group.entries.map { CatalogNode(entry: $0) }
    }

    init(entry: ATCatalogEntry) {
        title = entry.command
        self.entry = entry
        children = []
    }
}

final class DebugController: NSObject, NSApplicationDelegate, NSOutlineViewDataSource,
        NSOutlineViewDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private let portMenu = NSPopUpButton()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let stateLabel = NSTextField(labelWithString: "Not connected")
    private let logView = NSTextView()
    private let input = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let outline = NSOutlineView()

    private let nodes = ATCatalog.groups.map { CatalogNode(group: $0) }
    private var ports: [PortChoice] = []
    private var monitor: ATMonitor?
    private var history: [String] = []
    private var historyIndex = 0
    private let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    // ------------------------------------------------------------ set-up

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app bundle has its own icon; `swift run` has none.
        if Bundle.main.bundleURL.pathExtension != "app" { NSApp.applicationIconImage = appIcon() }
        buildMenu()
        buildWindow()
        rescan()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    /// Without a main menu the usual shortcuts (quit, copy, paste) do nothing.
    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Quectel Debug", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
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

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Quectel Debug"
        window.center()

        // Top row: port, connect, state.
        connectButton.target = self
        connectButton.action = #selector(toggleConnection)
        connectButton.bezelStyle = .rounded
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [NSTextField(labelWithString: "Port:"), portMenu,
                                      button("Rescan", #selector(rescan)), connectButton, stateLabel])
        top.spacing = 8

        // Left: the command list.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(commandChosen)
        outline.rowSizeStyle = .custom
        outline.rowHeight = 34
        let listScroll = NSScrollView()
        listScroll.documentView = outline
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let legendText = NSMutableAttributedString(string: "Double-click to use a command.", attributes: small)
        for (kind, meaning) in [(ATCatalogEntry.Kind.action, "changes the modem; asks first"),
                                (.template, "has values; edit, then send")] {
            legendText.append(NSAttributedString(string: "\n", attributes: small))
            if let symbol = mark(for: kind) { legendText.append(symbol) }
            legendText.append(NSAttributedString(string: "  " + meaning, attributes: small))
        }
        let legend = NSTextField(wrappingLabelWithString: "")
        legend.attributedStringValue = legendText
        legend.isSelectable = false
        let left = NSStackView(views: [listScroll, legend])
        left.orientation = .vertical
        left.spacing = 6
        left.alignment = .leading
        listScroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        legend.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true

        // Right: the log, then the input row.
        logView.isEditable = false
        logView.font = mono
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        logView.textContainerInset = NSSize(width: 4, height: 4)
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder

        input.font = mono
        input.placeholderString = "AT command; Return sends, Up and Down recall earlier ones"
        input.delegate = self
        input.target = self
        input.action = #selector(sendInput)
        sendButton.target = self
        sendButton.action = #selector(sendInput)
        sendButton.bezelStyle = .rounded
        let bottom = NSStackView(views: [input, sendButton, button("Clear", #selector(clearLog)),
                                         button("Save Log…", #selector(saveLog))])
        bottom.spacing = 8

        let right = NSStackView(views: [logScroll, bottom])
        right.orientation = .vertical
        right.spacing = 8
        right.alignment = .leading
        logScroll.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        bottom.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        right.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        let root = NSStackView(views: [top, split])
        root.orientation = .vertical
        root.spacing = 10
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
        ])
        window.contentView = content
        window.layoutIfNeeded()
        split.setPosition(320, ofDividerAt: 0)
        updateControls()
    }

    // ------------------------------------------------------------ connection

    @objc private func rescan() {
        guard monitor == nil else { return }
        let chosen = portMenu.titleOfSelectedItem
        ports = availablePorts()
        portMenu.removeAllItems()
        portMenu.addItems(withTitles: ports.map { $0.title })
        // Keep the user's choice if that port still exists.
        if let chosen, portMenu.itemTitles.contains(chosen) { portMenu.selectItem(withTitle: chosen) }
        updateControls()
    }

    private func updateControls() {
        let connected = monitor != nil
        connectButton.title = connected ? "Disconnect" : "Connect"
        connectButton.isEnabled = connected || !ports.isEmpty
        portMenu.isEnabled = !connected && !ports.isEmpty
        input.isEnabled = connected
        sendButton.isEnabled = connected
        let noModem = "No modem found. Plug it in and press Rescan."
        if !connected, ports.isEmpty {
            stateLabel.stringValue = noModem
        } else if stateLabel.stringValue == noModem {
            stateLabel.stringValue = "Not connected"
        }
    }

    @objc private func toggleConnection() {
        if let monitor {
            monitor.stop()  // .closed arrives when the port is really closed
            connectButton.isEnabled = false
            return
        }
        let index = portMenu.indexOfSelectedItem
        guard ports.indices.contains(index) else { return }
        let port = ports[index]
        do {
            let transport = try port.open()
            let monitor = ATMonitor(transport: transport) { [weak self] event in
                DispatchQueue.main.async { self?.handle(event) }
            }
            self.monitor = monitor
            monitor.start()
            stateLabel.stringValue = "Connected to \(port.title)"
            append("\(timeFormat.string(from: Date())) * opened \(port.title)", color: .secondaryLabelColor)
            window.makeFirstResponder(input)
        } catch {
            var text = error.localizedDescription
            if text.contains("Resource busy") { text += ". Another program has this port open." }
            stateLabel.stringValue = text
        }
        updateControls()
    }

    private func handle(_ event: ATMonitor.Event) {
        switch event {
        case .sent: append(logLine(event), color: .systemBlue)
        case .received: append(logLine(event), color: .labelColor)
        case .closed(let reason):
            append(logLine(event), color: reason == nil ? .secondaryLabelColor : .systemRed)
            monitor = nil
            stateLabel.stringValue = reason ?? "Not connected"
            rescan()
        }
    }

    // ------------------------------------------------------------ log

    private func append(_ line: String, color: NSColor) {
        guard let storage = logView.textStorage else { return }
        storage.append(NSAttributedString(string: line + "\n",
                                          attributes: [.font: mono, .foregroundColor: color]))
        logView.scrollToEndOfDocument(nil)
    }

    @objc private func clearLog() {
        logView.string = ""
    }

    @objc private func saveLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "quectel-log.txt"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self.logView.string.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.stateLabel.stringValue = error.localizedDescription
            }
        }
    }

    // ------------------------------------------------------------ sending

    private func send(_ command: String) {
        guard let monitor, !command.isEmpty else { return }
        if history.last != command { history.append(command) }
        historyIndex = history.count
        monitor.send(command)
    }

    @objc private func sendInput() {
        let command = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        input.stringValue = ""
        send(command)
    }

    /// Up and Down in the input field walk through earlier commands.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let step: Int
        if selector == #selector(NSResponder.moveUp(_:)) { step = -1 }
        else if selector == #selector(NSResponder.moveDown(_:)) { step = 1 }
        else { return false }
        let next = historyIndex + step
        guard next >= 0, next <= history.count else { return true }
        historyIndex = next
        input.stringValue = next < history.count ? history[next] : ""
        textView.string = input.stringValue
        textView.moveToEndOfDocument(nil)
        return true
    }

    @objc private func commandChosen() {
        guard let node = outline.item(atRow: outline.clickedRow) as? CatalogNode else { return }
        guard let entry = node.entry else {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            return
        }
        guard monitor != nil else {
            stateLabel.stringValue = "Connect first."
            return
        }
        switch entry.kind {
        case .query:
            send(entry.command)
        case .template:
            input.stringValue = entry.command
            window.makeFirstResponder(input)
        case .action:
            let alert = makeAlert()
            alert.messageText = "Send \(entry.command)?"
            alert.informativeText = entry.summary + ". This changes the modem's state."
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { self.send(entry.command) }
            }
        }
    }

    // ------------------------------------------------------------ command list

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? CatalogNode)?.children.count ?? nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? CatalogNode)?.children[index] ?? nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? CatalogNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? CatalogNode)?.entry == nil ? 22 : 34
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? CatalogNode else { return nil }
        // One line each; a line that does not fit ends in "…" and the full
        // text is in the tooltip.
        func line(_ text: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = color
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return label
        }
        guard let entry = node.entry else {
            return line(node.title, NSFont.boldSystemFont(ofSize: 12), .labelColor)
        }
        let command = line(entry.command, mono, .labelColor)
        if let symbol = mark(for: entry.kind) {
            let text = NSMutableAttributedString(string: entry.command + "  ",
                attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
            text.append(symbol)
            command.attributedStringValue = text
        }
        let row = NSStackView(views: [
            command,
            line(entry.summary, NSFont.systemFont(ofSize: 10), .secondaryLabelColor),
        ])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 1
        let hint = entry.kind == .action ? "\nChanges the modem; asks before sending."
            : entry.kind == .template ? "\nEdit the values, then send." : ""
        row.toolTip = "\(entry.command)\n\(entry.summary)\(hint)"
        return row
    }
}

let app = NSApplication.shared
let controller = DebugController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
