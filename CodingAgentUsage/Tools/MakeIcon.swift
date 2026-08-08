// Renders AppIcon.iconset. Run: swift Tools/MakeIcon.swift <output-dir>
// Two concentric gauge arcs — one per agent — on the standard macOS rounded-rect plate.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func arc(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ w: CGFloat,
         from startDeg: CGFloat, sweep: CGFloat, color: CGColor) {
    guard sweep > 0 else { return }
    ctx.setLineWidth(w)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color)
    ctx.beginPath()
    ctx.addArc(center: c, radius: r,
               startAngle: startDeg * .pi / 180,
               endAngle: (startDeg - sweep) * .pi / 180,
               clockwise: true)
    ctx.strokePath()
}

func render(_ S: CGFloat) -> CGImage {
    let px = Int(S)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Apple's macOS plate: 824/1024 square, 185.4/1024 corner radius.
    let inset = S * 100 / 1024, radius = S * 185.4 / 1024
    let plate = CGPath(roundedRect: CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset),
                       cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [rgb(0x3C3C43), rgb(0x1B1B1D)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    let c = CGPoint(x: S / 2, y: S / 2)
    let lw = S * 0.058
    let start: CGFloat = 210, span: CGFloat = 240   // 120° gap centred at the bottom
    let track = rgb(0xFFFFFF, 0.13)

    for (r, fill, pct) in [(S * 0.295, rgb(0xFAB219), CGFloat(0.68)),
                           (S * 0.185, rgb(0x45C8D8), CGFloat(0.42))] {
        arc(ctx, c, r, lw, from: start, sweep: span, color: track)
        arc(ctx, c, r, lw, from: start, sweep: span * pct, color: fill)
    }

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    write(render(CGFloat(base * scale)), to: outDir.appendingPathComponent(name))
}
print("wrote \(outDir.path)")
