// SPDX-License-Identifier: CC0-1.0
// The message window of the menu bar app.
import AppKit
import ModemKit

func describe(_ message: SMSMessage, dates: DateFormatter) -> String {
    var line = message.incoming ? "From \(message.address)" : "To \(message.address)"
    if let timestamp = message.timestamp { line += ", \(dates.string(from: timestamp))" }
    if message.missingParts > 0 { line += " (\(message.missingParts) part(s) missing)" }
    return line
}

func messageDates() -> DateFormatter {
    let dates = DateFormatter()
    dates.dateStyle = .short
    dates.timeStyle = .short
    return dates
}

/// Lists the messages stored on the modem. The owner does the modem I/O.
final class MessagesWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Called with the number to write to; empty for a new message.
    var onCompose: ((String) -> Void)?
    var onDelete: ((SMSMessage) -> Void)?

    private var window: NSWindow?
    private let table = NSTableView()
    private let body = NSTextView()
    private let replyButton = NSButton(title: "Reply…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let dates = messageDates()
    private var messages: [SMSMessage] = []
    /// First storage index of the messages to mark as new.
    private var fresh: Set<Int> = []

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(_ list: [SMSMessage], fresh: Set<Int>) {
        let selected = self.selected?.indices
        messages = list
        self.fresh = fresh
        table.reloadData()
        if let selected, let row = list.firstIndex(where: { $0.indices == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        showSelection()
    }

    private var selected: SMSMessage? {
        let row = table.selectedRow
        return row >= 0 && row < messages.count ? messages[row] : nil
    }

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Messages"
        window.isReleasedWhenClosed = false
        window.center()

        for (identifier, title, width) in [("who", "From / To", 170.0), ("date", "Received", 130.0),
                                           ("text", "Message", 300.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = CGFloat(width)
            column.isEditable = false
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder

        body.isEditable = false
        body.font = NSFont.systemFont(ofSize: 13)
        body.isVerticallyResizable = true
        body.autoresizingMask = [.width]
        body.textContainerInset = NSSize(width: 4, height: 4)
        let bodyScroll = NSScrollView()
        bodyScroll.documentView = body
        bodyScroll.hasVerticalScroller = true
        bodyScroll.borderType = .bezelBorder

        let newButton = NSButton(title: "New Message…", target: self, action: #selector(newMessage))
        for (button, action) in [(replyButton, #selector(reply)), (deleteButton, #selector(deleteSelected))] {
            button.target = self
            button.action = action
        }
        for button in [newButton, replyButton, deleteButton] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [newButton, replyButton, deleteButton])
        buttons.spacing = 8

        let root = NSStackView(views: [tableScroll, bodyScroll, buttons])
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
            tableScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            bodyScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            bodyScroll.heightAnchor.constraint(equalToConstant: 110),
        ])
        window.contentView = content
        self.window = window
        table.reloadData()
        showSelection()
    }

    private func showSelection() {
        let message = selected
        body.string = message.map { describe($0, dates: dates) + "\n\n" + $0.text } ?? ""
        replyButton.isEnabled = message?.incoming == true
            && SMSEncoder.normalizedNumber(message?.address ?? "") != nil
        deleteButton.isEnabled = message != nil
    }

    @objc private func newMessage() {
        onCompose?("")
    }

    @objc private func reply() {
        if let message = selected { onCompose?(message.address) }
    }

    @objc private func deleteSelected() {
        if let message = selected { onDelete?(message) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        messages.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < messages.count else { return nil }
        let message = messages[row]
        switch tableColumn?.identifier.rawValue {
        case "who":
            let isFresh = message.indices.first.map { fresh.contains($0) } ?? false
            let mark = isFresh ? "● " : ""
            return mark + (message.incoming ? "" : "To ") + message.address
        case "date":
            return message.timestamp.map(dates.string(from:)) ?? ""
        default:
            return message.text.replacingOccurrences(of: "\n", with: " ")
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showSelection()
    }
}
