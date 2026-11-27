// SPDX-License-Identifier: CC0-1.0
import Foundation

/// Tracks a reboot the app asked for, so the menu can keep saying so until
/// the modem is back instead of showing each failed poll.
public struct RebootWatch: Equatable {
    /// Text to show while the modem is away.
    public let message: String
    private let deadline: Date
    private var gone = false

    /// `limit` bounds the wait, in case the modem never left or never returns.
    public init(message: String, now: Date = Date(), limit: TimeInterval = 60) {
        self.message = message
        deadline = now.addingTimeInterval(limit)
    }

    /// False once the limit has passed: show the real state again.
    public func isActive(now: Date = Date()) -> Bool {
        now < deadline
    }

    /// A poll failed: the modem has stopped answering or left the bus.
    public mutating func pollFailed() {
        gone = true
    }

    /// Whether a successful poll shows the rebooted modem. The modem still
    /// answers for a few seconds after the reboot command, and shortly after
    /// it returns it does not yet answer every query; the USB network mode is
    /// the last one in a poll.
    public func isBack(_ status: ModemStatus, now: Date = Date()) -> Bool {
        !isActive(now: now) || (gone && status.usbNetMode != nil)
    }
}
