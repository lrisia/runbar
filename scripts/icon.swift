// Draws the app icon into Resources/AppIcon.icns. Run from the repo root:
//   swift scripts/icon.swift
import AppKit

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

/// The icon on a 1024 pt canvas: a play button over a bar.
func drawIcon() {
    // macOS icon grid: an 824 pt body centred on the canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    hex(0xDDE1E7).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: hex(0xFFFFFF), ending: hex(0xDDE1E7))!.draw(in: shape, angle: -90)
    NSColor(white: 1, alpha: 0.14).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    rim.lineWidth = 4
    rim.stroke()

    // Shapes below are laid out top-down.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: 1024)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()
    let play = NSBezierPath()
    play.move(to: NSPoint(x: 420, y: 300))
    play.line(to: NSPoint(x: 420, y: 600))
    play.line(to: NSPoint(x: 673.5, y: 450))
    play.close()
    play.lineWidth = 44
    play.lineJoinStyle = .round
    hex(0x22C55E).setFill()
    hex(0x22C55E).setStroke()
    play.fill()
    play.stroke()
    hex(0x1C1C1E).setFill()
    NSBezierPath(roundedRect: NSRect(x: 262, y: 652, width: 500, height: 84), xRadius: 42, yRadius: 42).fill()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
