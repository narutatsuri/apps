import AppKit
import Foundation

// A small board: three pastel cards — Jot's paper colours, since the editor
// is Jot's — standing on a dark ground, each with a header band and a few
// lines of writing of different lengths, so it reads as projects at
// different stages rather than a bar chart. Drawn rather than shipped as a
// PNG so the icon lives in version control as something readable.
func draw(_ size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    // Ground: a squircle-ish rounded square with a soft vertical gradient.
    let inset = s * 0.06
    let ground = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let groundPath = NSBezierPath(roundedRect: ground, xRadius: s * 0.21, yRadius: s * 0.21)
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.30, alpha: 1),
               ending: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.17, alpha: 1))?
        .draw(in: groundPath, angle: -90)

    // Three cards, slightly staggered in height so the board looks lived-in.
    let papers: [(NSColor, NSColor)] = [
        (NSColor(srgbRed: 1.00, green: 0.91, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.93, green: 0.80, blue: 0.36, alpha: 1)),
        (NSColor(srgbRed: 0.72, green: 0.85, blue: 1.00, alpha: 1), NSColor(srgbRed: 0.55, green: 0.72, blue: 0.95, alpha: 1)),
        (NSColor(srgbRed: 0.74, green: 0.93, blue: 0.79, alpha: 1), NSColor(srgbRed: 0.55, green: 0.82, blue: 0.62, alpha: 1)),
    ]
    let lines: [[CGFloat]] = [[0.78, 0.55, 0.66, 0.40], [0.62, 0.70, 0.35], [0.74, 0.48, 0.60, 0.66, 0.30]]
    let tops: [CGFloat] = [0.80, 0.86, 0.76]
    let gap = ground.width * 0.055
    let cardW = (ground.width - gap * 4) / 3
    let radius = cardW * 0.14

    for i in 0..<3 {
        let x = ground.minX + gap + CGFloat(i) * (cardW + gap)
        let top = ground.minY + ground.height * tops[i]
        let card = NSRect(x: x, y: ground.minY + gap * 1.2, width: cardW, height: top - ground.minY - gap * 1.2)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = s * 0.025
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.set()
        papers[i].0.setFill()
        NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Header band, clipped to the card's rounded top.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius).addClip()
        papers[i].1.setFill()
        NSRect(x: card.minX, y: card.maxY - card.height * 0.16, width: card.width,
               height: card.height * 0.16).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Lines of writing.
        NSColor(srgbRed: 0.18, green: 0.16, blue: 0.10, alpha: 0.42).setStroke()
        for (j, w) in lines[i].enumerated() {
            let line = NSBezierPath()
            line.lineWidth = max(1, s * 0.03)
            line.lineCapStyle = .round
            let y = card.maxY - card.height * 0.16 - card.height * (0.17 + CGFloat(j) * 0.15)
            guard y > card.minY + card.height * 0.08 else { break }
            line.move(to: NSPoint(x: card.minX + cardW * 0.14, y: y))
            line.line(to: NSPoint(x: card.minX + cardW * (0.14 + w * 0.72), y: y))
            line.stroke()
        }
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
