// SPDX-License-Identifier: CC0-1.0
import XCTest
@testable import ModemKit

/// Behaves like the modem's AT port: echoes the command, then answers.
final class FakeModem: ByteTransport {
    var replies: [String: String]
    var pending = Data()
    var sent: [String] = []
    var silent = false

    init(replies: [String: String], stale: String = "") {
        self.replies = replies
        pending = Data(stale.utf8)
    }

    func write(_ data: Data) throws {
        let command = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        sent.append(command)
        guard !silent else { return }
        let body = replies[command] ?? "+CME ERROR: 100"
        pending.append(Data("\(command)\r\r\n\(body)\r\n".utf8))
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
