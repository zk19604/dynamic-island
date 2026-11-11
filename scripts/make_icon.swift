// Draws the dynamic-island app icon and writes Resources/AppIcon.icns.
// Run from the repo root:  swift scripts/make_icon.swift
// (Only needed when changing the design; the .icns is committed.)
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824x824 body centered, continuous-corner rounded square.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor.black.setFill()
bodyPath.fill()
ctx.restoreGState()

// Background: deep graphite gradient with a soft colored glow.
ctx.saveGState()
bodyPath.addClip()
NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.21, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)])!
    .draw(in: body, angle: -90)
let glow = NSGradient(colors: [NSColor(calibratedRed: 0.55, green: 0.35, blue: 1.0, alpha: 0.55),
                               NSColor(calibratedRed: 0.55, green: 0.35, blue: 1.0, alpha: 0)])!
glow.draw(fromCenter: NSPoint(x: 512, y: 600), radius: 0, toCenter: NSPoint(x: 512, y: 600), radius: 420, options: [])
// Top sheen.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
ctx.restoreGState()

// The island: a black pill with a thin light rim.
let pill = CGRect(x: 212, y: 452, width: 600, height: 180)
let pillPath = NSBezierPath(roundedRect: pill, xRadius: 90, yRadius: 90)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.6).cgColor)
NSColor.black.setFill()
pillPath.fill()
ctx.restoreGState()
NSColor.white.withAlphaComponent(0.16).setStroke()
pillPath.lineWidth = 4
pillPath.stroke()

// Album art: rounded square with a warm gradient.
let art = CGRect(x: 262, y: 482, width: 120, height: 120)
let artPath = NSBezierPath(roundedRect: art, xRadius: 30, yRadius: 30)
ctx.saveGState()
artPath.addClip()
NSGradient(colors: [NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.3, alpha: 1),
                    NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.55, alpha: 1)])!
    .draw(in: art, angle: -45)
ctx.restoreGState()

// Waveform bars.
let heights: [CGFloat] = [56, 104, 76, 120, 64]
let barWidth: CGFloat = 22, gap: CGFloat = 16
var x: CGFloat = 812 - 50 - (barWidth * 5 + gap * 4)
for h in heights {
    let bar = CGRect(x: x, y: pill.midY - h / 2, width: barWidth, height: h)
    NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.5, alpha: 1).setFill()
    NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

image.unlockFocus()

// Write the iconset and convert to .icns.
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
