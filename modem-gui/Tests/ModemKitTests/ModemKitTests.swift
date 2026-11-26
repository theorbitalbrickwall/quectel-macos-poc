// SPDX-License-Identifier: CC0-1.0
import XCTest
@testable import ModemKit

/// Behaves like the modem's AT port: echoes the command, then answers.
/// Commands without a canned reply get the behaviour of the message store.
final class FakeModem: ByteTransport {
    var replies: [String: String]
    var pending = Data()
    var sent: [String] = []
    var silent = false
    /// Message store: slot, status and PDU.
    var store: [(index: Int, status: Int, pdu: String)] = []
    /// PDUs accepted by AT+CMGS.
    var submitted: [String] = []
    var cancelled = false
    /// Never show the "> " prompt of AT+CMGS.
    var withholdPrompt = false
    /// A line the modem sends on its own in the middle of the message list.
    var listingNotice: String?
    private var promptLength: Int?
    /// eSIM chip: its EID and the profiles as (ICCID, enabled, nickname, provider).
    var eid: String?
    var profiles: [(iccid: String, enabled: Bool, nickname: String, provider: String)] = []

    init(replies: [String: String], stale: String = "") {
        self.replies = replies
        pending = Data(stale.utf8)
    }

    /// A message arrives: it is stored and announced with +CMTI.
    func receive(_ pdu: String) {
        let index = (store.map { $0.index }.max() ?? -1) + 1
        store.append((index, 0, pdu))
        pending.append(Data("\r\n+CMTI: \"ME\",\(index)\r\n".utf8))
    }

    func write(_ data: Data) throws {
        if data == Data([0x1B]) {
            cancelled = true
            promptLength = nil
            return
        }
        if let expected = promptLength {
            // The PDU after the prompt, ended by Ctrl-Z.
            promptLength = nil
            let pdu = String(decoding: data.dropLast(), as: UTF8.self)
            let valid = data.last == 0x1A && SMSEncoder.commandLength(ofPDU: pdu) == expected
            if valid { submitted.append(pdu) }
            let result = valid ? "+CMGS: \(submitted.count)\r\n\r\nOK" : "+CMS ERROR: 304"
            pending.append(Data("\(pdu)\u{1A}\r\n\(result)\r\n".utf8))
            return
        }
        let command = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        sent.append(command)
        guard !silent else { return }
        if replies[command] == nil, command.hasPrefix("AT+CMGS=") {
            pending.append(Data("\(command)\r".utf8))
            if !withholdPrompt {
                promptLength = Int(command.dropFirst("AT+CMGS=".count))
                pending.append(Data("\r\n> ".utf8))
            }
            return
        }
        let body = replies[command] ?? storeReply(command) ?? "+CME ERROR: 100"
        pending.append(Data("\(command)\r\r\n\(body)\r\n".utf8))
    }

    /// `AT+QESIM`, written the way the EC25-EUX does: no space after the
    /// prefix, the status in quotes, nothing for an empty nickname.
    private func esimReply(_ command: String) -> String? {
        guard let eid else { return nil }
        let fields = ATParser.fields(String(command.dropFirst("AT+QESIM=".count)))
        switch fields.first {
        case "eid":
            return "+QESIM:\"eid\",0,\"\(eid)\"\r\n\r\nOK"
        case "list":
            let lines = profiles.map {
                "\"\($0.iccid)\",\"\($0.enabled ? 1 : 0)\","
                    + ($0.nickname.isEmpty ? "" : "\"\($0.nickname)\"") + ",\"\($0.provider)\"\r\n"
            }
            return "+QESIM:\"list\",0\r\n" + lines.joined() + "\r\nOK"
        case "enable":
            guard fields.count == 2, let index = profiles.firstIndex(where: { $0.iccid == fields[1] }) else {
                return "+QESIM:\"enable\",2,10,1\r\n\r\nOK"  // ICCID not found
            }
            if profiles[index].enabled { return "+QESIM:\"enable\",2,10,2\r\n\r\nOK" }
            for other in profiles.indices { profiles[other].enabled = other == index }
            return "+QESIM:\"enable\",0\r\n\r\nOK"
        default:
            return nil
        }
    }

    private func storeReply(_ command: String) -> String? {
        if command.hasPrefix("AT+QESIM=") { return esimReply(command) }
        switch command {
        case "AT+CMGF=0":
            return "OK"
        case "AT+CPMS?":
            return "+CPMS: \"ME\",\(store.count),255,\"ME\",\(store.count),255,\"ME\",\(store.count),255\r\n\r\nOK"
        case "AT+CMGL=4":
            var text = ""
            for index in store.indices {
                let entry = store[index]
                let length = SMSEncoder.commandLength(ofPDU: entry.pdu)
                text += "+CMGL: \(entry.index),\(entry.status),,\(length)\r\n"
                if let listingNotice { text += "\r\n\(listingNotice)\r\n" }
                text += "\(entry.pdu)\r\n"
                if entry.status == 0 { store[index].status = 1 }  // listing marks it read
            }
            return text + "\r\nOK"
        default:
            guard command.hasPrefix("AT+CMGD="), let index = Int(command.dropFirst("AT+CMGD=".count)),
                  store.contains(where: { $0.index == index }) else { return nil }
            store.removeAll { $0.index == index }
            return "OK"
        }
    }

    func read(timeout: TimeInterval) throws -> Data {
        // Hand out small chunks to exercise line reassembly.
        let chunk = pending.prefix(7)
        pending = Data(pending.dropFirst(chunk.count))
        return Data(chunk)
    }

    func close() {}
}

let lteReplies = [
    "AT+CPIN?": "+CPIN: READY\r\n\r\nOK",
    "AT+QCSQ": "+QCSQ: \"LTE\",-67,-95,15,-10\r\n\r\nOK",
    "AT+QNWINFO": "+QNWINFO: \"FDD LTE\",\"26201\",\"LTE BAND 3\",1300\r\n\r\nOK",
    "AT+QSPN": "+QSPN: \"Telekom.de\",\"TDG\",\"\",0,\"26201\"\r\n\r\nOK",
    "AT+CEREG?": "+CEREG: 0,1\r\n\r\nOK",
    "AT+CGDCONT?": "+CGDCONT: 1,\"IPV4V6\",\"internet.telekom\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0\r\n"
        + "+CGDCONT: 2,\"IPV4V6\",\"ims\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0\r\n\r\nOK",
    "AT+CGPADDR": "+CGPADDR: 1,\"10.34.12.7\",\"2a01:598::1\"\r\n+CGPADDR: 2,\"0.0.0.0\"\r\n\r\nOK",
    "AT+QCFG=\"usbnet\"": "+QCFG: \"usbnet\",1\r\n\r\nOK",
]

final class ParserTests: XCTestCase {
    func testFieldsSeeQuotesAndCommasUnderCombiningMarks() {
        XCTAssertEqual(ATParser.fields("\"\u{301}a,b\",\"c\"\u{301},d,\u{301}e"),
                       ["\u{301}a,b", "c\u{301}", "d", "\u{301}e"])
    }

    func testFieldsHonourQuotes() {
        XCTAssertEqual(ATParser.fields(" \"FDD LTE\",\"a,b\",,7"), ["FDD LTE", "a,b", "", "7"])
    }

    func testFinalLines() {
        XCTAssertTrue(ATParser.isFinal("OK"))
        XCTAssertTrue(ATParser.isFinal("+CME ERROR: 10"))
        XCTAssertFalse(ATParser.isFinal("OKAY"))
        XCTAssertFalse(ATParser.isFinal("+QCSQ: \"LTE\""))
    }

