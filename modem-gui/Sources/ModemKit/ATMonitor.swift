// SPDX-License-Identifier: CC0-1.0
import Foundation

/// Turns the modem's byte stream into text lines. Blank lines are dropped.
public struct LineAssembler {
    private var buffer = Data()

    public init() {}

    public var hasPartialLine: Bool { !buffer.isEmpty }

    /// Adds received bytes and returns the lines that are now complete.
    public mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let raw = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            if let line = Self.text(raw) { lines.append(line) }
        }
        return lines
    }

    /// Returns text that has no line end yet, such as the "> " prompt the
    /// modem prints while it waits for an SMS body.
    public mutating func flush() -> String? {
        defer { buffer = Data() }
        return Self.text(buffer)
    }

    private static func text(_ raw: Data) -> String? {
        let line = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }
}

/// Keeps a port open and reports every line the modem sends, including
/// unsolicited ones (URCs). Unlike `ATChannel` it does not pair commands with
/// replies; it is meant for a terminal-like view.
public final class ATMonitor {
    public enum Event: Equatable {
        case sent(String)
        case received(String)
        /// The port was closed; the text is the reason, nil after `stop()`.
        case closed(String?)
    }

    private let transport: ByteTransport
    private let handler: (Event) -> Void
    private let queue = DispatchQueue(label: "at-monitor")
    private let lock = NSLock()
    private var outbox: [String] = []
    private var running = false

    /// `handler` is called on a background queue.
    public init(transport: ByteTransport, handler: @escaping (Event) -> Void) {
        self.transport = transport
        self.handler = handler
    }

    public func start() {
        lock.lock(); running = true; lock.unlock()
        queue.async { self.run() }
    }

    /// Queues one line; a carriage return is added.
    public func send(_ text: String) {
        lock.lock(); outbox.append(text); lock.unlock()
    }

    /// Asks the loop to end. `.closed(nil)` is reported when it has.
    public func stop() {
        lock.lock(); running = false; lock.unlock()
    }

    private func take() -> (running: Bool, lines: [String]) {
        lock.lock(); defer { lock.unlock() }
        let lines = outbox
        outbox = []
        return (running, lines)
    }

    // One thread does both directions, so the transport is never used from
    // two threads at once.
    private func run() {
        var assembler = LineAssembler()
        var idleSince = Date()
        var reason: String?
        do {
            while true {
                let state = take()
                guard state.running else { break }
                for line in state.lines {
                    try transport.write(Data((line + "\r").utf8))
                    handler(.sent(line))
                }
                let data = try transport.read(timeout: 0.05)
                if !data.isEmpty {
                    idleSince = Date()
                    for line in assembler.feed(data) { handler(.received(line)) }
                } else if assembler.hasPartialLine, Date().timeIntervalSince(idleSince) > 0.3,
                          let partial = assembler.flush() {
                    handler(.received(partial))
                }
            }
        } catch {
            reason = error.localizedDescription
        }
        transport.close()
        handler(.closed(reason))
    }
}
