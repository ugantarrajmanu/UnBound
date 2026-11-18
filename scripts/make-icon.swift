// Renders the Unbound app icon (same mark as the Android adaptive icon) into an .iconset.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Coordinates in a 108-unit space (matches the Android vector), flipped to top-left origin.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: s / 108, y: -s / 108)

    // macOS icon grid: rounded square inset ~10%.
    let tile = CGRect(x: 6, y: 6, width: 96, height: 96)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 22, cornerHeight: 22, transform: nil)
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 0.08, green: 0.12, blue: 0.26, alpha: 1),
                                       CGColor(red: 0.03, green: 0.05, blue: 0.11, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 54, y: 6), end: CGPoint(x: 54, y: 102), options: [])
    ctx.resetClip()

    // Mac display (outline) and stand.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(4)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 26, y: 37, width: 34, height: 27), cornerWidth: 3, cornerHeight: 3, transform: nil))
    ctx.strokePath()
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 37, y: 71)); ctx.addLine(to: CGPoint(x: 49, y: 71))
    ctx.strokePath()

    // Tablet breaking out to the side.
    ctx.setFillColor(CGColor(red: 0.30, green: 0.55, blue: 1.0, alpha: 1))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 60, y: 43, width: 24, height: 32), cornerWidth: 4, cornerHeight: 4, transform: nil))
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(out.path)")
