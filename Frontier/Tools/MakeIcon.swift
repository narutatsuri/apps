// Renders AppIcon.iconset. Run: swift Tools/MakeIcon.swift <output-dir>
//
// Steps rising to a lit one, not a node graph. Paper Notes' icon is already a
// graph of nodes and edges on navy, and two dark tiles with dots joined by lines
// are indistinguishable in the Dock at 32pt. This says the other half of what
// the app is anyway: not a map of concepts, but a place you are standing on and
// the next step up — deep green plate, amber on the edge you have reached.
import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let sizes = [16, 32, 64, 128, 256, 512]
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ pixels: Int) -> NSImage {
    let S = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: S, height: S))
    image.lockFocus()

    let inset = S * 0.098, radius = S * 0.181
    let plate = NSBezierPath(roundedRect: NSRect(x: inset, y: inset,
                                                 width: S - 2 * inset, height: S - 2 * inset),
                             xRadius: radius, yRadius: radius)
    NSGradient(colors: [rgb(0x1B4D46), rgb(0x0B211F)])?.draw(in: plate, angle: -90)

    // One staircase, not four bars.
    //
    // Drawn as a single connected silhouette because separate rectangles read
    // as a bar chart — measurement rather than ascent, which is the wrong idea
    // entirely. The top tread is lit: the step being climbed, not the summit.
    let x0 = S * 0.245, y0 = S * 0.315
    let tread = S * 0.128, rise = S * 0.088
    let steps = 4

    let stair = NSBezierPath()
    stair.move(to: NSPoint(x: x0, y: y0))
    for i in 0..<steps {
        let x = x0 + CGFloat(i) * tread
        stair.line(to: NSPoint(x: x, y: y0 + CGFloat(i + 1) * rise))
        stair.line(to: NSPoint(x: x + tread, y: y0 + CGFloat(i + 1) * rise))
    }
    stair.line(to: NSPoint(x: x0 + CGFloat(steps) * tread, y: y0))
    stair.close()
    rgb(0x8FD3C7, 0.55).setFill()
    stair.fill()

    // The tread you are on.
    let topY = y0 + CGFloat(steps) * rise
    let lit = NSBezierPath(roundedRect: NSRect(x: x0 + CGFloat(steps - 1) * tread,
                                               y: topY - S * 0.030,
                                               width: tread, height: S * 0.030),
                           xRadius: S * 0.008, yRadius: S * 0.008)
    rgb(0xF5A524).setFill()
    lit.fill()

    // And a mark standing on it.
    let markerR = S * 0.042
    let marker = NSRect(x: x0 + (CGFloat(steps) - 0.5) * tread - markerR,
                        y: topY + S * 0.018,
                        width: markerR * 2, height: markerR * 2)
    rgb(0xFFF3D6).setFill()
    NSBezierPath(ovalIn: marker).fill()

    image.unlockFocus()
    return image
}

for size in sizes {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let pixels = size * scale
        guard pixels <= 1024 else { continue }
        guard let tiff = render(pixels).tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        try? png.write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)\(suffix).png"))
    }
}
print("wrote \(out)")