    func testSignalPerMode() {
        let lte = ATParser.signal(["+QCSQ: \"LTE\",-67,-95,15,-10"])
        XCTAssertEqual(lte, SignalQuality(mode: "LTE", rssi: -67, rsrp: -95, sinr: 15, rsrq: -10))
        XCTAssertEqual(lte?.sinrDB, -17)
        XCTAssertEqual(SignalQuality(mode: "LTE", sinr: 248).sinrDB, 30)
        XCTAssertNil(SignalQuality(mode: "GSM", rssi: -70).sinrDB)
        XCTAssertEqual(lte?.bars, 3)
        let wcdma = ATParser.signal(["+QCSQ: \"WCDMA\",-104,-110,-9"])
        XCTAssertEqual(wcdma, SignalQuality(mode: "WCDMA", rssi: -104))
        XCTAssertEqual(wcdma?.bars, 1)
        XCTAssertEqual(ATParser.signal(["+QCSQ: \"NOSERVICE\""])?.bars, 0)
        XCTAssertNil(ATParser.signal(["OK"]))
    }

    func testBarThresholds() {
        func bars(_ rsrp: Int) -> Int { SignalQuality(mode: "LTE", rsrp: rsrp).bars }
        XCTAssertEqual([-80, -85, -86, -105, -106, -115, -116].map(bars), [4, 4, 3, 2, 1, 1, 0])
    }

    func testRegistration() {
        XCTAssertEqual(ATParser.registration(["+CEREG: 0,1"]), .home)
        XCTAssertEqual(ATParser.registration(["+CEREG: 2,5,\"1A2B\",\"01234567\",7"]), .roaming)
        XCTAssertEqual(ATParser.registration(["+CGREG: 0,2"], prefix: "+CGREG:"), .searching)
        XCTAssertNil(ATParser.registration(["+CEREG: 0"]))
    }

    func testOperatorFallsBackWhenNamesAreUCS2() {
        let name = ATParser.operatorName(["+QSPN: \"00540065\",\"0054\",\"\",1,\"26201\""])
        XCTAssertEqual(name?.best, "26201")
    }

    func testSimStateIncludesErrors() {
        XCTAssertEqual(ATParser.simState(["+CPIN: SIM PIN"]), "SIM PIN")
        XCTAssertEqual(ATParser.simState(["+CME ERROR: 10"]), "+CME ERROR: 10")
    }

    func testAPNValidation() {
        XCTAssertTrue(ATParser.isValidAPN("internet.t-mobile"))
        XCTAssertTrue(ATParser.isValidAPN(""))
        XCTAssertFalse(ATParser.isValidAPN("a\",\"b"))
        XCTAssertFalse(ATParser.isValidAPN("apn\rAT+CFUN=0"))
        XCTAssertFalse(ATParser.isValidAPN("ünternet"))
    }
}

final class ChannelTests: XCTestCase {
    func testCommandStripsEchoAndStaleURC() throws {
        let modem = FakeModem(replies: ["ATI": "Quectel\r\nEC25\r\n\r\nOK"], stale: "\r\nRDY\r\n")
        let response = try ATChannel(transport: modem).command("ATI")
        XCTAssertEqual(response, ATResponse(lines: ["Quectel", "EC25", "OK"], ok: true))
        XCTAssertEqual(response.body, ["Quectel", "EC25"])
    }

    func testErrorResponse() throws {
        let response = try ATChannel(transport: FakeModem(replies: [:])).command("AT+BOGUS")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.lines, ["+CME ERROR: 100"])
    }

    func testSilenceTimesOut() {
        let modem = FakeModem(replies: [:])
        modem.silent = true
        XCTAssertThrowsError(try ATChannel(transport: modem).command("AT", timeout: 0.3)) { error in
            XCTAssertEqual(error as? ModemError, .timeout("AT"))
        }
    }
}

final class ModemTests: XCTestCase {
    func testStatusOnLTE() throws {
        let status = try Modem(channel: ATChannel(transport: FakeModem(replies: lteReplies))).status()
        XCTAssertEqual(status.sim, "READY")
        XCTAssertEqual(status.signal?.rsrp, -95)
        XCTAssertEqual(status.network, NetworkInfo(technology: "FDD LTE", plmn: "26201",
                                                   band: "LTE BAND 3", channel: 1300))
        XCTAssertEqual(status.operatorName?.best, "Telekom.de")
        XCTAssertEqual(status.registration, .home)
        XCTAssertEqual(status.apn, "internet.telekom")
        XCTAssertEqual(status.address, "10.34.12.7")
        XCTAssertEqual(status.usbNetMode, .ecm)
        XCTAssertEqual(status.title, "LTE ●●●○")
    }

    func testStatusSurvivesRejectedQueries() throws {
        // No SIM: most queries fail, but the poll must still complete.
        let modem = FakeModem(replies: ["AT+CPIN?": "+CME ERROR: 10",
                                        "AT+QCSQ": "+QCSQ: \"NOSERVICE\"\r\n\r\nOK",
                                        "AT+CEREG?": "+CEREG: 0,2\r\n\r\nOK",
                                        "AT+CGREG?": "+CGREG: 0,0\r\n\r\nOK"])
        let status = try Modem(channel: ATChannel(transport: modem)).status()
        XCTAssertEqual(status.sim, "+CME ERROR: 10")
        XCTAssertEqual(status.registration, .searching)
        XCTAssertNil(status.network)
        XCTAssertEqual(status.contexts, [])
        XCTAssertEqual(status.title, "No service")
    }

    func testFallsBackTo3GRegistration() throws {
        var replies = lteReplies
        replies["AT+CEREG?"] = "+CEREG: 0,0\r\n\r\nOK"
        replies["AT+CGREG?"] = "+CGREG: 0,5\r\n\r\nOK"
        let status = try Modem(channel: ATChannel(transport: FakeModem(replies: replies))).status()
        XCTAssertEqual(status.registration, .roaming)
    }

    func testSetAPNKeepsContextTypeAndRejectsInjection() throws {
        let fake = FakeModem(replies: ["AT+CGDCONT=1,\"IPV4V6\",\"new.apn\"": "OK"])
        let modem = Modem(channel: ATChannel(transport: fake))
        let context = PDPContext(cid: 1, type: "IPV4V6", apn: "old")
        try modem.setAPN("new.apn", context: context)
        XCTAssertEqual(fake.sent, ["AT+CGDCONT=1,\"IPV4V6\",\"new.apn\""])
        XCTAssertThrowsError(try modem.setAPN("x\"\rAT+CFUN=0", context: context))
        XCTAssertEqual(fake.sent.count, 1, "an invalid APN must never reach the modem")
    }

    func testSetUSBNetModeStoresThenReboots() throws {
        let fake = FakeModem(replies: ["AT+QCFG=\"usbnet\",2": "OK", "AT+CFUN=1,1": "OK"])
        try Modem(channel: ATChannel(transport: fake)).setUSBNetMode(.mbim)
        XCTAssertEqual(fake.sent, ["AT+QCFG=\"usbnet\",2", "AT+CFUN=1,1"])
    }

    func testRejectedUSBNetModeDoesNotReboot() {
        let fake = FakeModem(replies: [:])
        XCTAssertThrowsError(try Modem(channel: ATChannel(transport: fake)).setUSBNetMode(.ecm))
        XCTAssertEqual(fake.sent, ["AT+QCFG=\"usbnet\",1"])
    }
}

