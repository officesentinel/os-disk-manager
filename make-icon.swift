#!/usr/bin/env swift
import AppKit

// Render a 1024x1024 app icon: squircle gradient background + drive glyph + wipe sparkle.
func renderMaster(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle background with margin.
    let margin = size * 0.06
    let rect = CGRect(x: margin, y: margin, width: size - 2*margin, height: size - 2*margin)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()

    // Vertical gradient: indigo -> blue.
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.31, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.95, alpha: 1)
    ])!
    grad.draw(in: rect, angle: -90)

    // Drive glyph (SF Symbol) in white, centered.
    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        NSColor.white.set()
        let r = CGRect(origin: .zero, size: sym.size)
        sym.draw(in: r)
        r.fill(using: .sourceAtop)
        tinted.unlockFocus()
        let gx = rect.midX - sym.size.width/2
        let gy = rect.midY - sym.size.height/2 - size*0.02
        tinted.draw(in: CGRect(x: gx, y: gy, width: sym.size.width, height: sym.size.height))
    }

    // Wipe sparkles (top-right) to convey "clean".
    let scfg = NSImage.SymbolConfiguration(pointSize: size * 0.20, weight: .bold)
    if let spark = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
        .withSymbolConfiguration(scfg) {
        let tinted = NSImage(size: spark.size)
        tinted.lockFocus()
        NSColor(calibratedRed: 1, green: 0.96, blue: 0.6, alpha: 1).set()
        let r = CGRect(origin: .zero, size: spark.size)
        spark.draw(in: r)
        r.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: CGRect(x: rect.maxX - spark.size.width - size*0.10,
                               y: rect.maxY - spark.size.height - size*0.12,
                               width: spark.size.width, height: spark.size.height))
    }

    img.unlockFocus()
    return img
}

func pngData(_ image: NSImage, px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: CGRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let master = renderMaster(size: 1024)

let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for s in specs {
    let data = pngData(master, px: s.px)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(s.name).png")
    try! data.write(to: url)
}
print("wrote \(specs.count) PNGs to \(outDir)")
