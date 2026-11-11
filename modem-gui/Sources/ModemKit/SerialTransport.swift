// SPDX-License-Identifier: CC0-1.0
import Foundation

/// A serial port such as /dev/cu.quectel2 (published by the serial driver).
public final class SerialTransport: ByteTransport {
    private var descriptor: Int32

    public init(path: String) throws {
        descriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw ModemError.io("Cannot open \(path): \(String(cString: strerror(errno)))")
        }
        // Exclusive: a second program on the same port would take some of our
        // replies. Its open() now fails with "Resource busy" instead.
        // TIOCEXCL is _IO('t', 13); Swift does not import that macro.
        _ = ioctl(descriptor, 0x2000_740D)
        var settings = termios()
        tcgetattr(descriptor, &settings)
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&settings, speed_t(B115200))
        tcsetattr(descriptor, TCSANOW, &settings)
        tcflush(descriptor, TCIOFLUSH)
    }

    private func wait(for events: Int32, timeout: TimeInterval) -> Bool {
        var request = pollfd(fd: descriptor, events: Int16(events), revents: 0)
        return poll(&request, 1, Int32(max(0, timeout) * 1000)) > 0
    }

    public func write(_ data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            guard wait(for: POLLOUT, timeout: 5) else { throw ModemError.io("Serial port not writable") }
            let written = remaining.withUnsafeBytes { Foundation.write(descriptor, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw ModemError.io("Serial write failed: \(String(cString: strerror(errno)))")
            }
            remaining = Data(remaining.dropFirst(written))
        }
    }

    public func read(timeout: TimeInterval) throws -> Data {
        guard wait(for: POLLIN, timeout: timeout) else { return Data() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Foundation.read(descriptor, &buffer, buffer.count)
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return Data() }
            throw ModemError.io("Serial read failed: \(String(cString: strerror(errno)))")
        }
        if count == 0 { throw ModemError.io("Serial port closed (modem unplugged?)") }
        return Data(buffer[0..<count])
    }

    public func close() {
        if descriptor >= 0 {
            Foundation.close(descriptor)
            descriptor = -1
        }
    }

    deinit { close() }
}
