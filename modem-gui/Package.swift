// swift-tools-version:5.9
// SPDX-License-Identifier: CC0-1.0
import PackageDescription

let package = Package(
    name: "QuectelMenu",
    platforms: [.macOS(.v13)],
    targets: [
        // Modem logic without any UI: AT parsing, transports, status model.
        .target(
            name: "ModemKit",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("IOUSBHost")]
        ),
        .executableTarget(name: "QuectelMenu", dependencies: ["ModemKit"]),
        .executableTarget(name: "QuectelDebug", dependencies: ["ModemKit"]),
        .testTarget(name: "ModemKitTests", dependencies: ["ModemKit"]),
    ]
)
