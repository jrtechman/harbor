import AppKit

// Draws Harbor's app icon: a few coral starburst "boats" in a harbor at sunset.
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let coral = NSColor(calibratedRed: 0.85, green: 0.46, blue: 0.34, alpha: 1)

/// A hand-drawn radial burst of rounded rays.
func burst(_ c: NSPoint, _ r: CGFloat) {
    let lengths: [CGFloat] = [1.0, 0.72, 0.95, 0.70, 1.0, 0.76, 0.92, 0.70, 1.0, 0.72, 0.96, 0.78]
    coral.setStroke()
    for (i, L) in lengths.enumerated() {
        let a = CGFloat(i) / CGFloat(lengths.count) * 2 * .pi + 0.2
        let p = NSBezierPath()
        p.lineWidth = r * 0.21
        p.lineCapStyle = .round
        p.move(to: c)
        p.line(to: NSPoint(x: c.x + cos(a) * r * L, y: c.y + sin(a) * r * L))
        p.stroke()
    }
}

/// One boat: hull, mast and a burst for a sail. `k` scales it, `alpha` fades distant boats.
func boat(_ s: CGFloat, x: CGFloat, baseY: CGFloat, k: CGFloat, alpha: CGFloat) {
    let w = 0.34 * s * k, h = 0.075 * s * k
    let top = baseY + h / 2, bottom = baseY - h / 2
    let hull = NSBezierPath()
    hull.move(to: NSPoint(x: x - w / 2, y: top))
    hull.line(to: NSPoint(x: x + w / 2, y: top))
    hull.line(to: NSPoint(x: x + w * 0.34, y: bottom))
    hull.line(to: NSPoint(x: x - w * 0.34, y: bottom))
    hull.close()
    let center = NSPoint(x: x, y: top + 0.19 * s * k)
    NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.34, alpha: alpha).setStroke()
    let mast = NSBezierPath()
    mast.lineWidth = max(1, 0.012 * s * k)
    mast.move(to: NSPoint(x: x, y: top)); mast.line(to: center)
    mast.stroke()
    NSGraphicsContext.current?.cgContext.setAlpha(alpha)
    burst(center, 0.15 * s * k)
    NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.34, alpha: 1).setFill()
    hull.fill()
    NSGraphicsContext.current?.cgContext.setAlpha(1)
    // ripples under the hull
    NSColor.white.withAlphaComponent(0.55 * alpha).setStroke()
    for dy in [CGFloat(-0.03), -0.06] {
        let p = NSBezierPath()
        p.lineWidth = max(1, 0.012 * s * k)
        p.lineCapStyle = .round
        let ww = w * (dy == -0.03 ? 0.62 : 0.4)
        p.move(to: NSPoint(x: x - ww, y: bottom + dy * s * k))
        p.line(to: NSPoint(x: x + ww, y: bottom + dy * s * k))
        p.stroke()
    }
}

func draw(_ s: CGFloat) {
    let rect = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18).addClip()

    let horizon = rect.minY + rect.height * 0.42
    // sky
    NSGradient(starting: NSColor(calibratedRed: 0.97, green: 0.80, blue: 0.68, alpha: 1),
               ending: NSColor(calibratedRed: 0.99, green: 0.95, blue: 0.90, alpha: 1))!
        .draw(in: NSRect(x: rect.minX, y: horizon, width: rect.width, height: rect.maxY - horizon), angle: 90)
    // water
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.32, blue: 0.45, alpha: 1),
               ending: NSColor(calibratedRed: 0.32, green: 0.60, blue: 0.70, alpha: 1))!
        .draw(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: horizon - rect.minY), angle: 90)

    // distant boats first, the big one last
    boat(s, x: 0.30 * s, baseY: horizon - 0.025 * s, k: 0.50, alpha: 0.75)
    boat(s, x: 0.74 * s, baseY: horizon - 0.075 * s, k: 0.62, alpha: 0.9)
    boat(s, x: 0.50 * s, baseY: horizon - 0.15 * s, k: 1.0, alpha: 1)
    NSGraphicsContext.restoreGraphicsState()
}

for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                   (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