final class DescriptorTests: XCTestCase {
    // Configuration with a 2-endpoint interface 0 and the AT-style interface 2
    // (interrupt IN 0x83, bulk IN 0x82, bulk OUT 0x02).
    let configuration = Data([
        9, 2, 55, 0, 2, 1, 0, 0xA0, 250,
        9, 4, 0, 0, 2, 0xFF, 0xFF, 0xFF, 0,
        7, 5, 0x81, 2, 0, 2, 0,
        7, 5, 0x01, 2, 0, 2, 0,
        9, 4, 2, 0, 3, 0xFF, 0, 0, 0,
        5, 0x24, 0, 0x10, 1,
        7, 5, 0x83, 3, 10, 0, 9,
        7, 5, 0x82, 2, 0, 2, 0,
        7, 5, 0x02, 2, 0, 2, 0,
    ])

    func testFindsBulkPairOfRequestedInterface() {
        XCTAssertEqual(USBDescriptors.bulkEndpoints(configuration: configuration, interfaceNumber: 2),
                       BulkEndpoints(input: 0x82, output: 0x02))
        XCTAssertEqual(USBDescriptors.bulkEndpoints(configuration: configuration, interfaceNumber: 0),
                       BulkEndpoints(input: 0x81, output: 0x01))
    }

    func testMissingInterfaceAndTruncatedDescriptor() {
        XCTAssertNil(USBDescriptors.bulkEndpoints(configuration: configuration, interfaceNumber: 5))
        XCTAssertNil(USBDescriptors.bulkEndpoints(configuration: configuration.prefix(48), interfaceNumber: 2))
        XCTAssertNil(USBDescriptors.bulkEndpoints(configuration: Data([0, 0, 0]), interfaceNumber: 0))
    }
}

final class MonitorTests: XCTestCase {
    func testLineAssemblerSplitsAndDropsBlankLines() {
        var assembler = LineAssembler()
        XCTAssertEqual(assembler.feed(Data("ATI\r\r\nQuec".utf8)), ["ATI"])
        XCTAssertTrue(assembler.hasPartialLine)
        XCTAssertEqual(assembler.feed(Data("tel\r\n\r\nOK\r\n".utf8)), ["Quectel", "OK"])
        XCTAssertFalse(assembler.hasPartialLine)
    }

    func testLineAssemblerFlushReturnsPrompt() {
        var assembler = LineAssembler()
        XCTAssertEqual(assembler.feed(Data("\r\n> ".utf8)), [])
        XCTAssertEqual(assembler.flush(), ">")
        XCTAssertNil(assembler.flush())
    }

    func testMonitorReportsSentReceivedAndUnsolicitedLines() {
        let modem = FakeModem(replies: ["ATI": "Quectel\r\nEC25\r\n\r\nOK"], stale: "\r\n+CPIN: READY\r\n")
        var events: [ATMonitor.Event] = []
        let closed = expectation(description: "closed")
        var monitor: ATMonitor?
        monitor = ATMonitor(transport: modem) { event in
            events.append(event)
            if event == .received("OK") { monitor?.stop() }
            if case .closed = event { closed.fulfill() }
        }
        monitor?.send("ATI")
        monitor?.start()
        wait(for: [closed], timeout: 5)
        XCTAssertEqual(events, [.sent("ATI"), .received("+CPIN: READY"), .received("ATI"),
                                .received("Quectel"), .received("EC25"), .received("OK"), .closed(nil)])
    }

    func testMonitorReportsTransportFailure() {
        final class Broken: ByteTransport {
            func write(_ data: Data) throws {}
            func read(timeout: TimeInterval) throws -> Data { throw ModemError.io("unplugged") }
            func close() {}
        }
        let closed = expectation(description: "closed")
        var last: ATMonitor.Event?
        let monitor = ATMonitor(transport: Broken()) { event in
            last = event
            closed.fulfill()
        }
        monitor.start()
        wait(for: [closed], timeout: 5)
        XCTAssertEqual(last, .closed("unplugged"))
    }

    func testCatalogIsSane() {
        let entries = ATCatalog.groups.flatMap { $0.entries }
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(Set(entries.map { $0.command }).count, entries.count, "duplicate command")
        for entry in entries {
            XCTAssertTrue(entry.command.hasPrefix("AT"), entry.command)
            XCTAssertFalse(entry.summary.isEmpty, entry.command)
        }
        // Anything that reboots or powers down must ask first.
        for command in ["AT+CFUN=1,1", "AT+QPOWD", "AT+CFUN=4", "AT+CFUN=0"] {
            XCTAssertEqual(entries.first { $0.command == command }?.kind, .action, command)
        }
    }
}

// Reference PDUs, built by an independent encoder. All received ones come
// from service centre +491710760000 at 2026-11-25 22:30:15 +01:00 unless noted.
enum PDU {
    static let gsm = "0791947101670000040C9109551532547600006211522203514013C8329BFD066D50F7B79C4DDEA4409B720D"
    static let gsmText = "Hello {world} €5"
    static let ucs2 = "0791947101670000040C910955153254760008621152220351406000C70061011F007201310020006900E70069006E002000740065015F0065006B006B00FC0072006C00650072002C00200130007300740061006E00620075006C201900640061006E002000730065006C0061006D006C006100720020D83DDE00"
    static let ucs2Text = "Çağrı için teşekkürler, İstanbul’dan selamlar 😀"
    /// Two UCS-2 parts, reference 0x2A; the emoji is cut between them.
    static let longUCS2 = [
        "0791947101670000440C910955153254760008621152220351408C0500032A0201"
            + String(repeating: "015F", count: 66) + "D83D",
        "0791947101670000440C910955153254760008621152220351401C0500032A0202DE00"
            + String(repeating: "011F", count: 10),
    ]
    static let longUCS2Text = String(repeating: "ş", count: 66) + "😀" + String(repeating: "ğ", count: 10)
    /// Two GSM 7-bit parts from "12345", 16-bit reference 0x1234.
    static let longGSM = [
        "07919471016700004405812143F5000062115222035140A106080412340201"
            + String(repeating: "C16030180C0683", count: 19) + "41",
        "07919471016700004405812143F50000621152220351401306080412340202F4709A0DDAF0DEEB8D0F",
    ]
    static let longGSMText = String(repeating: "A", count: 153) + "tail [ok]"
    /// From the name "Turkcell", sent 2026-01-02 03:04:05 -05:00.
    static let alphanumeric = "0791947101670000040ED0D4BA7C3D2EB3D900006210203040500A02C834"
    static let turkishSingleShift = "0791947101670000440C910955153254760000621152220351401203240101486EE69BF41A14DE9CC39B31"
    static let turkishLockingShift = "0791947101670000440C91095515325476000062115222035140140325010100E6D3A0B3DFCD2ECB59A04ED90C"

    /// From the name "05551234567", which looks like a phone number.
    static let nameLikeNumber = "14D0B05AAD1693CD6835DB0D"
    /// The phone number 05551234567.
    static let number = "0B815055214365F7"

    /// A received UCS-2 PDU on 2026-11-`day` at 22:`minute`:15 +01:00, for the
    /// tests that need many variations. `part` is reference, total, sequence.
    static func deliver(_ text: String, address: String = "0C91095515325476", day: Int = 25,
                        minute: Int = 30, part: (Int, Int, Int)? = nil) -> String {
        func hex(_ value: Int) -> String { String(format: "%02X", value) }
        func swapped(_ value: Int) -> String { "\(value % 10)\(value / 10)" }
        let header = part.map { "050003" + hex($0.0) + hex($0.1) + hex($0.2) } ?? ""
        let body = text.utf16.map { String(format: "%04X", $0) }.joined()
        return "0791947101670000" + (part == nil ? "04" : "44") + address + "0008"
            + "6211" + swapped(day) + "22" + swapped(minute) + "5140"
            + hex((header.count + body.count) / 2) + header + body
    }

