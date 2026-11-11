// SPDX-License-Identifier: CC0-1.0 AND MIT
// Contains code from idy/ch348-macos, Copyright (c) 2026 idy, under the MIT
// licence: see serial-driver/LICENSE-ch348-macos.
// Minimal host app. macOS only loads a driver extension that is embedded in
// an app in /Applications and activated through the SystemExtensions API.
import AppKit
import SystemExtensions

@main
final class Installer: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    private let identifier = "space.linuxgemini.quectel-serial.driver"
    private let status = NSTextField(wrappingLabelWithString:
        "Install the driver to get /dev/cu.quectel* ports for the modem's AT interfaces.")
    private var window: NSWindow!

    static func main() {
        let app = NSApplication.shared
        let delegate = Installer()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 210),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Quectel Serial Driver"
        status.frame = NSRect(x: 25, y: 85, width: 470, height: 100)
        window.contentView?.addSubview(status)
        let buttons: [(String, Selector, CGFloat)] = [
            ("Install / Update", #selector(install), 25), ("Uninstall", #selector(uninstall), 205),
        ]
        for (title, action, x) in buttons {
            let button = NSButton(title: title, target: self, action: action)
            button.frame = NSRect(x: x, y: 30, width: 165, height: 32)
            window.contentView?.addSubview(button)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--activate") { install() }
    }

    @objc private func install() {
        status.stringValue = "Requesting driver activation…"
        submit(.activationRequest(forExtensionWithIdentifier: identifier, queue: .main))
    }

    @objc private func uninstall() {
        status.stringValue = "Requesting driver removal…"
        submit(.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main))
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status.stringValue = "Approve the driver in System Settings → General → "
            + "Login Items & Extensions → Driver Extensions."
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        status.stringValue = result == .completed
            ? "Done. Replug the modem and check: ls /dev/cu.quectel*"
            : "Done, but a restart is required before the change takes effect."
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let detail = error as NSError
        status.stringValue = "Failed: \(error.localizedDescription)\n"
            + "\(detail.domain) code \(detail.code). Check signing and provisioning."
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
