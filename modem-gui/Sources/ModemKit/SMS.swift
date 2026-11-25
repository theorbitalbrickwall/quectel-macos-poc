// SPDX-License-Identifier: CC0-1.0
import Foundation

// SMS in PDU mode: 3GPP TS 23.040 (PDU layout), TS 23.038 (alphabets) and
// TS 27.005 (AT commands).

/// The GSM 7-bit alphabets of 3GPP TS 23.038.
enum GSMAlphabet {
    static let escape: UInt8 = 0x1B

    /// Default alphabet, position = septet value.
    static let basic = Array((
        "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\u{1B}ÆæßÉ"
        + " !\"#¤%&'()*+,-./0123456789:;<=>?"
        + "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§"
        + "¿abcdefghijklmnopqrstuvwxyzäöñüà").unicodeScalars)

    /// Default extension table: the character after an escape septet.
    static let basicExtension: [UInt8: Unicode.Scalar] = [
        0x0A: "\u{0C}", 0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\",
        0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|", 0x65: "€",
    ]

    /// Turkish locking shift table (national language identifier 1).
    static let turkish = Array((
        "@£$¥€éùıòÇ\nĞğ\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\u{1B}ŞşßÉ"
        + " !\"#¤%&'()*+,-./0123456789:;<=>?"
        + "İABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§"
        + "çabcdefghijklmnopqrstuvwxyzäöñüà").unicodeScalars)

    /// Turkish single shift table (national language identifier 1).
    static let turkishExtension: [UInt8: Unicode.Scalar] = [
        0x0A: "\u{0C}", 0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\",
        0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|", 0x47: "Ğ", 0x49: "İ",
        0x53: "Ş", 0x63: "ç", 0x65: "€", 0x67: "ğ", 0x69: "ı", 0x73: "ş",
    ]

    /// Septets of every character the default alphabet can express.
    static let encoding: [Unicode.Scalar: [UInt8]] = {
        var map: [Unicode.Scalar: [UInt8]] = [:]
        for (value, scalar) in basic.enumerated() where UInt8(value) != escape {
            map[scalar] = [UInt8(value)]
        }
        for (value, scalar) in basicExtension {
            map[scalar] = [escape, value]
        }
        return map
    }()

    /// One entry per character, or nil when the text needs UCS-2.
    static func encode(_ text: String) -> [[UInt8]]? {
        var groups: [[UInt8]] = []
        for scalar in text.unicodeScalars {
            guard let septets = encoding[scalar] else { return nil }
            groups.append(septets)
        }
        return groups
    }

    /// Septets to text. `locking` and `single` are national language
    /// identifiers from the user data header; only Turkish (1) is known,
    /// anything else uses the default tables.
    static func decode(_ septets: [UInt8], locking: Int = 0, single: Int = 0) -> String {
        let table = locking == 1 ? turkish : basic
        let shift = single == 1 ? turkishExtension : basicExtension
        var scalars = String.UnicodeScalarView()
        var index = 0
        while index < septets.count {
            let value = septets[index] & 0x7F
            index += 1
            if value != escape {
                scalars.append(table[Int(value)])
            } else if index < septets.count {
                let next = septets[index] & 0x7F
                index += 1
                // Escape twice is reserved and shown as a space. A code the
                // shift table does not define means the main table's character.
                scalars.append(next == escape ? " " : shift[next] ?? table[Int(next)])
            } else {
                scalars.append(" ")
            }
        }
        return String(scalars)
    }

    /// Unpack `count` septets from octets.
    static func unpack(_ data: [UInt8], count: Int) -> [UInt8] {
        var septets: [UInt8] = []
        for index in 0..<max(0, count) {
            let bit = index * 7
            let byte = bit / 8
            let shift = bit % 8
            guard byte < data.count else { break }
            var value = Int(data[byte]) >> shift
            if shift > 1, byte + 1 < data.count {
                value |= Int(data[byte + 1]) << (8 - shift)
            }
            septets.append(UInt8(value & 0x7F))
        }
        return septets
    }

