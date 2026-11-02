// Draws the AutoREQ app icon and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
// The icon shows a jagged room response and the flat, corrected response in the accent yellow.
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // The macOS icon grid: an 824-point rounded square in a 1024-point canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1).cgColor,
                                 NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // A log-frequency grid, like the chart in the app.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
    ctx.setLineWidth(3)
    for decade in [0.0, 1, 2, 3] {
        for k in 1...9 {
            let x = 150 + (decade + log10(Double(k))) / 3 * 724
            guard x <= 874 else { continue }
            ctx.move(to: CGPoint(x: x, y: 180)); ctx.addLine(to: CGPoint(x: x, y: 844))
        }
    }
    for y in stride(from: 260.0, through: 780, by: 104) {
        ctx.move(to: CGPoint(x: 150, y: y)); ctx.addLine(to: CGPoint(x: 874, y: y))
    }
    ctx.strokePath()

    // A path through y(t) for t in 0...1 across the plot area.
    func trace(_ y: (Double) -> Double) -> CGPath {
        let p = CGMutablePath()
        for i in 0...300 {
            let t = Double(i) / 300
            let pt = CGPoint(x: 150 + t * 724, y: 512 + y(t))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
    // The room: a bass mode, a cancellation dip and a ragged top.
    let room = trace { t in
        150 * exp(-pow((t - 0.16) / 0.05, 2)) - 120 * exp(-pow((t - 0.36) / 0.035, 2))
            + 60 * exp(-pow((t - 0.55) / 0.06, 2)) + 22 * sin(t * 47) * t - 80 * pow(max(t - 0.85, 0) / 0.15, 2) - 20
    }
    ctx.addPath(room)
    ctx.setStrokeColor(NSColor(red: 0.94, green: 0.33, blue: 0.31, alpha: 0.85).cgColor)
    ctx.setLineWidth(16)
    ctx.setLineJoin(.round); ctx.setLineCap(.round)
    ctx.strokePath()

    // The corrected response: nearly flat, with a gentle bass lift like the house target.
    let fixed = trace { t in 40 * exp(-pow(t / 0.22, 2)) - 30 }
    ctx.addPath(fixed)
    ctx.setShadow(offset: .zero, blur: 30, color: NSColor(red: 1, green: 0.77, blue: 0, alpha: 0.8).cgColor)
    ctx.setStrokeColor(NSColor(red: 1, green: 0.77, blue: 0, alpha: 1).cgColor)
    ctx.setLineWidth(30)
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try draw(size: 1024).write(to: out.appendingPathComponent("AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
