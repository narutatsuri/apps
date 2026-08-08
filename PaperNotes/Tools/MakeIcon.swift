// Renders AppIcon.iconset. Run: swift Tools/MakeIcon.swift <output-dir>
// A small citation graph — nodes and edges — since the graph is the point of the app.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ S: CGFloat) -> CGImage {
    let px = Int(S)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)

    let inset = S * 100 / 1024, radius = S * 185.4 / 1024
    let plate = CGPath(roundedRect: CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset),
                       cornerWidth: radius, cornerHeight: radius, transform: nil)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    ctx.saveGState()
    ctx.addPath(plate); ctx.clip()
    ctx.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: [rgb(0x243447), rgb(0x141B24)] as CFArray,
                   locations: [0, 1])!,
        start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // A hub with satellites — one paper, and what it connects to.
    let c = CGPoint(x: S / 2, y: S / 2)
    let orbit = S * 0.215
    let satellites: [(CGFloat, CGFloat)] = [(90, 1.0), (200, 0.92), (320, 0.86), (250, 0.55), (25, 0.6)]
    let points = satellites.map { (deg, dist) -> CGPoint in
        let r = orbit * dist * 1.35
        return CGPoint(x: c.x + cos(deg * .pi / 180) * r, y: c.y + sin(deg * .pi / 180) * r)
    }

    ctx.setLineWidth(S * 0.016)
    ctx.setStrokeColor(rgb(0x6E8AA8, 0.75))
    ctx.setLineCap(.round)
    for p in points {
        ctx.beginPath(); ctx.move(to: c); ctx.addLine(to: p); ctx.strokePath()
    }
    // One edge between satellites — the graph is not a star.
    ctx.beginPath(); ctx.move(to: points[0]); ctx.addLine(to: points[1]); ctx.strokePath()

    for (i, p) in points.enumerated() {
        let r = S * (i < 3 ? 0.052 : 0.040)
        ctx.setFillColor(rgb(0x7BE7F5))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }
    let hub = S * 0.082
    ctx.setFillColor(rgb(0xFAB219))
    ctx.fillEllipse(in: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2))

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    write(render(CGFloat(base * scale)), to: outDir.appendingPathComponent(name))
}
print("wrote \(outDir.path)")
