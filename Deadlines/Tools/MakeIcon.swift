import AppKit

// Renders the .iconset. No Xcode here, so the icon is drawn rather than
// designed: a dark rounded tile with an hourglass, which reads at 16pt.
let sizes = [16, 32, 64, 128, 256, 512]
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> NSImage {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()
    let rect = NSRect(origin: .zero, size: size)
    let radius = CGFloat(pixels) * 0.22
    let tile = NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(pixels) * 0.045,
                                                      dy: CGFloat(pixels) * 0.045),
                            xRadius: radius, yRadius: radius)
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: 1),
                        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.12, alpha: 1)])?
        .draw(in: tile, angle: -90)

    let glyphSize = CGFloat(pixels) * 0.54
    let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor(srgbRed: 1.0, green: 0.74, blue: 0.33, alpha: 1).set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
        symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        let box = NSRect(x: (size.width - symbol.size.width) / 2,
                         y: (size.height - symbol.size.height) / 2,
                         width: symbol.size.width, height: symbol.size.height)
        tinted.draw(in: box)
    }
    image.unlockFocus()
    return image
}

for size in sizes {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let pixels = size * scale
        guard pixels <= 1024 else { continue }
        let image = draw(pixels)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        try? png.write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)\(suffix).png"))
    }
}
print("wrote \(out)")
