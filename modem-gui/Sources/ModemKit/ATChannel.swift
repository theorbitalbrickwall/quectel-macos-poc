// SPDX-License-Identifier: CC0-1.0
import Foundation

/// A byte stream to the modem's AT port.
public protocol ByteTransport: AnyObject {
    func write(_ data: Data) throws
    /// Returns whatever arrived within `timeout`; empty data means nothing did.
    func read(timeout: TimeInterval) throws -> Data
    func close()
}

public enum ModemError: Error, LocalizedError, Equatable {
    case timeout(String)
    case notFound(String)
    case io(String)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let command): return "No response to \(command)"
        case .notFound(let what): return what
        case .io(let what): return what
        case .rejected(let what): return what
        }
    }
}

public struct ATResponse: Equatable {
    public var lines: [String]
    public var ok: Bool

    /// Everything except the final result line.
    public var body: [String] { Array(lines.dropLast()) }
}

/// Sends one AT command at a time and collects the lines up to the final result.
public final class ATChannel {
    public let transport: ByteTransport
    private var buffer = Data()
    private var unsolicited: [String] = []

    public init(transport: ByteTransport) {
        self.transport = transport
    }

    /// Lines the modem sent on its own (URCs) since the last call: everything
    /// that arrived between two commands, and new message notices that
    /// arrived during one.
    public func takeUnsolicited() -> [String] {
        defer { unsolicited = [] }
        return unsolicited
    }

    private func note(_ line: String) {
        unsolicited.append(line)
        if unsolicited.count > 100 { unsolicited.removeFirst() }
    }

    private static func trimmed(_ raw: Data) -> String {
        String(decoding: raw, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
    }

    /// `payload` is for commands that prompt for more input with "> ", such
    /// as `AT+CMGS`: it is sent after the prompt, followed by Ctrl-Z.
    public func command(_ text: String, payload: String? = nil,
                        timeout: TimeInterval = 5) throws -> ATResponse {
        var stale = LineAssembler()
        while true {
            let data = try transport.read(timeout: 0.05)
            if data.isEmpty { break }
            for line in stale.feed(data) { note(line) }
        }
        buffer = Data()
        try transport.write(Data((text + "\r").utf8))
        let deadline = Date().addingTimeInterval(timeout)
        var lines: [String] = []
        var waitingForPrompt = payload != nil
        while Date() < deadline {
            buffer.append(try transport.read(timeout: min(0.2, max(0.01, deadline.timeIntervalSinceNow))))
            while let newline = buffer.firstIndex(of: 0x0A) {
                let raw = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                let line = Self.trimmed(raw)
                if line.isEmpty || (line == text && lines.isEmpty) { continue }  // blank or echo
                if let payload, line.hasSuffix(payload) { continue }  // echo of the payload
                if SMSStore.isNewMessageNotice(line) {
                    note(line)
                    continue
                }
                lines.append(line)
                if ATParser.isFinal(line) {
                    return ATResponse(lines: lines, ok: line == "OK")
                }
            }
            if waitingForPrompt, let payload, Self.trimmed(buffer).hasPrefix(">") {
                waitingForPrompt = false
                buffer = Data()
                try transport.write(Data(payload.utf8) + Data([0x1A]))
            }
        }
        // Leave the prompt, or the next command would be taken as input.
        if payload != nil { try? transport.write(Data([0x1B])) }
        throw ModemError.timeout(text)
    }

    public func close() {
        transport.close()
    }
}
