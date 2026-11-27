// SPDX-License-Identifier: CC0-1.0
// eSIM profiles through the modem's built-in LPA (`AT+QESIM`), after Quectel's
// EC2x&EG2x&EG9x&EM05 series eSIM LPA Application Note V1.0.
import Foundation

/// One line of `AT+QESIM="list"`.
public struct ESIMProfile: Equatable {
    public var iccid: String
    public var enabled: Bool
    public var nickname: String
    public var provider: String

    public init(iccid: String, enabled: Bool, nickname: String, provider: String) {
        self.iccid = iccid
        self.enabled = enabled
        self.nickname = nickname
        self.provider = provider
    }

    /// What to call the profile: its nickname, else the provider, else the ICCID.
    public var name: String {
        [nickname, provider, iccid].first { !$0.isEmpty } ?? ""
    }
}

/// The eSIM chip and what is installed on it.
public struct ESIMInfo: Equatable {
    public var eid: String
    public var profiles: [ESIMProfile]

    public init(eid: String, profiles: [ESIMProfile]) {
        self.eid = eid
        self.profiles = profiles
    }
}

/// A `<result>` other than 0, with the two error values (chapter 4 of the note).
public struct ESIMFailure: Error, Equatable {
    public var result: Int
    public var info1: Int?
    public var info2: Int?

    public var description: String {
        let kind: String
        switch result {
        case 1: kind = "internal error"
        case 2: kind = "eSIM error"
        case 3: kind = "SM-DP+ error"
        default: kind = "error \(result)"
        }
        guard let info1 else { return kind }
        let code = "\(info1)" + (info2.map { ", \($0)" } ?? "")
        if let reason = reason { return "\(kind): \(reason) (\(code))" }
        return "\(kind) (\(code))"
    }

    /// The causes that can follow from listing, enabling or disabling.
    var reason: String? {
        switch (result, info1, info2) {
        case (1, 2, _): return "the SIM rejected a command"
        case (1, 98, _): return "parameter error"
        case (2, 10, 1), (2, 11, 1): return "profile not found"
        case (2, 10, 2): return "the profile is not disabled"
        case (2, 11, 2): return "the profile is not enabled"
        case (2, 10, 3), (2, 11, 3): return "not allowed by the profile's policy"
        case (2, 10, 4): return "incorrect profile reenabling"
        case (2, 10, 5), (2, 11, 5): return "the SIM is busy"
        default: return nil
        }
    }
}

public enum ESIMParser {
    /// Longest profile name kept, in Unicode scalars.
    public static let maxNameLength = 64

    /// The values after `+QESIM: "<what>",` when the first of them, `<result>`,
    /// is 0; the failure otherwise. Nil without such a line. The modem writes
    /// the prefix without a space, the note with one.
    static func result(of what: String, in lines: [String]) -> Result<[String], ESIMFailure>? {
        guard let values = ATParser.allParameters(of: "+QESIM:", in: lines).first(where: {
            $0.first == what
        }), values.count >= 2, let result = Int(values[1]) else { return nil }
        if result == 0 { return .success(Array(values.dropFirst(2))) }
        return .failure(ESIMFailure(result: result,
                                    info1: values.count > 2 ? Int(values[2]) : nil,
                                    info2: values.count > 3 ? Int(values[3]) : nil))
    }

    /// `+QESIM: "eid",0,"<eid>"`: 32 digits.
    public static func eid(_ lines: [String]) -> String? {
        guard case .success(let values)? = result(of: "eid", in: lines), let eid = values.first,
              !eid.isEmpty, eid.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return eid
    }

    /// The `<ICCID>,<status>,<nickname>,<provider>` lines after `+QESIM: "list",0`.
    /// They have no prefix. Lines that are not a profile are skipped.
    public static func profiles(_ lines: [String]) -> [ESIMProfile]? {
        guard case .success? = result(of: "list", in: lines) else { return nil }
        return lines.filter { !$0.hasPrefix("+") }.compactMap { line in
            let values = ATParser.fields(line)
            guard values.count >= 2, isValidICCID(values[0]), let status = Int(values[1]) else {
                return nil
            }
            func text(_ index: Int) -> String {
                guard index < values.count else { return "" }
                // The names come from the profile's operator, so they get the
                // treatment of SMS text and a length limit. The note allows a
                // nickname 32 characters.
                let clean = SMSText.clean(values[index], singleLine: true)
                    .trimmingCharacters(in: .whitespaces)
                return String(String.UnicodeScalarView(clean.unicodeScalars.prefix(ESIMParser.maxNameLength)))
                    .trimmingCharacters(in: .whitespaces)
            }
            return ESIMProfile(iccid: values[0], enabled: status == 1, nickname: text(2),
                               provider: text(3))
        }
    }

    /// An ICCID is placed inside a quoted AT parameter. It is up to 20 digits,
    /// with "F" as filler.
    public static func isValidICCID(_ iccid: String) -> Bool {
        (10...20).contains(iccid.count) && iccid.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

extension Modem {
    /// The note gives 6 s as the longest response time of every command here.
    private static let esimTimeout: TimeInterval = 10

    /// Nil when the modem has no eSIM, its firmware no `AT+QESIM`, or the eSIM
    /// does not answer just now.
    public func esim() throws -> ESIMInfo? {
        let answer = try channel.command("AT+QESIM=\"eid\"", timeout: Self.esimTimeout)
        guard answer.ok, let eid = ESIMParser.eid(answer.body) else { return nil }
        let list = try channel.command("AT+QESIM=\"list\"", timeout: Self.esimTimeout)
        guard list.ok, let profiles = ESIMParser.profiles(list.body) else { return nil }
        return ESIMInfo(eid: eid, profiles: profiles)
    }

    /// Make `profile` the active one. Only `enable` is sent: the eSIM disables
    /// the profile in use as part of enabling another, and leaves both as
    /// they were when that fails (GSMA SGP.22 V3.0, 3.2.1 and 5.7.16).
    public func enableESIMProfile(_ profile: ESIMProfile) throws {
        guard ESIMParser.isValidICCID(profile.iccid) else {
            throw ModemError.rejected("This is not an ICCID.")
        }
        let answer = try channel.command("AT+QESIM=\"enable\",\"\(profile.iccid)\"",
                                         timeout: Self.esimTimeout)
        switch ESIMParser.result(of: "enable", in: answer.lines) {
        case .success?:
            return
        case .failure(let failure)?:
            throw ModemError.rejected("The profile was not enabled: \(failure.description)")
        case nil:
            throw ModemError.rejected("The modem did not enable the profile: "
                + answer.lines.joined(separator: " "))
        }
    }
}
