// Renders AppIcon.iconset. Run: swift Tools/MakeIcon.swift <output-dir>
// A five-bar waveform — the same motif as the listening HUD — on the standard
// macOS rounded-rect plate.
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
    ctx.interpolationQuality = .high

    // Apple's macOS plate: 824/1024 square, 185.4/1024 corner radius.
    let inset = S * 100 / 1024, radius = S * 185.4 / 1024
    let plate = CGPath(roundedRect: CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset),
                       cornerWidth: radius, cornerHeight: radius, transform: nil)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: [rgb(0x2B3A44), rgb(0x14191D)] as CFArray,
                   locations: [0, 1])!,
        start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // Symmetric waveform: short, medium, tall, medium, short.
    let heights: [CGFloat] = [0.30, 0.62, 1.0, 0.62, 0.30]
    let barW = S * 0.072
    let gap = S * 0.052
    let maxH = S * 0.46
    let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = S / 2 - totalW / 2

    ctx.saveGState()
    for h in heights {
        let barH = maxH * h
        let rect = CGRect(x: x, y: S / 2 - barH / 2, width: barW, height: barH)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2,
                           transform: nil))
        x += barW + gap
    }
    ctx.clip()
    ctx.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: [rgb(0x7BE7F5), rgb(0x2B9FC4)] as CFArray,
                   locations: [0, 1])!,
        start: CGPoint(x: 0, y: S / 2 + maxH / 2), end: CGPoint(x: 0, y: S / 2 - maxH / 2),
        options: [])
    ctx.restoreGState()

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
