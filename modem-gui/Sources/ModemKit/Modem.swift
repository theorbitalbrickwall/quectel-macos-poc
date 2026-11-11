// SPDX-License-Identifier: CC0-1.0
import Foundation

/// One poll of everything the menu shows. Fields are nil when the modem did
/// not answer that query.
public struct ModemStatus: Equatable {
    public var sim: String?
    public var signal: SignalQuality?
    public var network: NetworkInfo?
    public var operatorName: OperatorName?
    public var registration: RegistrationState?
    public var contexts: [PDPContext] = []
    public var address: String?
    public var usbNetMode: USBNetMode?

    public init() {}

    /// The context used for the data connection (the first one, normally cid 1).
    public var apn: String? { contexts.first?.apn }

    /// Short text for the menu bar, e.g. "LTE ●●●○".
    public var title: String {
        guard let signal, signal.mode != "NOSERVICE", registration?.isRegistered != false else {
            return "No service"
        }
        let bars = String(repeating: "●", count: signal.bars)
            + String(repeating: "○", count: 4 - signal.bars)
        return "\(signal.mode) \(bars)"
    }
}

public final class Modem {
    public let channel: ATChannel

    public init(channel: ATChannel) {
        self.channel = channel
    }

    /// Lines of a successful command, nil when the modem answers with an error.
    /// Transport failures and timeouts still throw: the port is unusable then.
    private func query(_ command: String) throws -> [String]? {
        let response = try channel.command(command)
        return response.ok ? response.body : response.lines
    }

    public func status() throws -> ModemStatus {
        var status = ModemStatus()
        status.sim = try query("AT+CPIN?").flatMap(ATParser.simState)
        status.signal = try query("AT+QCSQ").flatMap(ATParser.signal)
        status.network = try query("AT+QNWINFO").flatMap(ATParser.network)
        status.operatorName = try query("AT+QSPN").flatMap(ATParser.operatorName)
        status.registration = try query("AT+CEREG?").flatMap { ATParser.registration($0) }
        if status.registration?.isRegistered != true {
            // Not on LTE: the packet domain registration of 2G/3G applies instead.
            if let state = try query("AT+CGREG?").flatMap({ ATParser.registration($0, prefix: "+CGREG:") }),
               state.isRegistered || status.registration == nil {
                status.registration = state
            }
        }
        status.contexts = try query("AT+CGDCONT?").map(ATParser.contexts) ?? []
        status.address = try query("AT+CGPADDR").flatMap(ATParser.address)
        status.usbNetMode = try query("AT+QCFG=\"usbnet\"").flatMap(ATParser.usbNetMode)
        return status
    }

    /// Change the APN of an existing context, keeping its PDP type.
    public func setAPN(_ apn: String, context: PDPContext) throws {
        guard ATParser.isValidAPN(apn) else {
            throw ModemError.rejected("The APN contains characters that are not allowed.")
        }
        let response = try channel.command("AT+CGDCONT=\(context.cid),\"\(context.type)\",\"\(apn)\"")
        guard response.ok else {
            throw ModemError.rejected("The modem rejected the APN: \(response.lines.joined(separator: " "))")
        }
    }

    /// Store the new USB network mode and reboot the modem so it takes effect.
    public func setUSBNetMode(_ mode: USBNetMode) throws {
        let response = try channel.command("AT+QCFG=\"usbnet\",\(mode.rawValue)")
        guard response.ok else {
            throw ModemError.rejected("The modem rejected the mode: \(response.lines.joined(separator: " "))")
        }
        // The modem may leave the bus before it answers.
        _ = try? channel.command("AT+CFUN=1,1", timeout: 3)
    }
}
