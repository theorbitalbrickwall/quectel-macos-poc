// SPDX-License-Identifier: CC0-1.0
import Foundation

public enum RegistrationState: Equatable {
    case notRegistered, home, searching, denied, unknown, roaming

    public init(stat: Int) {
        switch stat {
        case 0: self = .notRegistered
        case 1: self = .home
        case 2: self = .searching
        case 3: self = .denied
        case 5: self = .roaming
        default: self = .unknown
        }
    }

    public var isRegistered: Bool { self == .home || self == .roaming }

    public var label: String {
        switch self {
        case .notRegistered: return "not registered"
        case .home: return "registered (home)"
        case .searching: return "searching"
        case .denied: return "registration denied"
        case .unknown: return "unknown"
        case .roaming: return "registered (roaming)"
        }
    }
}

/// `AT+QCSQ`. Which values are present depends on the service mode.
public struct SignalQuality: Equatable {
    public var mode: String
    public var rssi: Int?
    public var rsrp: Int?   // LTE only
    public var sinr: Int?   // LTE only, raw value: steps of 0.2 dB above -20 dB
    public var rsrq: Int?   // LTE only

    /// SINR in dB. The manual gives `sinr` in dB, but modems report 0...250;
    /// this is the usual Quectel conversion, which the manual does not state.
    public var sinrDB: Int? {
        sinr.map { Int((Double($0) / 5 - 20).rounded()) }
    }

    /// 0...4, from RSRP on LTE and RSSI otherwise.
    public var bars: Int {
        if let rsrp {
            return [-85, -95, -105, -115].filter { rsrp >= $0 }.count
        }
        if let rssi {
            return [-70, -85, -100, -110].filter { rssi >= $0 }.count
        }
        return 0
    }
}

public struct NetworkInfo: Equatable {
    public var technology: String
    public var plmn: String
    public var band: String
    public var channel: Int?
}

public struct OperatorName: Equatable {
    public var full: String
    public var short: String
    public var serviceProvider: String
    public var plmn: String

    public var best: String {
        [full, short, serviceProvider, plmn].first { !$0.isEmpty } ?? ""
    }
}

public struct PDPContext: Equatable {
    public var cid: Int
    public var type: String
    public var apn: String
}

public enum USBNetMode: Int, CaseIterable {
    case rmnet = 0, ecm = 1, mbim = 2, rndis = 3

    public var label: String {
        switch self {
        case .rmnet: return "RmNet / QMI"
        case .ecm: return "ECM"
        case .mbim: return "MBIM"
        case .rndis: return "RNDIS"
        }
    }
}

public enum ATParser {
    static let finalPrefixes = ["OK", "ERROR", "+CME ERROR", "+CMS ERROR", "NO CARRIER"]

    public static func isFinal(_ line: String) -> Bool {
        finalPrefixes.contains { line == $0 || line.hasPrefix($0 + ":") }
    }

    /// Split a comma-separated parameter list, honouring double quotes.
    /// Works on Unicode scalars: a quote or comma followed by a combining
    /// mark is one `Character` to Swift, but still a quote or comma here.
    public static func fields(_ text: String) -> [String] {
        var fields: [String] = []
        var current = String.UnicodeScalarView()
        var quoted = false
        func finish() {
            fields.append(String(current).trimmingCharacters(in: .whitespaces))
            current = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            if scalar == "\"" {
                quoted.toggle()
            } else if scalar == "," && !quoted {
                finish()
            } else {
                current.append(scalar)
            }
        }
        finish()
        return fields
    }

    /// The parameters of the first line starting with `prefix` (e.g. "+QCSQ:").
    public static func parameters(of prefix: String, in lines: [String]) -> [String]? {
        allParameters(of: prefix, in: lines).first
    }

    public static func allParameters(of prefix: String, in lines: [String]) -> [[String]] {
        lines.filter { $0.hasPrefix(prefix) }
            .map { fields(String($0.dropFirst(prefix.count))) }
    }

    public static func signal(_ lines: [String]) -> SignalQuality? {
        guard let values = parameters(of: "+QCSQ:", in: lines), let mode = values.first,
              !mode.isEmpty else { return nil }
        func number(_ index: Int) -> Int? { index < values.count ? Int(values[index]) : nil }
        var signal = SignalQuality(mode: mode, rssi: number(1))
        if mode == "LTE" {
            signal.rsrp = number(2)
            signal.sinr = number(3)
            signal.rsrq = number(4)
        }
        return signal
    }

    public static func network(_ lines: [String]) -> NetworkInfo? {
        guard let values = parameters(of: "+QNWINFO:", in: lines), values.count >= 3 else {
            return nil
        }
        return NetworkInfo(technology: values[0], plmn: values[1], band: values[2],
                           channel: values.count > 3 ? Int(values[3]) : nil)
    }

    public static func operatorName(_ lines: [String]) -> OperatorName? {
        guard let values = parameters(of: "+QSPN:", in: lines), values.count >= 5 else {
            return nil
        }
        // With alphabet 1 the names are UCS2 hex strings; fall back to the PLMN then.
        let ucs2 = values[3] == "1"
        return OperatorName(full: ucs2 ? "" : values[0], short: ucs2 ? "" : values[1],
                            serviceProvider: values[2], plmn: values[4])
    }

    /// `+CEREG: <n>,<stat>[,...]`, also valid for +CREG and +CGREG.
    public static func registration(_ lines: [String], prefix: String = "+CEREG:") -> RegistrationState? {
        guard let values = parameters(of: prefix, in: lines), values.count >= 2,
              let stat = Int(values[1]) else { return nil }
        return RegistrationState(stat: stat)
    }

    public static func simState(_ lines: [String]) -> String? {
        if let values = parameters(of: "+CPIN:", in: lines) { return values.first }
        return lines.first { $0.hasPrefix("+CME ERROR") }
    }

    public static func contexts(_ lines: [String]) -> [PDPContext] {
        allParameters(of: "+CGDCONT:", in: lines).compactMap { values in
            guard values.count >= 3, let cid = Int(values[0]) else { return nil }
            return PDPContext(cid: cid, type: values[1], apn: values[2])
        }
    }

    /// First usable address of `+CGPADDR: <cid>,<addr>[,<addr>]` lines.
    /// Without a connection the modem gives all-zero addresses, and it can
    /// put the IPv4 and the IPv6 one in a single quoted value.
    public static func address(_ lines: [String]) -> String? {
        for values in allParameters(of: "+CGPADDR:", in: lines) {
            for value in values.dropFirst().flatMap({ $0.split(separator: ",") })
            where !value.allSatisfy({ $0 == "0" || $0 == "." || $0 == ":" || $0 == " " }) {
                return value.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    public static func usbNetMode(_ lines: [String]) -> USBNetMode? {
        guard let values = parameters(of: "+QCFG:", in: lines), values.count >= 2,
              values[0] == "usbnet", let raw = Int(values[1]) else { return nil }
        return USBNetMode(rawValue: raw)
    }

    /// An APN is placed inside a quoted AT parameter; reject what would break out of it.
    public static func isValidAPN(_ apn: String) -> Bool {
        apn.count <= 100 && apn.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        }
    }
}