    static let submitGSM = "0001000C91095515325476000013C8329BFD066D50F7B79C4DDEA4409B720D"
    static let submitUCS2 = "0001000B815055214365F700083E004D0065007200680061006200610020006400FC006E00790061002C0020006E006100730131006C00730131006E003F0020011F00FC015F006900F600E7"
    static let submitUCS2Text = "Merhaba dünya, nasılsın? ğüşiöç"
    /// "x" 152 times, then "[yyyyyyyy": the escape pair of "[" must not be split.
    static let submitLongGSM = [
        "0041000D91947110325476F800009F050003070201F0"
            + String(repeating: "783C1E8FC7E3F1", count: 18) + "783C1E8FC7E301",
        "0041000D91947110325476F800001105000307020236BC7C3E9FCFE7F379",
    ]
    static let submitLongUCS2 = [
        "0041000D91947110325476F800088A050003070201" + String(repeating: "015F", count: 66),
        "0041000D91947110325476F800081E050003070202D83DDE00" + String(repeating: "011F", count: 10),
    ]
}

final class SMSTests: XCTestCase {
    func testDecodesGSM7WithEscapes() {
        let pdu = SMSPDU(hex: PDU.gsm)
        XCTAssertEqual(pdu?.kind, .deliver)
        XCTAssertEqual(pdu?.address, "+905551234567")
        XCTAssertEqual(pdu?.text, PDU.gsmText)
        XCTAssertEqual(pdu?.timestamp, Date(timeIntervalSince1970: 1_795_642_215))
        XCTAssertNil(pdu?.part)
    }

    func testDecodesUCS2() {
        XCTAssertEqual(SMSPDU(hex: PDU.ucs2)?.text, PDU.ucs2Text)
    }

    func testDecodesAlphanumericSenderAndNegativeTimeZone() {
        let pdu = SMSPDU(hex: PDU.alphanumeric)
        XCTAssertEqual(pdu?.address, "Turkcell")
        XCTAssertEqual(pdu?.text, "Hi")
        XCTAssertEqual(pdu?.timestamp, Date(timeIntervalSince1970: 1_767_341_045))
    }

    func testDecodesTurkishShiftTables() {
        XCTAssertEqual(SMSPDU(hex: PDU.turkishSingleShift)?.text, "Işık ağaç")
        XCTAssertEqual(SMSPDU(hex: PDU.turkishLockingShift)?.text, "İyi günler, şef")
    }

    func testDecodesPartHeaders() {
        XCTAssertEqual(SMSPDU(hex: PDU.longUCS2[1])?.part, SMSPDU.Part(reference: 0x2A, total: 2, sequence: 2))
        XCTAssertEqual(SMSPDU(hex: PDU.longGSM[0])?.part, SMSPDU.Part(reference: 0x1234, total: 2, sequence: 1))
        XCTAssertEqual(SMSPDU(hex: PDU.longGSM[0])?.address, "12345")
        XCTAssertEqual(SMSPDU(hex: PDU.longGSM[1])?.text, "tail [ok]")
    }

    func testFollowsTheRulesForOddPDUs() {
        // Reserved message type 3 is read as a received message.
        let reserved = String(PDU.gsm.prefix(16)) + "07" + String(PDU.gsm.dropFirst(18))
        XCTAssertEqual(SMSPDU(hex: reserved)?.kind, .deliver)
        XCTAssertEqual(SMSPDU(hex: reserved)?.text, PDU.gsmText)
        // A header whose last element is cut short is ignored as a whole.
        let pdu = SMSPDU(hex: "0791947101670000440C910955153254760000621152220351400A0600032A020124C834")
        XCTAssertNil(pdu?.part)
        XCTAssertEqual(pdu?.text, "Hi")
        // Escape twice is a space; an undefined escape code is the main table's character.
        XCTAssertEqual(GSMAlphabet.decode([0x1B, 0x1B, 0x41]), " A")
        XCTAssertEqual(GSMAlphabet.decode([0x1B, 0x41, 0x1B]), "A ")
        XCTAssertEqual(GSMAlphabet.decode([0x1B, 0x40, 0x1B, 0x60], locking: 1), "|ç")
        // Compressed text is not decoded as if it were plain.
        let compressed = String(PDU.gsm.prefix(36)) + "20" + String(PDU.gsm.dropFirst(38))
        XCTAssertEqual(SMSPDU(hex: compressed)?.text, "(Compressed message, it cannot be shown.)")
        XCTAssertEqual(SMSPDU.alphabet(coding: 0x0C), .gsm7)  // reserved character set
        XCTAssertEqual(SMSPDU.alphabet(coding: 0x48), .ucs2)  // marked for automatic deletion
        XCTAssertEqual(SMSPDU.alphabet(coding: 0x90), .gsm7)  // reserved group
        XCTAssertEqual(SMSPDU.alphabet(coding: 0xD8), .gsm7)  // message waiting, 7-bit
        XCTAssertEqual(SMSPDU.alphabet(coding: 0xE8), .ucs2)  // message waiting, UCS-2
        XCTAssertEqual(SMSPDU.alphabet(coding: 0xF4), .data)
        // A time stamp digit that is not a digit counts as 0.
        XCTAssertEqual(SMSPDU.timestamp([0x62, 0x11, 0x52, 0x22, 0x03, 0xF1, 0x40]),
                       SMSPDU.timestamp([0x62, 0x11, 0x52, 0x22, 0x03, 0x01, 0x40]))
    }

    func testRejectsBrokenPDUs() {
        XCTAssertNil(SMSPDU(hex: ""))
        XCTAssertNil(SMSPDU(hex: "zz"))
        XCTAssertNil(SMSPDU(hex: "079194"))
        XCTAssertNil(SMSPDU(hex: String(PDU.gsm.prefix(30))))
        // Every cut-off length must fail or decode, never crash.
        for length in stride(from: 0, to: PDU.longGSM[0].count, by: 2) {
            _ = SMSPDU(hex: String(PDU.longGSM[0].prefix(length)))
            _ = SMSPDU(hex: String(PDU.turkishSingleShift.prefix(length)))
        }
        // A status report is recognised but not decoded.
        XCTAssertEqual(SMSPDU(hex: "0006000C910955153254766211522203514062115222035140")?.kind, .other)
    }

    func testJoinsLongMessagesInAnyOrder() {
        let parts = [
            SMSStoredPart(index: 4, status: 0, pdu: SMSPDU(hex: PDU.longUCS2[1])!),
            SMSStoredPart(index: 5, status: 1, pdu: SMSPDU(hex: PDU.gsm)!),
            SMSStoredPart(index: 7, status: 1, pdu: SMSPDU(hex: PDU.longGSM[0])!),
            SMSStoredPart(index: 8, status: 1, pdu: SMSPDU(hex: PDU.longUCS2[0])!),
            SMSStoredPart(index: 9, status: 1, pdu: SMSPDU(hex: PDU.longGSM[1])!),
        ]
        let messages = SMSStore.messages(parts)
        XCTAssertEqual(messages.count, 3)
        let long = messages.first { $0.indices == [4, 8] }
        XCTAssertEqual(long?.text, PDU.longUCS2Text)
        XCTAssertEqual(long?.unread, true)
        XCTAssertEqual(long?.missingParts, 0)
        XCTAssertEqual(messages.first { $0.indices == [7, 9] }?.text, PDU.longGSMText)
        XCTAssertEqual(messages.first { $0.indices == [5] }?.unread, false)
    }

    func testMarksMissingParts() {
        let message = SMSStore.messages([SMSStoredPart(index: 1, status: 0, pdu: SMSPDU(hex: PDU.longGSM[1])!)])
        XCTAssertEqual(message.first?.missingParts, 1)
        XCTAssertEqual(message.first?.text, " […] tail [ok]")
    }

