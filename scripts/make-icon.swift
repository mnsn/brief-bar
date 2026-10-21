// Regenerates Resources/AppIcon.icns:  swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple's icon grid: an 824 pt body centered on a 1024 pt canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(srgbRed: 0.07, green: 0.16, blue: 0.33, alpha: 1),
        NSColor(srgbRed: 0.12, green: 0.47, blue: 0.68, alpha: 1),
    ])?.draw(in: shape, angle: 90)

    // Three lines of a brief, each with the color of what it's about: needs you, running, done.
    // Drawn by hand: SF Symbols may not be used in app icons.
    let rows: [(color: NSColor, length: CGFloat)] = [
        (.systemOrange, 420), (.systemBlue, 330), (.systemGreen, 380),
    ]
    for (index, row) in rows.enumerated() {
        let centerY = 672 - CGFloat(index) * 160
        row.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 236, y: centerY - 46, width: 92, height: 92)).fill()
        NSColor.white.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: NSRect(x: 372, y: centerY - 34, width: row.length, height: 68), xRadius: 34, yRadius: 34).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try drawIcon(pixels: points * scale)?.write(to: iconset.appending(path: name))
    }
}
print(iconset.path)
