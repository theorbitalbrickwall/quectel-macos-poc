// SPDX-License-Identifier: CC0-1.0
// Draw the app icon (the antenna symbol on a rounded square) in every size
// that `iconutil` wants.
//
//   swift make-icon.swift OUT.iconset light|dark
import AppKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift OUT.iconset light|dark\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let dark = CommandLine.arguments[2] == "dark"
let background = dark ? NSColor(white: 0.16, alpha: 1) : NSColor.white
let foreground = dark ? NSColor.white : NSColor(red: 0, green: 0.48, blue: 1, alpha: 1)

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(text)\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let side = CGFloat(pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fail("no bitmap") }
    let style = NSImage.SymbolConfiguration(pointSize: side * 0.42, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [foreground]))
    guard let symbol = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                               accessibilityDescription: nil)?.withSymbolConfiguration(style)
    else { fail("the antenna symbol is missing") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    // Apple's icon grid: the square takes 824 of 1024 points.
    let square = NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.098, dy: side * 0.098)
    background.setFill()
    NSBezierPath(roundedRect: square, xRadius: square.width * 0.225, yRadius: square.width * 0.225).fill()
    let size = symbol.size
    symbol.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                           width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("no PNG") }
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try png.write(to: folder.appendingPathComponent(name))
}