    func testParsesMessageList() {
        let parts = SMSStore.parts(["+CMGL: 0,1,,25", PDU.gsm, "+CMGL: 3,0,\"a,b\",120", PDU.ucs2,
                                    "+CMGL: 4,1,,5", "+CMGL: 6,3,,30", PDU.submitGSM, "+CMGL: 7,1,,9", "nonsense"])
        XCTAssertEqual(parts.map { $0.index }, [0, 3, 4, 6, 7])
        XCTAssertEqual(parts.map { $0.status }, [1, 0, 1, 3, 1])
        XCTAssertEqual(parts.map { $0.pdu.kind }, [.deliver, .deliver, .other, .submit, .other])
        XCTAssertEqual(parts[3].pdu.address, "+905551234567")
        XCTAssertEqual(parts[3].pdu.text, PDU.gsmText)
        let messages = SMSStore.messages(parts)
        XCTAssertEqual(messages.first { $0.indices == [6] }?.incoming, false)
        XCTAssertEqual(SMSStore.usedCount(["+CPMS: \"ME\",3,255,\"ME\",3,255,\"ME\",3,255"]), 3)
        XCTAssertNil(SMSStore.usedCount(["+CMS ERROR: 302"]))
    }

    private func stored(_ pdus: [String]) -> [SMSStoredPart] {
        pdus.enumerated().map { SMSStoredPart(index: $0.offset, status: 0, pdu: SMSPDU(hex: $0.element)!) }
    }

    func testBuildsTestPDUs() {
        let pdu = SMSPDU(hex: PDU.deliver("Selam ş", day: 26, minute: 5, part: (7, 3, 2)))
        XCTAssertEqual(pdu?.text, "Selam ş")
        XCTAssertEqual(pdu?.address, "+905551234567")
        XCTAssertEqual(pdu?.part, SMSPDU.Part(reference: 7, total: 3, sequence: 2))
        XCTAssertEqual(pdu?.timestamp, Date(timeIntervalSince1970: 1_795_642_215 + 86400 - 25 * 60))
    }

    func testCleansHostileText() {
        XCTAssertEqual(SMSText.clean("a\u{1B}[2Jb\r\nc\rd\u{202E}e\u{9B}f\tg\u{0}h\u{2028}i"),
                       "a\u{FFFD}[2Jb\nc\nd\u{FFFD}e\u{FFFD}f\tg\u{FFFD}h\ni")
        XCTAssertEqual(SMSText.clean("Bank\r\nFrom x\ty", singleLine: true), "Bank From x y")
        XCTAssertEqual(SMSText.clean("👨‍👩‍👧 İyi günler\n"), "👨‍👩‍👧 İyi günler\n")
        // The raw PDU keeps what was sent; the message that is shown does not.
        let hostile = PDU.deliver("x\u{1B}]0;title\u{07}y")
        XCTAssertEqual(SMSPDU(hex: hostile)?.text, "x\u{1B}]0;title\u{07}y")
        XCTAssertEqual(SMSStore.messages(stored([hostile])).first?.text, "x\u{FFFD}]0;title\u{FFFD}y")
        let long = [PDU.deliver("a\u{1B}", part: (1, 2, 1)), PDU.deliver("[2Jb", part: (1, 2, 2))]
        XCTAssertEqual(SMSStore.messages(stored(long)).first?.text, "a\u{FFFD}[2Jb")
    }

    func testSenderNameIsNotANumber() {
        let named = SMSPDU(hex: PDU.deliver("Hi", address: PDU.nameLikeNumber))
        XCTAssertEqual(named?.address, "05551234567")
        XCTAssertEqual(named?.addressIsName, true)
        XCTAssertEqual(SMSPDU(hex: PDU.deliver("Hi", address: PDU.number))?.address, "05551234567")
        XCTAssertEqual(SMSPDU(hex: PDU.deliver("Hi", address: PDU.number))?.addressIsName, false)
        XCTAssertEqual(SMSStore.messages(stored([PDU.deliver("Hi", address: PDU.nameLikeNumber)])).first?.addressIsName,
                       true)
        XCTAssertEqual(SMSStore.messages(stored([PDU.gsm])).first?.addressIsName, false)
        // A name and a number that read the same are different senders.
        let mixed = [PDU.deliver("one", address: PDU.number, part: (5, 2, 1)),
                     PDU.deliver("two", address: PDU.nameLikeNumber, part: (5, 2, 2))]
        XCTAssertEqual(SMSStore.messages(stored(mixed)).count, 2)
        // More than 20 semi-octets of address are not allowed.
        XCTAssertNil(SMSPDU(hex: PDU.deliver("Hi", address: "16D0" + String(repeating: "31", count: 11))))
        XCTAssertNotNil(SMSPDU(hex: PDU.deliver("Hi", address: "14D0" + String(repeating: "31", count: 10))))
    }

    func testKeepsLongMessagesWithAReusedReferenceApart() {
        func texts(_ pdus: [String]) -> [[Int]: String] {
            Dictionary(uniqueKeysWithValues: SMSStore.messages(stored(pdus)).map { ($0.indices, $0.text) })
        }
        // A day apart, stored interleaved.
        XCTAssertEqual(texts([PDU.deliver("A1", part: (9, 2, 1)), PDU.deliver("B1", day: 26, part: (9, 2, 1)),
                              PDU.deliver("A2", part: (9, 2, 2)), PDU.deliver("B2", day: 26, part: (9, 2, 2))]),
                       [[0, 2]: "A1A2", [1, 3]: "B1B2"])
        // A day apart, each with one part only.
        XCTAssertEqual(texts([PDU.deliver("A1", part: (9, 2, 1)), PDU.deliver("B2", day: 26, part: (9, 2, 2))]),
                       [[0]: "A1 […] ", [1]: " […] B2"])
        // At the same time, one after the other.
        XCTAssertEqual(texts([PDU.deliver("A1", part: (9, 2, 1)), PDU.deliver("A2", part: (9, 2, 2)),
                              PDU.deliver("B1", part: (9, 2, 1)), PDU.deliver("B2", part: (9, 2, 2))]),
                       [[0, 1]: "A1A2", [2, 3]: "B1B2"])
        // Minutes apart: the nearest in time wins.
        XCTAssertEqual(texts([PDU.deliver("A1", minute: 10, part: (9, 2, 1)),
                              PDU.deliver("B1", minute: 40, part: (9, 2, 1)),
                              PDU.deliver("B2", minute: 41, part: (9, 2, 2))]),
                       [[0]: "A1 […] ", [1, 2]: "B1B2"])
        // The same part twice is one part; a different one in its place is not hidden.
        XCTAssertEqual(texts([PDU.deliver("A1", part: (9, 2, 1)), PDU.deliver("A1", part: (9, 2, 1)),
                              PDU.deliver("A2", part: (9, 2, 2)), PDU.deliver("X2", part: (9, 2, 2))]),
                       [[0, 1, 2]: "A1A2", [3]: " […] X2"])
    }

    func testSkipsNoticesInTheMessageList() {
        let parts = SMSStore.parts(["+CMGL: 0,1,,25", "RING", "+QIND: \"csq\",20,99", PDU.gsm,
                                    "+CMGL: 1,0,,25", PDU.gsm, "RING"])
        XCTAssertEqual(parts.map { $0.index }, [0, 1])
        XCTAssertEqual(parts.map { $0.pdu.text }, [PDU.gsmText, PDU.gsmText])
    }

