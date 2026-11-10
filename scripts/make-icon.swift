// Draws the MetaDrag app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift <Resources dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: k, y: k)

    // macOS icon grid: 824 pt body, 100 pt margin
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor(white: 0.19, alpha: 1), NSColor(white: 0.03, alpha: 1)])!.draw(in: body, angle: -90)
    // soft sheen from the top
    NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // the ring
    let c = NSPoint(x: 512, y: 512)
    let rOut: CGFloat = 300, rIn: CGFloat = 150
    for i in 0..<6 {
        let a = CGFloat(i) * 60 + 90
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: rOut - 18, startAngle: a - 24, endAngle: a + 24)
        p.appendArc(withCenter: c, radius: rIn + 18, startAngle: a + 24, endAngle: a - 24, clockwise: true)
        p.close()
        p.lineJoinStyle = .round
        p.lineWidth = 36
        if i == 0 {
            // the "picked" petal lifts out, solid white
            p.transform(using: AffineTransform(translationByX: 0, byY: 22))
            NSColor.white.setFill()
            NSColor.white.setStroke()
            p.fill()
            p.stroke()
        } else {
            NSColor(white: 1, alpha: 0.15).setFill()
            NSColor(white: 1, alpha: 0.15).setStroke()
            p.fill()
            p.stroke()
        }
    }
    NSColor(white: 1, alpha: 0.92).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 106, y: c.y - 106, width: 212, height: 212)).fill()
    NSColor(white: 0.05, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 34, y: c.y - 34, width: 68, height: 68)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("MetaDrag-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "icon ok" : "iconutil failed")
