// Renders Resources/AppIcon.icns. Run from the repository root: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let scale = size / 1024

    // Apple's icon grid: an 824 pt rounded square centered on a 1024 pt canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824).applying(CGAffineTransform(scaleX: scale, y: scale))
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.11, green: 0.10, blue: 0.24, alpha: 1).cgColor,
        NSColor(red: 0.27, green: 0.16, blue: 0.55, alpha: 1).cgColor,
        NSColor(red: 0.10, green: 0.55, blue: 0.75, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])

    let gains: [CGFloat] = [0.55, 0.72, 0.62, 0.40, 0.30, 0.38, 0.52, 0.68, 0.74, 0.60]
    let inset = tile.width * 0.16
    let area = tile.insetBy(dx: inset, dy: tile.height * 0.22)
    let points = gains.enumerated().map { index, gain in
        CGPoint(x: area.minX + area.width * (CGFloat(index) + 0.5) / CGFloat(gains.count), y: area.minY + area.height * gain)
    }

    let barWidth = 10 * scale
    context.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    for point in points {
        context.addPath(CGPath(roundedRect: CGRect(x: point.x - barWidth / 2, y: area.minY, width: barWidth, height: area.height),
                               cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    }
    context.fillPath()

    let ends = [CGPoint(x: area.minX - inset * 0.4, y: points[0].y)] + points + [CGPoint(x: area.maxX + inset * 0.4, y: points.last!.y)]
    let curve = CGMutablePath()
    curve.move(to: ends[0])
    // Catmull-Rom through the knobs, so the line reads as a filter response rather than steps.
    for index in 1..<ends.count {
        let before = ends[max(index - 2, 0)], start = ends[index - 1], end = ends[index], after = ends[min(index + 1, ends.count - 1)]
        curve.addCurve(to: end,
                       control1: CGPoint(x: start.x + (end.x - before.x) / 6, y: start.y + (end.y - before.y) / 6),
                       control2: CGPoint(x: end.x - (after.x - start.x) / 6, y: end.y - (after.y - start.y) / 6))
    }
    context.addPath(curve)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(26 * scale)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setShadow(offset: .zero, blur: 30 * scale, color: NSColor(red: 0.55, green: 0.85, blue: 1, alpha: 0.8).cgColor)
    context.strokePath()

    let knob = 50 * scale
    context.setShadow(offset: CGSize(width: 0, height: -4 * scale), blur: 10 * scale, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    context.setFillColor(NSColor.white.cgColor)
    for index in [1, 4, 8] {
        context.fillEllipse(in: CGRect(x: points[index].x - knob / 2, y: points[index].y - knob / 2, width: knob, height: knob))
    }
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(size: CGFloat(points)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(size: CGFloat(points * 2)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try render(size: 512).write(to: URL(fileURLWithPath: "docs/icon.png"))
exit(iconutil.terminationStatus)