    func testSurvivesRandomPDUs() {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 40) & 0xFF
        }
        let seeds = [PDU.gsm, PDU.ucs2, PDU.longUCS2[0], PDU.longGSM[0], PDU.alphanumeric, PDU.turkishSingleShift,
                     PDU.turkishLockingShift, PDU.submitLongGSM[0]].map { Hex.bytes($0)! }
        var parts: [SMSStoredPart] = []
        for round in 0..<20000 {
            var bytes = seeds[round % seeds.count]
            if round % 4 == 3 {
                bytes = (0..<next()).map { _ in UInt8(next()) }
            } else {
                for _ in 0...(next() % 4) { bytes[next() % bytes.count] = UInt8(next()) }
                if next() % 4 == 0 { bytes.removeLast(next() % bytes.count) }
            }
            if let pdu = SMSPDU(hex: Hex.string(bytes)) {
                parts.append(SMSStoredPart(index: round, status: next() % 4, pdu: pdu))
            }
        }
        XCTAssertGreaterThan(parts.count, 5000)
        let messages = SMSStore.messages(parts)
        XCTAssertEqual(messages.flatMap { $0.indices }.sorted(), parts.map { $0.index })
        func unsafe(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x09, 0x0A: return false
            case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069, 0x2028, 0x2029: return true
            default: return false
            }
        }
        for message in messages {
            XCTAssertFalse(message.text.unicodeScalars.contains(where: unsafe))
            XCTAssertFalse(message.address.unicodeScalars.contains { unsafe($0) || $0 == "\n" || $0 == "\t" })
        }
    }

    func testEncodesShortMessages() {
        XCTAssertEqual(SMSEncoder.submitPDUs(to: "+905551234567", text: PDU.gsmText, reference: 0), [PDU.submitGSM])
        XCTAssertEqual(SMSEncoder.submitPDUs(to: "05551234567", text: PDU.submitUCS2Text, reference: 0),
                       [PDU.submitUCS2])
        XCTAssertEqual(SMSEncoder.commandLength(ofPDU: PDU.submitGSM), 30)
        XCTAssertEqual(SMSEncoder.commandLength(ofPDU: PDU.gsm), 36)
        XCTAssertNil(SMSEncoder.submitPDUs(to: "+905551234567", text: "", reference: 0))
    }

    func testSplitsLongMessages() {
        let gsm = String(repeating: "x", count: 152) + "[yyyyyyyy"
        XCTAssertEqual(SMSEncoder.submitPDUs(to: "+4917012345678", text: gsm, reference: 7), PDU.submitLongGSM)
        XCTAssertEqual(SMSEncoder.submitPDUs(to: "+4917012345678", text: PDU.longUCS2Text, reference: 7),
                       PDU.submitLongUCS2)
    }

    func testPartCounts() {
        func count(_ text: String) -> Int { SMSEncoder.partCount(text).parts }
        XCTAssertEqual(count(String(repeating: "a", count: 160)), 1)
        XCTAssertEqual(count(String(repeating: "a", count: 161)), 2)
        XCTAssertEqual(count(String(repeating: "€", count: 80)), 1)   // two septets each
        XCTAssertEqual(count(String(repeating: "€", count: 81)), 2)
        XCTAssertEqual(count(String(repeating: "ş", count: 70)), 1)
        XCTAssertEqual(count(String(repeating: "ş", count: 71)), 2)
        XCTAssertEqual(count(String(repeating: "ş", count: 135)), 3)
        XCTAssertFalse(SMSEncoder.partCount("Hello [you]\n").ucs2)
        XCTAssertTrue(SMSEncoder.partCount("ı").ucs2)
    }

    func testEncodedMessagesDecodeAgain() {
        for text in ["a", "Kısa", String(repeating: "Uzun bir mesaj 😀 [€] ", count: 40),
                     String(repeating: "plain {text} ~ ", count: 40)] {
            let pdus = SMSEncoder.submitPDUs(to: "+4917012345678", text: text, reference: 9) ?? []
            XCTAssertEqual(pdus.count, SMSEncoder.partCount(text).parts)
            let parts = pdus.enumerated().map { SMSStoredPart(index: $0.offset, status: 3, pdu: SMSPDU(hex: $0.element)!) }
            let messages = SMSStore.messages(Array(parts.reversed()))
            XCTAssertEqual(messages.map { $0.text }, [text])
            XCTAssertEqual(messages.first?.address, "+4917012345678")
            for pdu in pdus { XCTAssertLessThanOrEqual(SMSEncoder.commandLength(ofPDU: pdu), 155) }
        }
    }

    func testNumberValidation() {
        XCTAssertEqual(SMSEncoder.normalizedNumber("+90 (555) 123-45 67"), "+905551234567")
        XCTAssertEqual(SMSEncoder.normalizedNumber("5555"), "5555")
        XCTAssertNil(SMSEncoder.normalizedNumber(""))
        XCTAssertNil(SMSEncoder.normalizedNumber("+"))
        XCTAssertNil(SMSEncoder.normalizedNumber("12+34"))
        XCTAssertNil(SMSEncoder.normalizedNumber("Turkcell"))
        XCTAssertNil(SMSEncoder.normalizedNumber("١٢٣"))
        XCTAssertNil(SMSEncoder.normalizedNumber(String(repeating: "1", count: 21)))
    }
}

final class SMSModemTests: XCTestCase {
    func testListsMessagesAroundANotice() throws {
        let fake = FakeModem(replies: [:])
        fake.store = [(0, 1, PDU.gsm), (1, 0, PDU.ucs2)]
        fake.listingNotice = "RING"
        let messages = try Modem(channel: ATChannel(transport: fake)).messages()
        XCTAssertEqual(messages.map { $0.text }.sorted(), [PDU.gsmText, PDU.ucs2Text].sorted())
    }

    func testListsAndDeletesMessages() throws {
        let fake = FakeModem(replies: [:])
        fake.store = [(0, 1, PDU.longUCS2[0]), (2, 0, PDU.gsm), (5, 0, PDU.longUCS2[1])]
        let modem = Modem(channel: ATChannel(transport: fake))
        XCTAssertEqual(try modem.storedMessageCount(), 3)
        let messages = try modem.messages()
        XCTAssertEqual(fake.sent, ["AT+CPMS?", "AT+CMGF=0", "AT+CMGL=4"])
        XCTAssertEqual(messages.map { $0.text }.sorted(), [PDU.gsmText, PDU.longUCS2Text].sorted())
        XCTAssertEqual(messages.map { $0.unread }, [true, true])
        XCTAssertEqual(try modem.messages().map { $0.unread }, [false, false])

        try modem.delete(messages.first { $0.indices == [0, 5] }!)
        XCTAssertEqual(fake.store.map { $0.index }, [2])
        XCTAssertEqual(try modem.storedMessageCount(), 1)
        XCTAssertThrowsError(try modem.delete(messages.first { $0.indices == [0, 5] }!))
    }

    func testNoticesNewMessages() throws {
        let fake = FakeModem(replies: lteReplies)
        let modem = Modem(channel: ATChannel(transport: fake))
        _ = try modem.status()
        XCTAssertFalse(modem.takeNewMessageNotice())
        fake.receive(PDU.ucs2)
        XCTAssertEqual(try modem.status().apn, "internet.telekom")
        XCTAssertTrue(modem.takeNewMessageNotice())
        XCTAssertFalse(modem.takeNewMessageNotice())
        XCTAssertEqual(try modem.messages().map { $0.text }, [PDU.ucs2Text])
    }

    func testNoticeInsideAResponseIsKeptOutOfIt() throws {
        let fake = FakeModem(replies: ["AT+CPIN?": "+CMTI: \"ME\",4\r\n+CPIN: READY\r\n\r\nOK"])
        let channel = ATChannel(transport: fake)
        XCTAssertEqual(try channel.command("AT+CPIN?").lines, ["+CPIN: READY", "OK"])
        XCTAssertEqual(channel.takeUnsolicited(), ["+CMTI: \"ME\",4"])
    }

