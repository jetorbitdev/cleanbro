// Places a window capture (taken with `screencapture -l <id>`, shadow included)
// on a teal gradient backdrop for the README.
// Usage: swift docs/screenshots/frame.swift <window.png> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let win = NSImage(contentsOfFile: args[1]),
      let winRep = win.representations.first else {
    print("usage: frame.swift <window.png> <out.png>"); exit(1)
}

// Work in pixels so Retina captures stay sharp
let ww = CGFloat(winRep.pixelsWide), wh = CGFloat(winRep.pixelsHigh)
let pad = ww * 0.07
let w = Int(ww + pad * 2), h = Int(wh + pad * 2)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: w, height: h)
let bg = NSBezierPath(roundedRect: canvas, xRadius: pad * 0.45, yRadius: pad * 0.45)
NSGradient(colors: [
    NSColor(srgbRed: 0.10, green: 0.72, blue: 0.62, alpha: 1),
    NSColor(srgbRed: 0.02, green: 0.36, blue: 0.40, alpha: 1),
    NSColor(srgbRed: 0.05, green: 0.14, blue: 0.22, alpha: 1),
])!.draw(in: bg, angle: -60)

win.draw(in: NSRect(x: pad, y: pad, width: ww, height: wh))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("✅ \(args[2])")
