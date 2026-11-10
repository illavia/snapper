// Draws the Snapper app icon and writes an .iconset folder. Usage: swift Scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.45, blue: 0.95, alpha: 1),
                        NSColor(red: 0.05, green: 0.20, blue: 0.55, alpha: 1)])!.draw(in: shape, angle: -90)

    // Viewfinder corners
    NSColor.white.setStroke()
    let m = s * 0.26, len = s * 0.16
    let corners = NSBezierPath()
    corners.lineWidth = s * 0.045
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    for (x, y, dx, dy) in [(m, m, 1.0, 1.0), (s - m, m, -1.0, 1.0), (m, s - m, 1.0, -1.0), (s - m, s - m, -1.0, -1.0)] {
        corners.move(to: NSPoint(x: x + CGFloat(dx) * len, y: y))
        corners.line(to: NSPoint(x: x, y: y))
        corners.line(to: NSPoint(x: x, y: y + CGFloat(dy) * len))
    }
    corners.stroke()
    // Centre dot
    NSColor.white.setFill()
    let r = s * 0.075
    NSBezierPath(ovalIn: NSRect(x: s / 2 - r, y: s / 2 - r, width: r * 2, height: r * 2)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                       ("512x512@2x", 1024)] {
    try render(pixels).write(to: out.appendingPathComponent("icon_\(name).png"))
}