    /// Pack septets into octets.
    static func pack(_ septets: [UInt8]) -> [UInt8] {
        var octets = [UInt8](repeating: 0, count: (septets.count * 7 + 7) / 8)
        for (index, septet) in septets.enumerated() {
            let bit = index * 7
            let byte = bit / 8
            let shift = bit % 8
            let value = Int(septet & 0x7F) << shift
            octets[byte] |= UInt8(value & 0xFF)
            if shift > 1 {
                octets[byte + 1] |= UInt8(value >> 8)
            }
        }
        return octets
    }
}

enum Hex {
    static func bytes(_ text: String) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        func value(_ digit: UInt8) -> UInt8? {
            switch digit {
            case 0x30...0x39: return digit - 0x30
            case 0x41...0x46: return digit - 0x41 + 10
            case 0x61...0x66: return digit - 0x61 + 10
            default: return nil
            }
        }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = value(digits[index]), let low = value(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    static func string(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var text = [UInt8]()
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}

/// One stored or received PDU, decoded. A long message is several of these.
public struct SMSPDU: Equatable {
    public enum Kind: Equatable {
        /// Received (SMS-DELIVER).
        case deliver
        /// Written or sent by this side (SMS-SUBMIT).
        case submit
        /// Status reports and anything that could not be decoded.
        case other
    }

    /// Position of this PDU in a long message.
    public struct Part: Equatable {
        public var reference: Int
        public var total: Int
        public var sequence: Int
    }

    public var kind: Kind
    /// Sender of a received message, recipient of a sent one.
    public var address = ""
    /// Service centre time stamp; received messages only.
    public var timestamp: Date?
    /// The text as UTF-16. Kept as code units because an emoji may be split
    /// over two parts.
    public var units: [UInt16] = []
    public var part: Part?

    public var text: String { String(decoding: units, as: UTF16.self) }

    public init(kind: Kind) {
        self.kind = kind
    }

    /// Decode the hex string of `AT+CMGL` / `AT+CMGR`, which starts with the
    /// service centre address. Returns nil when it is cut short or not hex.
    public init?(hex: String) {
        guard let bytes = Hex.bytes(hex.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var position = 0
        func available(_ count: Int) -> Bool { count >= 0 && position + count <= bytes.count }
        func byte() -> Int? {
            guard available(1) else { return nil }
            position += 1
            return Int(bytes[position - 1])
        }
        func take(_ count: Int) -> [UInt8]? {
            guard available(count) else { return nil }
            position += count
            return Array(bytes[(position - count)..<position])
        }

        guard let serviceCentreLength = byte(), take(serviceCentreLength) != nil,
              let first = byte() else { return nil }
        switch first & 0x03 {
        case 1: kind = .submit
        case 2:
            kind = .other  // status report
            return
        default: kind = .deliver  // 3 is reserved and to be read as SMS-DELIVER
        }
        if kind == .submit {
            guard byte() != nil else { return nil }  // message reference
        }

        guard let addressLength = byte(), let addressType = byte(),
              let addressBytes = take((addressLength + 1) / 2) else { return nil }
        address = SMSPDU.address(addressBytes, semiOctets: addressLength, type: addressType)

        guard byte() != nil, let coding = byte() else { return nil }  // protocol identifier, coding
        if kind == .deliver {
            guard let stamp = take(7) else { return nil }
            timestamp = SMSPDU.timestamp(stamp)
        } else {
            let validityLength = [0, 7, 1, 7][(first >> 3) & 0x03]
            guard take(validityLength) != nil else { return nil }
        }

        guard let length = byte() else { return nil }
        let data = Array(bytes[position...])

        var headerLength = 0
        var locking = 0
        var single = 0
        if first & 0x40 != 0 {
            guard let headerSize = data.first, data.count >= 1 + Int(headerSize) else { return nil }
            headerLength = 1 + Int(headerSize)
            var index = 1
            var wellFormed = true
            while index < headerLength {
                guard index + 2 <= headerLength, index + 2 + Int(data[index + 1]) <= headerLength else {
                    wellFormed = false
                    break
                }
                let identifier = data[index]
                let size = Int(data[index + 1])
                let start = index + 2
                let value = data[start..<(start + size)].map { Int($0) }
                switch (identifier, size) {
                case (0x00, 3): part = Part(reference: value[0], total: value[1], sequence: value[2])
                case (0x08, 4): part = Part(reference: value[0] << 8 | value[1], total: value[2], sequence: value[3])
                case (0x24, 1): single = value[0]
                case (0x25, 1): locking = value[0]
                default: break
                }
                index = start + size
            }
            if !wellFormed {
                // An element that does not fit: the whole header is ignored.
                part = nil
                single = 0
                locking = 0
            }
            if let found = part, found.total < 1 || found.sequence < 1 || found.sequence > found.total {
                part = nil
            }
        }

        if coding & 0x80 == 0, coding & 0x20 != 0 {
            // Compressed text (TS 23.042), which hardly any network uses.
            units = Array("(Compressed message, it cannot be shown.)".utf16)
            return
        }
        switch SMSPDU.alphabet(coding: coding) {
        case .gsm7:
            // The header is padded to a septet boundary.
            let septets = GSMAlphabet.unpack(data, count: length)
            let skip = (headerLength * 8 + 6) / 7
            units = Array(GSMAlphabet.decode(Array(septets.dropFirst(skip)),
                                             locking: locking, single: single).utf16)
        case .ucs2:
            let body = Array(data.prefix(length).dropFirst(headerLength))
            for index in stride(from: 0, to: body.count - 1, by: 2) {
                units.append(UInt16(body[index]) << 8 | UInt16(body[index + 1]))
            }
        case .data:
            units = data.prefix(length).dropFirst(headerLength).map { UInt16($0) }
        }
    }

    enum Alphabet { case gsm7, data, ucs2 }

    /// The alphabet named by a data coding scheme octet (TS 23.038 section 4).
    static func alphabet(coding: Int) -> Alphabet {
        switch coding >> 4 {
        case 0...7:
            switch (coding >> 2) & 0x03 {
            case 1: return .data
            case 2: return .ucs2
            default: return .gsm7
            }
        case 0x0E: return .ucs2
        case 0x0F: return coding & 0x04 != 0 ? .data : .gsm7
        default: return .gsm7
        }
    }

    /// A phone number in swapped BCD digits, or a name in GSM 7-bit.
    static func address(_ bytes: [UInt8], semiOctets: Int, type: Int) -> String {
        let typeOfNumber = (type >> 4) & 0x07
        if typeOfNumber == 5 {
            return GSMAlphabet.decode(GSMAlphabet.unpack(bytes, count: semiOctets * 4 / 7))
        }
        let symbols = Array("0123456789*#abc")
        var number = typeOfNumber == 1 ? "+" : ""
        for byte in bytes {
            for nibble in [Int(byte & 0x0F), Int(byte >> 4)] where nibble < symbols.count {
                number.append(symbols[nibble])
            }
        }
        return number
    }

    /// Service centre time stamp: six swapped BCD octets and a time zone in
    /// quarter hours.
    static func timestamp(_ bytes: [UInt8]) -> Date? {
        guard bytes.count == 7 else { return nil }
        // A semi-octet that is not a digit counts as 0.
        func digit(_ nibble: UInt8) -> Int { nibble <= 9 ? Int(nibble) : 0 }
        func decimal(_ byte: UInt8) -> Int { digit(byte & 0x0F) * 10 + digit(byte >> 4) }
        let quarters = Int(bytes[6] & 0x07) * 10 + digit(bytes[6] >> 4)
        let offset = quarters * 900 * (bytes[6] & 0x08 != 0 ? -1 : 1)
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        calendar.timeZone = zone
        var components = DateComponents()
        components.year = 2000 + decimal(bytes[0])
        components.month = decimal(bytes[1])
        components.day = decimal(bytes[2])
        components.hour = decimal(bytes[3])
        components.minute = decimal(bytes[4])
        components.second = decimal(bytes[5])
        return calendar.date(from: components)
    }
}

/// Builds SMS-SUBMIT PDUs for `AT+CMGS`.
public enum SMSEncoder {
    /// Characters that fit in one PDU, and in each part of a long message.
    static let gsmLimits = (single: 160, part: 153)
    static let ucs2Limits = (single: 70, part: 67)

    /// The number without spaces and punctuation, or nil when it is not a
    /// phone number: an optional "+" and up to 20 digits.
    public static func normalizedNumber(_ number: String) -> String? {
        let kept = number.filter { !" -()./".contains($0) }
        let digits = kept.hasPrefix("+") ? kept.dropFirst() : Substring(kept)
        guard (1...20).contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return kept
    }

    /// How many parts `text` needs, and whether it needs UCS-2.
    public static func partCount(_ text: String) -> (parts: Int, ucs2: Bool) {
        if let groups = GSMAlphabet.encode(text) {
            return (split(groups: groups).count, false)
        }
        return (split(units: Array(text.utf16)).count, true)
    }

    static func split(groups: [[UInt8]]) -> [[UInt8]] {
        let septets = groups.flatMap { $0 }
        if septets.count <= gsmLimits.single { return [septets] }
        var parts: [[UInt8]] = [[]]
        for group in groups {
            // An escape and its character stay in one part.
            if parts[parts.count - 1].count + group.count > gsmLimits.part { parts.append([]) }
            parts[parts.count - 1] += group
        }
        return parts
    }

    static func split(units: [UInt16]) -> [[UInt16]] {
        if units.count <= ucs2Limits.single { return [units] }
        var parts: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + ucs2Limits.part, units.count)
            // Do not cut an emoji (surrogate pair) in two.
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            parts.append(Array(units[start..<end]))
            start = end
        }
        return parts
    }

    /// One hex PDU per part, each starting with "00" (use the service centre
    /// stored on the SIM). `number` must come from `normalizedNumber`.
    /// Returns nil when the text is empty or needs more than 255 parts.
    public static func submitPDUs(to number: String, text: String, reference: UInt8) -> [String]? {
        guard !text.isEmpty else { return nil }
        let international = number.hasPrefix("+")
        let digits = (international ? String(number.dropFirst()) : number).utf8.map { $0 &- 0x30 }
        guard !digits.isEmpty, digits.allSatisfy({ $0 <= 9 }) else { return nil }
        var destination: [UInt8] = [UInt8(digits.count), international ? 0x91 : 0x81]
        for index in stride(from: 0, to: digits.count, by: 2) {
            let high = index + 1 < digits.count ? digits[index + 1] : 0x0F
            destination.append(high << 4 | digits[index])
        }

        // (coding scheme, length field, user data) per part, without header.
        var bodies: [(coding: UInt8, length: Int, data: [UInt8])] = []
        let gsm = GSMAlphabet.encode(text)
        let count: Int
        if let gsm {
            let parts = split(groups: gsm)
            count = parts.count
            for part in parts {
                if count == 1 {
                    bodies.append((0x00, part.count, GSMAlphabet.pack(part)))
                } else {
                    // Seven septets of room for the six header octets.
                    let packed = GSMAlphabet.pack([UInt8](repeating: 0, count: 7) + part)
                    bodies.append((0x00, part.count + 7, Array(packed.dropFirst(6))))
                }
            }
        } else {
            let parts = split(units: Array(text.utf16))
            count = parts.count
            for part in parts {
                let data = part.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
                bodies.append((0x08, data.count + (count == 1 ? 0 : 6), data))
            }
        }
        guard count <= 255 else { return nil }

        var pdus: [String] = []
        for (index, body) in bodies.enumerated() {
            // No service centre, SMS-SUBMIT (with header flag), reference 0.
            var pdu: [UInt8] = [0x00, count == 1 ? 0x01 : 0x41, 0x00]
            pdu += destination
            pdu += [0x00, body.coding, UInt8(body.length)]
            if count > 1 {
                pdu += [0x05, 0x00, 0x03, reference, UInt8(count), UInt8(index + 1)]
            }
            pdu += body.data
            pdus.append(Hex.string(pdu))
        }
        return pdus
    }

    /// The length `AT+CMGS` wants: octets without the service centre part.
    public static func commandLength(ofPDU hex: String) -> Int {
        guard let bytes = Hex.bytes(hex), let first = bytes.first else { return 0 }
        return bytes.count - 1 - Int(first)
    }
}

/// One entry of the modem's message storage.
public struct SMSStoredPart: Equatable {
    public var index: Int
    /// 0 received unread, 1 received read, 2 stored unsent, 3 stored sent.
    public var status: Int
    public var pdu: SMSPDU
}

/// A whole message, joined from its parts.
public struct SMSMessage: Equatable {
    /// Storage indexes of all parts, for deleting.
    public var indices: [Int]
    public var incoming: Bool
    /// True when a part was unread before this listing. Listing marks it read.
    public var unread: Bool
    public var address: String
    public var timestamp: Date?
    public var text: String
    /// Parts of a long message that are not in the storage (yet).
    public var missingParts = 0
}

public enum SMSStore {
    /// Parse the body of `AT+CMGL=4`: a `+CMGL: <index>,<stat>,[<alpha>],<length>`
    /// line followed by a line with the PDU.
    public static func parts(_ lines: [String]) -> [SMSStoredPart] {
        var parts: [SMSStoredPart] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard line.hasPrefix("+CMGL:") else { continue }
            let values = ATParser.fields(String(line.dropFirst("+CMGL:".count)))
            guard values.count >= 2, let slot = Int(values[0]), let status = Int(values[1]) else { continue }
            var pdu = SMSPDU(kind: .other)
            if index < lines.count, !lines[index].hasPrefix("+CMGL:") {
                pdu = SMSPDU(hex: lines[index]) ?? pdu
                index += 1
            }
            parts.append(SMSStoredPart(index: slot, status: status, pdu: pdu))
        }
        return parts
    }