    func testSendsShortAndLongMessages() throws {
        let fake = FakeModem(replies: [:])
        let modem = Modem(channel: ATChannel(transport: fake))
        try modem.sendMessage(to: "+90 555 123 45 67", text: PDU.gsmText)
        XCTAssertEqual(fake.sent, ["AT+CMGF=0", "AT+CMGS=30"])
        XCTAssertEqual(fake.submitted, [PDU.submitGSM])

        try modem.sendMessage(to: "+4917012345678", text: PDU.longUCS2Text, reference: 7)
        XCTAssertEqual(Array(fake.submitted.dropFirst()), PDU.submitLongUCS2)
        XCTAssertEqual(Array(fake.sent.suffix(2)), ["AT+CMGS=152", "AT+CMGS=44"])
        XCTAssertFalse(fake.cancelled)
    }

    func testRefusesBadInputBeforeTalkingToTheModem() {
        let fake = FakeModem(replies: [:])
        let modem = Modem(channel: ATChannel(transport: fake))
        XCTAssertThrowsError(try modem.sendMessage(to: "12\rAT+CFUN=0", text: "x"))
        XCTAssertThrowsError(try modem.sendMessage(to: "+905551234567", text: ""))
        XCTAssertEqual(fake.sent, [])
    }

    func testSendFailureIsReported() {
        let fake = FakeModem(replies: ["AT+CMGS=30": "+CMS ERROR: 331"])
        let modem = Modem(channel: ATChannel(transport: fake))
        XCTAssertThrowsError(try modem.sendMessage(to: "+905551234567", text: PDU.gsmText)) { error in
            XCTAssertEqual(error as? ModemError, .rejected("Part 1 of 1 was not sent: +CMS ERROR: 331"))
        }
        XCTAssertEqual(fake.submitted, [])
    }

    func testMissingPromptIsCancelled() {
        let fake = FakeModem(replies: [:])
        fake.withholdPrompt = true
        let channel = ATChannel(transport: fake)
        XCTAssertThrowsError(try channel.command("AT+CMGS=30", payload: PDU.submitGSM, timeout: 0.3))
        XCTAssertTrue(fake.cancelled)
        XCTAssertEqual(fake.submitted, [])
    }
}

final class ESIMTests: XCTestCase {
    /// What the EC25-EUX sent, with three profiles on its eSIM.
    static let eidLines = ["+QESIM:\"eid\",0,\"89000000000000000000000000000002\""]
    static let listLines = [
        "+QESIM:\"list\",0",
        "\"8900000000000000011F\",\"0\",,\"Example Roaming\"",
        "\"8900000000000000029F\",\"0\",,\"Example Travel\"",
        "\"8900000000000000037F\",\"1\",\"Turkcell\",\"Turkcell \"",
    ]
    static let hardwareProfiles = [
        ESIMProfile(iccid: "8900000000000000011F", enabled: false, nickname: "", provider: "Example Roaming"),
        ESIMProfile(iccid: "8900000000000000029F", enabled: false, nickname: "", provider: "Example Travel"),
        ESIMProfile(iccid: "8900000000000000037F", enabled: true, nickname: "Turkcell", provider: "Turkcell"),
    ]

    func makeFake() -> FakeModem {
        let fake = FakeModem(replies: [:])
        fake.eid = "89000000000000000000000000000002"
        fake.profiles = [("8900000000000000011F", false, "", "Example Roaming"),
                         ("8900000000000000029F", false, "", "Example Travel"),
                         ("8900000000000000037F", true, "Turkcell", "Turkcell ")]
        return fake
    }

    func testParsesHardwareOutput() {
        XCTAssertEqual(ESIMParser.eid(Self.eidLines), "89000000000000000000000000000002")
        XCTAssertEqual(ESIMParser.profiles(Self.listLines), Self.hardwareProfiles)
        XCTAssertEqual(Self.hardwareProfiles.map { $0.name }, ["Example Roaming", "Example Travel", "Turkcell"])
    }

    func testParsesTheExamplesOfTheNote() {
        XCTAssertEqual(ESIMParser.eid(["+QESIM: \"eid\",0,\"89049032000001000000092092075457\""]),
                       "89049032000001000000092092075457")
        XCTAssertEqual(ESIMParser.profiles(["+QESIM: \"list\",0",
                                            "\"8932042000000199885F\",1,\"sim1\",\"V-Telekom\"",
                                            "\"89320420000002068839\",0,\"YFL1\",\"YFL1\""]),
                       [ESIMProfile(iccid: "8932042000000199885F", enabled: true, nickname: "sim1",
                                    provider: "V-Telekom"),
                        ESIMProfile(iccid: "89320420000002068839", enabled: false, nickname: "YFL1",
                                    provider: "YFL1")])
    }

    func testEmptyListAndFailures() {
        XCTAssertEqual(ESIMParser.profiles(["+QESIM: \"list\",0"]), [])
        XCTAssertNil(ESIMParser.profiles(["+QESIM: \"list\",1,2,\"6A82\""]))
        XCTAssertNil(ESIMParser.profiles([]))
        XCTAssertNil(ESIMParser.eid(["+QESIM: \"eid\",1,99,0"]))
        XCTAssertNil(ESIMParser.eid(["+QESIM: \"eid\",0,\"12\u{1B}[31m\""]))
        XCTAssertNil(ESIMParser.eid(["+QESIM: \"list\",0"]))
    }

    func testSkipsLinesThatAreNotProfiles() {
        let lines = ["+QESIM: \"list\",0", "RDY", "\"not an iccid\",0,\"a\",\"b\"",
                     "\"8932042000000199885F\",x,\"a\",\"b\"", "\"8932042000000199885F\",0"]
        XCTAssertEqual(ESIMParser.profiles(lines),
                       [ESIMProfile(iccid: "8932042000000199885F", enabled: false, nickname: "", provider: "")])
        XCTAssertEqual(ESIMParser.profiles(lines)?.first?.name, "8932042000000199885F")
    }

    func testCleansProfileNames() {
        let profiles = ESIMParser.profiles(["+QESIM: \"list\",0",
                                            "\"8932042000000199885F\",0,\"a\u{202E}b\",\" x\u{07}y \""])
        XCTAssertEqual(profiles?.first?.nickname, "a\u{FFFD}b")
        XCTAssertEqual(profiles?.first?.provider, "x\u{FFFD}y")
    }

