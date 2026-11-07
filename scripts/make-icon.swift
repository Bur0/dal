// Renders the app icon (1024px) and writes an AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift Dal/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = s / 1024
    // macOS icon grid: 824px rounded square centred in 1024.
    let rect = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor(red: 0.11, green: 0.13, blue: 0.17, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape); ctx.clip()
    // subtle top light
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(white: 1, alpha: 0.07).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 924 * k), end: CGPoint(x: 0, y: 500 * k), options: [])

    let blue = NSColor(red: 0.18, green: 0.61, blue: 0.88, alpha: 1).cgColor
    let amber = NSColor(red: 0.90, green: 0.60, blue: 0.18, alpha: 1).cgColor
    let lw = 46 * k
    ctx.setLineCap(.round)
    // trunk
    ctx.setStrokeColor(blue); ctx.setLineWidth(lw)
    ctx.move(to: CGPoint(x: 400 * k, y: 250 * k)); ctx.addLine(to: CGPoint(x: 400 * k, y: 774 * k)); ctx.strokePath()
    // branch curve
    ctx.setStrokeColor(amber)
    ctx.move(to: CGPoint(x: 400 * k, y: 330 * k))
    ctx.addCurve(to: CGPoint(x: 640 * k, y: 560 * k), control1: CGPoint(x: 400 * k, y: 470 * k), control2: CGPoint(x: 640 * k, y: 420 * k))
    ctx.addLine(to: CGPoint(x: 640 * k, y: 640 * k))
    ctx.strokePath()
    func node(_ x: CGFloat, _ y: CGFloat, _ c: CGColor, _ r: CGFloat) {
        let rr = CGRect(x: (x - r) * k, y: (y - r) * k, width: 2 * r * k, height: 2 * r * k)
        ctx.setFillColor(NSColor(red: 0.11, green: 0.13, blue: 0.17, alpha: 1).cgColor); ctx.fillEllipse(in: rr.insetBy(dx: -14 * k, dy: -14 * k))
        ctx.setFillColor(c); ctx.fillEllipse(in: rr)
    }
    node(400, 250, blue, 62)
    node(400, 774, blue, 62)
    node(640, 640, amber, 62)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: URL(fileURLWithPath: out).appendingPathComponent("Contents.json"))
let root = (out as NSString).deletingLastPathComponent
try! #"{"info":{"author":"xcode","version":1}}"#.write(toFile: root + "/Contents.json", atomically: true, encoding: .utf8)
print("wrote \(out)")
