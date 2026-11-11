// SPDX-License-Identifier: CC0-1.0
import Foundation

/// Ready-made AT commands for the debug app, taken from the Quectel EC2x AT
/// manuals. Not every firmware supports every command; an unsupported one
/// just answers ERROR.
public struct ATCatalogEntry: Equatable {
    public enum Kind: Equatable {
        /// Only reads something. Sent at once.
        case query
        /// Changes the modem's state. The app asks before sending.
        case action
        /// Has values to fill in. The app puts it in the input field.
        case template
    }

    public var command: String
    public var summary: String
    public var kind: Kind

    init(_ command: String, _ summary: String, _ kind: Kind = .query) {
        self.command = command
        self.summary = summary
        self.kind = kind
    }
}

public struct ATCatalogGroup: Equatable {
    public var title: String
    public var entries: [ATCatalogEntry]
}

public enum ATCatalog {
    public static let groups: [ATCatalogGroup] = [
        ATCatalogGroup(title: "Module", entries: [
            .init("ATI", "Model and firmware revision"),
            .init("AT+QGMR", "Full firmware version"),
            .init("AT+GSN", "IMEI"),
            .init("AT+CFUN?", "Radio state (1 full, 4 airplane)"),
            .init("AT+QTEMP", "Temperatures"),
            .init("AT+CCLK?", "Clock"),
            .init("AT+CMEE=2", "Show error details", .action),
        ]),
        ATCatalogGroup(title: "SIM", entries: [
            .init("AT+CPIN?", "SIM state"),
            .init("AT+QSIMSTAT?", "SIM inserted or not"),
            .init("AT+QCCID", "ICCID"),
            .init("AT+CIMI", "IMSI"),
            .init("AT+CNUM", "Own number, if on the SIM"),
            .init("AT+CPIN=\"1234\"", "Enter the PIN", .template),
        ]),
        ATCatalogGroup(title: "Network", entries: [
            .init("AT+CSQ", "Signal strength (0-31)"),
            .init("AT+QCSQ", "Signal per technology"),
            .init("AT+QNWINFO", "Technology, operator, band"),
            .init("AT+QSPN", "Operator name"),
            .init("AT+COPS?", "Selected operator"),
            .init("AT+CREG?", "Registration, circuit switched"),
            .init("AT+CGREG?", "Registration, GPRS"),
            .init("AT+CEREG?", "Registration, LTE"),
            .init("AT+CGATT?", "Packet service attached or not"),
            .init("AT+QENG=\"servingcell\"", "Serving cell details"),
            .init("AT+QENG=\"neighbourcell\"", "Neighbour cells"),
            .init("AT+QCFG=\"nwscanmode\"", "Allowed technologies"),
            .init("AT+QCFG=\"band\"", "Allowed bands"),
            .init("AT+COPS=?", "Operator scan (takes minutes)"),
        ]),
        ATCatalogGroup(title: "Data", entries: [
            .init("AT+CGDCONT?", "PDP contexts and APNs"),
            .init("AT+CGACT?", "Which contexts are active"),
            .init("AT+CGPADDR", "IP addresses"),
            .init("AT+CGCONTRDP", "Active context details"),
            .init("AT+CGDCONT=1,\"IPV4V6\",\"internet\"", "Set the APN of context 1", .template),
        ]),
        ATCatalogGroup(title: "USB", entries: [
            .init("AT+QCFG=\"usbnet\"", "Network mode (1 = ECM)"),
            .init("AT+QURCCFG=\"urcport\"", "Port that gets URCs"),
            .init("AT+QCFG=\"usbnet\",1", "Set network mode, then reboot", .template),
        ]),
        ATCatalogGroup(title: "GNSS", entries: [
            .init("AT+QGPS?", "GNSS on or off"),
            .init("AT+QGPSLOC=2", "Current position"),
            .init("AT+QGPSCFG=\"outport\"", "Port that gets NMEA"),
            .init("AT+QGPS=1", "Turn GNSS on", .action),
            .init("AT+QGPSEND", "Turn GNSS off", .action),
        ]),
        ATCatalogGroup(title: "SMS", entries: [
            .init("AT+CMGF?", "Message format (0 PDU, 1 text)"),
            .init("AT+CSCA?", "Service centre number"),
            .init("AT+CPMS?", "Message storage"),
            .init("AT+CMGF=1", "Use text format", .action),
            .init("AT+CMGL=\"ALL\"", "List messages (text format)"),
        ]),
        ATCatalogGroup(title: "Power", entries: [
            .init("AT+CFUN=4", "Airplane mode (radio off)", .action),
            .init("AT+CFUN=1", "Radio on", .action),
            .init("AT+CFUN=1,1", "Reboot the modem", .action),
            .init("AT+QPOWD", "Power the modem down", .action),
        ]),
    ]
}