    func testSurvivesMalformedProfileNames() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 40) & 0xFF
        }
        let nasty: [Unicode.Scalar] = ["\u{0}", "\u{7}", "\u{9}", "\u{A}", "\u{D}", "\u{1B}", "\u{7F}", "\u{85}", "\u{9B}",
                                       "\u{202E}", "\u{2066}", "\u{2028}", "\u{301}", ",", " ",
                                       "+", "ş", "\u{1F600}"]
        /// Any bytes read as UTF-8, mixed with characters that are known trouble.
        func text(quotes: Bool) -> String {
            var scalars = String.UnicodeScalarView()
            for _ in 0..<(next() % 3 == 0 ? next() : next() % 24) {
                if next() % 3 == 0 {
                    scalars.append(nasty[next() % nasty.count])
                } else {
                    scalars.append(contentsOf: String(decoding: [UInt8(next()), UInt8(next())],
                                                      as: UTF8.self).unicodeScalars)
                }
            }
            var kept = String.UnicodeScalarView()
            kept.append(contentsOf: scalars.filter { quotes || $0 != "\"" })
            return String(kept)
        }
        func check(_ profile: ESIMProfile, _ line: String) {
            XCTAssertTrue(ESIMParser.isValidICCID(profile.iccid), line.debugDescription)
            for name in [profile.nickname, profile.provider, profile.name] {
                XCTAssertLessThanOrEqual(name.unicodeScalars.count, ESIMParser.maxNameLength)
                XCTAssertEqual(name, name.trimmingCharacters(in: .whitespaces), line.debugDescription)
                XCTAssertFalse(name.unicodeScalars.contains {
                    switch $0.value {
                    case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069, 0x2028, 0x2029: return true
                    default: return false
                    }
                }, line.debugDescription)
            }
            XCTAssertFalse(profile.name.isEmpty)
        }
        let iccids = ["8900000000000000011F", "89320420000002068839", "8900000000000000037F"]
        let blank: [Unicode.Scalar] = [" ", "\u{9}", "\u{A}", "\u{D}", "\u{85}", "\u{2028}", "\u{2029}", "\u{A0}"]
        var named = 0
        for round in 0..<20000 {
            let iccid = iccids[round % iccids.count]
            let enabled = next() % 2 == 1
            let status = round % 2 == 0 ? "\"\(enabled ? 1 : 0)\"" : "\(enabled ? 1 : 0)"
            // Names without a quote cannot touch the ICCID or the status,
            // whatever else is in them, and come out as what was put in.
            let names = [text(quotes: false), text(quotes: false)]
            // Only blanks, including line ends, make an empty name.
            let expectEmpty = names.map { $0.unicodeScalars.allSatisfy { blank.contains($0) } }
            let line = "\"\(iccid)\",\(status),\"\(names[0])\",\"\(names[1])\""
            let profiles = ESIMParser.profiles(["+QESIM:\"list\",0", line])
            XCTAssertEqual(profiles?.count, 1, line.debugDescription)
            XCTAssertEqual(profiles?.first?.iccid, iccid, line.debugDescription)
            XCTAssertEqual(profiles?.first?.enabled, enabled, line.debugDescription)
            if let profile = profiles?.first {
                check(profile, line)
                XCTAssertEqual(profile.nickname.isEmpty, expectEmpty[0], line.debugDescription)
                XCTAssertEqual(profile.provider.isEmpty, expectEmpty[1], line.debugDescription)
                if profile.name != iccid { named += 1 }
            }
            // With quotes in the names, and with damaged lines, the fields may
            // shift, but what comes out must still be safe to show and to send.
            var broken = "\"\(iccid)\",\(status),\"\(text(quotes: true))\",\"\(text(quotes: true))\""
            if round % 3 == 0 {
                var bytes = Array(broken.utf8)
                for _ in 0...(next() % 4) { bytes[next() % bytes.count] = UInt8(next()) }
                if next() % 4 == 0 { bytes.removeLast(next() % bytes.count) }
                broken = String(decoding: bytes, as: UTF8.self)
            }
            let lines = ["+QESIM: \"list\",0"] + broken.split(whereSeparator: { $0.isNewline }).map(String.init)
            for profile in ESIMParser.profiles(lines) ?? [] { check(profile, broken) }
            _ = ESIMParser.eid([broken])
            _ = ESIMParser.eid(["+QESIM: \"eid\",0," + broken])
        }
        XCTAssertGreaterThan(named, 15000)
    }

    func testLongProfileNamesAreCut() {
        let long = String(repeating: "x", count: 500)
        let marks = "e" + String(repeating: "\u{301}", count: 500)
        let profiles = ESIMParser.profiles(["+QESIM: \"list\",0",
                                            "\"8932042000000199885F\",0,\"\(long)\",\"\(marks)\""])
        XCTAssertEqual(profiles?.first?.nickname, String(repeating: "x", count: 64))
        XCTAssertEqual(profiles?.first?.provider.unicodeScalars.count, 64)
    }

    func testICCIDValidation() {
        XCTAssertTrue(ESIMParser.isValidICCID("8900000000000000037F"))
        XCTAssertTrue(ESIMParser.isValidICCID("89320420000002068839"))
        XCTAssertFalse(ESIMParser.isValidICCID(""))
        XCTAssertFalse(ESIMParser.isValidICCID("8900000000000000037F0"))
        XCTAssertFalse(ESIMParser.isValidICCID("89900116\"\rAT+CFUN=0"))
        XCTAssertFalse(ESIMParser.isValidICCID("８９９００１１６１４０２"))
    }

    func testFailureDescriptions() {
        XCTAssertEqual(ESIMFailure(result: 2, info1: 10, info2: 1).description,
                       "eSIM error: profile not found (10, 1)")
        XCTAssertEqual(ESIMFailure(result: 2, info1: 10, info2: 3).description,
                       "eSIM error: not allowed by the profile's policy (10, 3)")
        XCTAssertEqual(ESIMFailure(result: 1, info1: 99, info2: 0).description, "internal error (99, 0)")
        XCTAssertEqual(ESIMFailure(result: 3, info1: nil, info2: nil).description, "SM-DP+ error")
    }

    func testReadsEIDAndProfilesFromTheModem() throws {
        let fake = makeFake()
        let info = try Modem(channel: ATChannel(transport: fake)).esim()
        XCTAssertEqual(info, ESIMInfo(eid: "89000000000000000000000000000002", profiles: Self.hardwareProfiles))
        XCTAssertEqual(fake.sent, ["AT+QESIM=\"eid\"", "AT+QESIM=\"list\""])
    }

    func testNoESIM() throws {
        // A modem that does not know the command, and one whose SIM is not an eSIM.
        let plain = FakeModem(replies: [:])
        XCTAssertNil(try Modem(channel: ATChannel(transport: plain)).esim())
        XCTAssertEqual(plain.sent, ["AT+QESIM=\"eid\""])
        let failing = FakeModem(replies: ["AT+QESIM=\"eid\"": "+QESIM: \"eid\",1,2,6A82\r\n\r\nOK"])
        XCTAssertNil(try Modem(channel: ATChannel(transport: failing)).esim())
    }

    func testEnablesAProfile() throws {
        let fake = makeFake()
        let modem = Modem(channel: ATChannel(transport: fake))
        try modem.enableESIMProfile(Self.hardwareProfiles[0])
        XCTAssertEqual(fake.sent, ["AT+QESIM=\"enable\",\"8900000000000000011F\""])
        XCTAssertEqual(try modem.esim()?.profiles.map { $0.enabled }, [true, false, false])
    }

    func testEnableFailuresAreReported() {
        let fake = makeFake()
        let modem = Modem(channel: ATChannel(transport: fake))
        XCTAssertThrowsError(try modem.enableESIMProfile(Self.hardwareProfiles[2])) {
            XCTAssertEqual($0 as? ModemError,
                           .rejected("The profile was not enabled: eSIM error: the profile is not disabled (10, 2)"))
        }
        let unknown = ESIMProfile(iccid: "89320420000002068839", enabled: false, nickname: "", provider: "")
        XCTAssertThrowsError(try modem.enableESIMProfile(unknown)) {
            XCTAssertEqual($0 as? ModemError,
                           .rejected("The profile was not enabled: eSIM error: profile not found (10, 1)"))
        }
        // A plain ERROR, without a +QESIM line.
        XCTAssertThrowsError(try Modem(channel: ATChannel(transport: FakeModem(replies: [:])))
            .enableESIMProfile(unknown))
    }

    func testBadICCIDNeverReachesTheModem() {
        let fake = makeFake()
        let hostile = ESIMProfile(iccid: "89\"\rAT+CFUN=0", enabled: false, nickname: "", provider: "")
        XCTAssertThrowsError(try Modem(channel: ATChannel(transport: fake)).enableESIMProfile(hostile))
        XCTAssertEqual(fake.sent, [])
    }
}
