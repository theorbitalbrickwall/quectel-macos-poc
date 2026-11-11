// SPDX-License-Identifier: CC0-1.0
import Foundation

public struct BulkEndpoints: Equatable {
    public var input: UInt8
    public var output: UInt8
}

public enum USBDescriptors {
    /// Find the bulk endpoint pair of an interface (alternate setting 0) in a
    /// raw configuration descriptor.
    public static func bulkEndpoints(configuration: Data, interfaceNumber: UInt8) -> BulkEndpoints? {
        let bytes = [UInt8](configuration)
        var offset = 0
        var inTarget = false
        var input: UInt8?
        var output: UInt8?
        while offset + 2 <= bytes.count {
            let length = Int(bytes[offset])
            let kind = bytes[offset + 1]
            guard length >= 2, offset + length <= bytes.count else { break }
            if kind == 4, length >= 9 {          // interface descriptor
                inTarget = bytes[offset + 2] == interfaceNumber && bytes[offset + 3] == 0
            } else if kind == 5, length >= 7, inTarget, bytes[offset + 3] & 0x03 == 2 {
                let address = bytes[offset + 2]  // bulk endpoint descriptor
                if address & 0x80 != 0 {
                    input = input ?? address
                } else {
                    output = output ?? address
                }
            }
            offset += length
        }
        guard let input, let output else { return nil }
        return BulkEndpoints(input: input, output: output)
    }
}
