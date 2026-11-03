// Generates AppIcon.icns for CleanBro.
// Usage: swift Icon/make-icon.swift  (from the CleanBro/ folder)
import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

// Turns broom.jpg (dark silhouette on white) into an alpha mask cropped to the silhouette.
let glyph: (mask: CGImage, box: CGRect) = {
    let src = NSImage(contentsOf: here.appendingPathComponent("broom.jpg"))!
        .cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let w = src.width, h = src.height
    var px = [UInt8](repeating: 0, count: w * h)
    let gray = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    gray.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Ink coverage: white paper -> 0, the ~#484848 silhouette -> 255
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            let v = (255 - Double(px[y * w + x])) / (255 - 72)
            let a = UInt8(max(0, min(1, v)) * 255)
            px[y * w + x] = a
            if a > 128 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
    }
    // CGImage masks treat 0 as opaque, so invert
    let inverted = px.map { 255 - $0 }
    let provider = CGDataProvider(data: Data(inverted) as CFData)!
    let full = CGImage(maskWidth: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       provider: provider, decode: nil, shouldInterpolate: true)!
    let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    return (full.cropping(to: crop)!, CGRect(origin: .zero, size: crop.size))
}()

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824pt body inside a 1024pt canvas
    let k = s / 1024
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.shadowBlurRadius = 20 * k
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Teal gradient matching Color.accentTeal (0.0, 0.53, 0.47)
    NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.72, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.00, green: 0.42, blue: 0.38, alpha: 1),
    ])!.draw(in: path, angle: -90)

    // Broom glyph, fitted into a 560pt box centered on the body
    let ctx = NSGraphicsContext.current!.cgContext
    let box: CGFloat = 560 * k
    let scale = box / max(glyph.box.width, glyph.box.height)
    let w = glyph.box.width * scale, h = glyph.box.height * scale
    let dest = CGRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 16 * k,
                  color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.interpolationQuality = .high
    ctx.clip(to: dest, mask: glyph.mask)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(dest)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: here.appendingPathComponent("AppIcon.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "✅ Icon/AppIcon.icns" : "iconutil failed")