    /// Join the parts of long messages. Newest first; messages without a
    /// time stamp (stored sent ones) come last.
    public static func messages(_ parts: [SMSStoredPart]) -> [SMSMessage] {
        var groups: [[SMSStoredPart]] = []
        var groupOfKey: [String: Int] = [:]
        for part in parts {
            guard let position = part.pdu.part else {
                groups.append([part])
                continue
            }
            let key = "\(part.pdu.kind)|\(part.pdu.address)|\(position.reference)|\(position.total)"
            if let group = groupOfKey[key] {
                groups[group].append(part)
            } else {
                groupOfKey[key] = groups.count
                groups.append([part])
            }
        }

        let messages = groups.map { group -> SMSMessage in
            let first = group[0]
            var message = SMSMessage(indices: group.map { $0.index }.sorted(),
                                     incoming: first.pdu.kind == .deliver,
                                     unread: group.contains { $0.status == 0 },
                                     address: first.pdu.address,
                                     timestamp: group.compactMap { $0.pdu.timestamp }.min(),
                                     text: "")
            if first.pdu.kind == .other {
                message.incoming = first.status <= 1
                message.text = "(This kind of message cannot be shown.)"
            } else if let total = first.pdu.part?.total {
                var units: [UInt16] = []
                var gap = false
                for sequence in 1...total {
                    if let part = group.first(where: { $0.pdu.part?.sequence == sequence }) {
                        units += part.pdu.units
                        gap = false
                    } else {
                        message.missingParts += 1
                        if !gap { units += Array(" […] ".utf16) }
                        gap = true
                    }
                }
                message.text = String(decoding: units, as: UTF16.self)
            } else {
                message.text = first.pdu.text
            }
            return message
        }
        return messages.sorted { left, right in
            let leftTime = left.timestamp ?? .distantPast
            let rightTime = right.timestamp ?? .distantPast
            if leftTime != rightTime { return leftTime > rightTime }
            return (left.indices.first ?? 0) > (right.indices.first ?? 0)
        }
    }

    /// Messages in the storage that is read and deleted from, out of
    /// `+CPMS: <mem1>,<used1>,<total1>,...`.
    public static func usedCount(_ lines: [String]) -> Int? {
        guard let values = ATParser.parameters(of: "+CPMS:", in: lines), values.count >= 2 else { return nil }
        return Int(values[1])
    }

    /// True for the `+CMTI: <mem>,<index>` notice of a new message.
    public static func isNewMessageNotice(_ line: String) -> Bool {
        line.hasPrefix("+CMTI:")
    }
}
