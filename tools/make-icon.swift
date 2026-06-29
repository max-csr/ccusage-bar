// Generates AppIcon.iconset PNGs for CC Usage.
// Motif: the app's usage ring — a Claude-coral arc on a dark squircle.
// Usage: swift tools/make-icon.swift [outDir]   (default outDir: AppIcon.iconset)
// Then:  iconutil -c icns <outDir> -o Resources/AppIcon.icns
import AppKit
import Foundation

func drawIcon(pixel: Int) -> Data {
    let s = CGFloat(pixel)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Dark rounded-square background with a soft top-to-bottom gradient.
    let margin = s * 0.085
    let frame = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let corner = frame.width * 0.235
    let bg = NSBezierPath(roundedRect: frame, xRadius: corner, yRadius: corner)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.17, green: 0.18, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: -90)

    // Usage ring: faint full-circle track + a coral arc (~80%) with round caps.
    let center = CGPoint(x: s / 2, y: s / 2)
    let radius = s * 0.285
    let lineWidth = s * 0.082

    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = lineWidth
    NSColor(white: 1, alpha: 0.10).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 288, clockwise: true)
    arc.lineWidth = lineWidth
    arc.lineCapStyle = .round
    NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1).setStroke()  // Claude coral ~ #D97757
    arc.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (name, px) in specs {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
    try! drawIcon(pixel: px).write(to: url)
    print("wrote \(name).png (\(px)px)")
}
print("done -> \(outDir)")
