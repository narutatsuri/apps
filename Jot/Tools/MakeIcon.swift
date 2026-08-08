import AppKit
import Foundation

// A yellow square with a folded corner and three lines of "writing".
// Drawn rather than shipped as a PNG so the icon lives in version control as
// something readable and adjustable.
func draw(_ size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let fold = rect.width * 0.30

    // Body, with the bottom-right corner cut away for the fold.
    let body = NSBezierPath()
    body.move(to: NSPoint(x: rect.minX, y: rect.minY + fold))
    body.line(to: NSPoint(x: rect.minX, y: rect.maxY))
    body.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    body.line(to: NSPoint(x: rect.maxX, y: rect.minY + fold))
    body.line(to: NSPoint(x: rect.minX + fold, y: rect.minY))
    body.close()
    NSColor(srgbRed: 1.0, green: 0.886, blue: 0.463, alpha: 1).setFill()
    body.fill()

    // The folded triangle, darker so it reads as a shadow.
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: rect.minX, y: rect.minY + fold))
    corner.line(to: NSPoint(x: rect.minX + fold, y: rect.minY + fold))
    corner.line(to: NSPoint(x: rect.minX + fold, y: rect.minY))
    corner.close()
    NSColor(srgbRed: 0.87, green: 0.74, blue: 0.32, alpha: 1).setFill()
    corner.fill()

    // Three ruled lines, the shortest last, so it reads as writing not a grid.
    NSColor(srgbRed: 0.42, green: 0.35, blue: 0.12, alpha: 0.55).setStroke()
    let widths: [CGFloat] = [0.62, 0.62, 0.38]
    for (i, w) in widths.enumerated() {
        let line = NSBezierPath()
        line.lineWidth = max(1, s * 0.045)
        line.lineCapStyle = .round
        let y = rect.maxY - rect.height * (0.30 + CGFloat(i) * 0.19)
        line.move(to: NSPoint(x: rect.minX + rect.width * 0.19, y: y))
        line.line(to: NSPoint(x: rect.minX + rect.width * (0.19 + w), y: y))
        line.stroke()
    }

    image.unlockFocus()
    return image
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (size, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                     (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                     (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let image = draw(size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("wrote \(out)")
