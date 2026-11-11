// SPDX-License-Identifier: CC0-1.0
import Foundation
import IOKit
import IOUSBHost

/// Talks to a vendor-specific serial interface of the modem directly over USB,
/// so no serial driver has to be installed. macOS attaches no driver of its
/// own to these interfaces.
public final class USBTransport: ByteTransport {
    public static let quectelVendorID = 0x2C7C

    private let interface: IOUSBHostInterface
    private let input: IOUSBHostPipe
    private let output: IOUSBHostPipe
    private let interfaceNumber: UInt16
    private var closed = false
    // kIOReturnTimeout, kIOReturnAborted, kIOUSBTransactionTimeout
    private static let timeoutCodes: Set<UInt32> = [0xE00002D6, 0xE00002EB, 0xE0004051]

    /// - Parameter interfaceNumber: USB interface of the AT port (2 on the EC25).
    public init(vendorID: Int = USBTransport.quectelVendorID, interfaceNumber: Int = 2) throws {
        guard let service = USBTransport.findInterface(vendorID: vendorID, number: interfaceNumber) else {
            throw ModemError.notFound("No Quectel modem with USB interface \(interfaceNumber) found.")
        }
        defer { IOObjectRelease(service) }
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil,
                                               interestHandler: nil)
        } catch {
            throw ModemError.io("Cannot open the modem's USB interface: \(error.localizedDescription)")
        }
        self.interfaceNumber = UInt16(interfaceNumber)
        let configuration = interface.configurationDescriptor
        let bytes = Data(bytes: configuration, count: Int(configuration.pointee.wTotalLength))
        guard let endpoints = USBDescriptors.bulkEndpoints(configuration: bytes,
                                                           interfaceNumber: UInt8(interfaceNumber)) else {
            interface.destroy()
            throw ModemError.notFound("USB interface \(interfaceNumber) has no bulk endpoints.")
        }
        do {
            input = try interface.copyPipe(withAddress: Int(endpoints.input))
            output = try interface.copyPipe(withAddress: Int(endpoints.output))
        } catch {
            interface.destroy()
            throw ModemError.io("Cannot open the USB endpoints: \(error.localizedDescription)")
        }
        setLineState(true)
    }

    private static func property(_ service: io_service_t, _ key: String) -> Int? {
        let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? NSNumber)?.intValue
    }

    /// Walk all USB interfaces instead of relying on the USB matching rules,
    /// which only accept certain key combinations.
    private static func findInterface(vendorID: Int, number: Int) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            if property(service, "idVendor") == vendorID,
               property(service, "bInterfaceNumber") == number,
               property(service, "bInterfaceClass") == 0xFF {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    /// CDC SET_CONTROL_LINE_STATE (DTR | RTS), as the Linux option driver sends.
    private func setLineState(_ on: Bool) {
        let request = IOUSBDeviceRequest(bmRequestType: 0x21, bRequest: 0x22, wValue: on ? 3 : 0,
                                         wIndex: interfaceNumber, wLength: 0)
        try? interface.__send(request, data: nil, bytesTransferred: nil, completionTimeout: 1)
    }

    public func write(_ data: Data) throws {
        var transferred = 0
        do {
            try output.__sendIORequest(with: NSMutableData(data: data), bytesTransferred: &transferred,
                                     completionTimeout: 5)
        } catch {
            throw ModemError.io("USB write failed: \(error.localizedDescription)")
        }
    }

    public func read(timeout: TimeInterval) throws -> Data {
        guard let buffer = NSMutableData(length: 4096) else { return Data() }
        var transferred = 0
        do {
            try input.__sendIORequest(with: buffer, bytesTransferred: &transferred,
                                    completionTimeout: max(0.01, timeout))
        } catch let error as NSError {
            // A timeout only means the modem had nothing to say.
            if USBTransport.timeoutCodes.contains(UInt32(truncatingIfNeeded: error.code)) {
                return Data(bytes: buffer.bytes, count: min(transferred, buffer.length))
            }
            throw ModemError.io("USB read failed: \(error.localizedDescription)")
        }
        return Data(bytes: buffer.bytes, count: min(transferred, buffer.length))
    }

    public func close() {
        guard !closed else { return }
        closed = true
        setLineState(false)
        interface.destroy()
    }

    deinit { close() }
}
